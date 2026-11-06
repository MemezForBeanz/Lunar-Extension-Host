--- Reads and writes the catalog. Every query is bounded and uses keyset pages, so
-- a page costs the same at row one million as at row one. Statements are prepared
-- once and reused, because this is the path every browse request takes.
-- @module libs.catalog

local sqlite = require("core.lib.sqlite")
local naming = require("libs.naming")

local Catalog = {}
Catalog.__index = Catalog

local M = {}

M.PAGE_MAX = 200

local function value(v)
	if v == sqlite.NULL then return nil end
	return v
end

local function row_of(raw)
	local out = {}
	for k, v in pairs(raw) do out[k] = value(v) end
	return out
end

--- Wrap an open, migrated database.
function M.new(db, clock)
	return setmetatable({ db = db, clock = clock or os.time, stmts = {} }, Catalog)
end

function Catalog:_prepared(sql)
	local stmt = self.stmts[sql]
	if not stmt then
		local err
		stmt, err = self.db:prepare(sql)
		if not stmt then error(err, 0) end
		self.stmts[sql] = stmt
	end
	stmt:reset()
	return stmt
end

function Catalog:_rows(sql, ...)
	local stmt = self:_prepared(sql)
	for i = 1, select("#", ...) do
		local bound = select(i, ...)
		stmt:bind(i, bound == nil and sqlite.NULL or bound)
	end
	local rows = {}
	while true do
		local row, err = stmt:step()
		if row == nil then stmt:reset(); error(err, 0) end
		if not row then break end
		rows[#rows + 1] = row_of(row)
	end
	stmt:reset()
	return rows
end

function Catalog:_one(sql, ...)
	return self:_rows(sql, ...)[1]
end

--- Finalize every cached statement; call before the database closes.
function Catalog:close()
	for _, stmt in pairs(self.stmts) do stmt:finalize() end
	self.stmts = {}
end

--- Run `fn` in one transaction, so a batch commits once.
function Catalog:batch(fn)
	return self.db:transaction(fn)
end

function Catalog:addLibrary(name, kind, root)
	self:_rows("INSERT INTO libraries (name, kind, root) VALUES (?, ?, ?)", name, kind, root)
	return self:_one("SELECT * FROM libraries WHERE root = ?", root)
end

function Catalog:libraries()
	return self:_rows([[SELECT l.*, (SELECT COUNT(*) FROM works w WHERE w.library_id = l.id
		AND w.kind IN ('movie', 'show')) AS item_count FROM libraries l ORDER BY l.name, l.id]])
end

function Catalog:library(id)
	return self:_one("SELECT * FROM libraries WHERE id = ?", id)
end

function Catalog:_work(library_id, parent_id, kind, identity, title, year, season, episode)
	local found = self:_one("SELECT id FROM works WHERE library_id = ? AND identity = ?", library_id, identity)
	if found then return found.id end
	self:_rows([[INSERT INTO works (library_id, parent_id, kind, identity, title, sort_key, year, season, episode, added_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], library_id, parent_id, kind, identity, title,
		naming.sortKey(title), year, season, episode, self.clock())
	return self:_one("SELECT id FROM works WHERE library_id = ? AND identity = ?", library_id, identity).id
end

function Catalog:_work_for(library_id, parsed)
	if parsed.kind == "movie" then
		local identity = "m:" .. naming.sortKey(parsed.title) .. ":" .. tostring(parsed.year or "")
		return self:_work(library_id, nil, "movie", identity, parsed.title, parsed.year)
	end
	local show_key = "s:" .. naming.sortKey(parsed.show) .. ":" .. tostring(parsed.show_year or "")
	local show = self:_work(library_id, nil, "show", show_key, parsed.show, parsed.show_year)
	local season_key = show_key .. ":" .. parsed.season
	local season_title = parsed.season == 0 and "Specials" or ("Season " .. parsed.season)
	local season = self:_work(library_id, show, "season", season_key, season_title, nil, parsed.season)
	local label = "Episode " .. parsed.episode
	return self:_work(library_id, season, "episode", season_key .. ":" .. parsed.episode, label, nil,
		parsed.season, parsed.episode)
end

--- Record one file seen by a scan.
-- @treturn number|nil the file id when it needs analysis
function Catalog:noteFile(library_id, rel_path, size, mtime, scan, parsed)
	local existing = self:_one(
		"SELECT id, size, mtime, probed_stamp FROM files WHERE library_id = ? AND rel_path = ?", library_id, rel_path)
	if existing then
		self:_rows("UPDATE files SET seen_scan = ?, missing_at = NULL, size = ?, mtime = ? WHERE id = ?",
			scan, size, mtime, existing.id)
		local stamp = size .. ":" .. mtime
		return existing.probed_stamp ~= stamp and existing.id or nil
	end
	local work = self:_work_for(library_id, parsed)
	self:_rows([[INSERT INTO files (library_id, work_id, rel_path, size, mtime, seen_scan)
		VALUES (?, ?, ?, ?, ?, ?)]], library_id, work, rel_path, size, mtime, scan)
	return self:_one("SELECT id FROM files WHERE library_id = ? AND rel_path = ?", library_id, rel_path).id
end

--- Queue analysis, unless it is already queued.
function Catalog:queueProbe(file_id)
	self:_rows("INSERT OR IGNORE INTO jobs (file_id) VALUES (?)", file_id)
end

--- Close a scan: files it did not see are marked missing, never deleted, so a
-- disk that is offline doesn't erase a library or anyone's progress.
function Catalog:finishScan(library_id, scan, now)
	self:_rows([[UPDATE files SET missing_at = ? WHERE library_id = ? AND seen_scan <> ? AND missing_at IS NULL]],
		now, library_id, scan)
	self:_rows("UPDATE libraries SET scanned_at = ?, scan_count = ?, available = 1 WHERE id = ?", now, scan, library_id)
end

local BROWSE = {
	title = { [[SELECT id, kind, title, year, sort_key, added_at FROM works
		WHERE library_id = ? AND kind IN ('movie', 'show') AND (sort_key, id) > (?, ?)
		ORDER BY sort_key, id LIMIT ?]], "sort_key" },
	added = { [[SELECT id, kind, title, year, sort_key, added_at FROM works
		WHERE library_id = ? AND kind IN ('movie', 'show') AND (added_at, id) < (?, ?)
		ORDER BY added_at DESC, id DESC LIMIT ?]], "added_at" },
}

--- One page of a library.
-- @tparam table opts `sort` (`title`, `added`), `limit`, `after_key`, `after_id`
-- @treturn table `{ items, next }`; `next` is nil on the last page
function Catalog:browse(library_id, opts)
	local spec = BROWSE[opts.sort or "title"] or BROWSE.title
	local limit = math.max(1, math.min(tonumber(opts.limit) or 50, M.PAGE_MAX))
	local key, id = opts.after_key, opts.after_id
	if spec == BROWSE.title then
		key, id = key or "", id or 0
	else
		key, id = key or 2 ^ 53, id or 2 ^ 53
	end
	local rows = self:_rows(spec[1], library_id, key, id, limit + 1)
	local next_page
	if #rows > limit then
		rows[#rows] = nil
		local last = rows[#rows]
		next_page = { after_key = last[spec[2]], after_id = last.id }
	end
	return { items = rows, next = next_page }
end

--- A title search; `q` matches the start of any sort key prefix, case-insensitively.
function Catalog:search(q, limit)
	local key = naming.sortKey(q)
	local upper = key .. "\255"
	return self:_rows([[SELECT id, library_id, kind, title, year FROM works
		WHERE kind IN ('movie', 'show') AND sort_key >= ? AND sort_key < ?
		ORDER BY sort_key, id LIMIT ?]], key, upper, math.min(tonumber(limit) or 20, M.PAGE_MAX))
end

--- One work with its files, streams, children and this user's progress.
function Catalog:item(id, user)
	local work = self:_one("SELECT * FROM works WHERE id = ?", id)
	if not work then return nil end
	work.files = self:_rows([[SELECT id, rel_path, size, container, duration_ms, bitrate, missing_at, probe_error
		FROM files WHERE work_id = ? ORDER BY id]], id)
	for _, file in ipairs(work.files) do
		file.streams = self:_rows([[SELECT idx, kind, codec, language, title, channels, width, height, hdr,
			is_default, is_forced FROM streams WHERE file_id = ? ORDER BY idx]], file.id)
	end
	work.children = self:_rows([[SELECT id, kind, title, season, episode FROM works
		WHERE parent_id = ? ORDER BY season, episode, id LIMIT 1000]], id)
	work.progress = self:_one(
		"SELECT position_ms, watched, updated_at FROM user_progress WHERE user = ? AND work_id = ?", user, id)
	return work
end

--- The file behind a streaming request, with the root it must stay inside.
function Catalog:fileTarget(file_id)
	return self:_one([[SELECT f.id, f.rel_path, f.container, f.missing_at, f.size, l.root
		FROM files f JOIN libraries l ON l.id = f.library_id WHERE f.id = ?]], file_id)
end

--- Save a resume point. Past 95% counts as watched, and the position clears.
function Catalog:saveProgress(user, work_id, position_ms, duration_ms, now)
	local watched = duration_ms and duration_ms > 0 and position_ms / duration_ms >= 0.95
	self:_rows([[INSERT INTO user_progress (user, work_id, position_ms, watched, updated_at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (user, work_id) DO UPDATE SET position_ms = excluded.position_ms,
		watched = MAX(watched, excluded.watched), updated_at = excluded.updated_at]],
		user, work_id, watched and 0 or position_ms, watched and 1 or 0, now)
end

--- What this user was in the middle of, newest first.
function Catalog:continueWatching(user, limit)
	return self:_rows([[SELECT w.id, w.kind, w.title, w.year, p.position_ms, p.updated_at
		FROM user_progress p JOIN works w ON w.id = p.work_id
		WHERE p.user = ? AND p.watched = 0 AND p.position_ms > 0
		ORDER BY p.updated_at DESC LIMIT ?]], user, math.min(tonumber(limit) or 20, M.PAGE_MAX))
end

--- Take the next ready analysis job, or nil.
function Catalog:claimProbe(now)
	local job = self:_one([[SELECT j.id, j.file_id, j.attempts, f.rel_path, l.root, f.size, f.mtime
		FROM jobs j JOIN files f ON f.id = j.file_id JOIN libraries l ON l.id = f.library_id
		WHERE j.state = 'queued' AND j.next_run_at <= ? ORDER BY j.next_run_at, j.id LIMIT 1]], now)
	if job then self:_rows("UPDATE jobs SET state = 'running' WHERE id = ?", job.id) end
	return job
end

--- A crash leaves running jobs behind; put them back on start.
function Catalog:recoverJobs()
	self:_rows("UPDATE jobs SET state = 'queued' WHERE state = 'running'")
end

--- Store a finished analysis and clear its job.
function Catalog:saveProbe(job, info)
	self:_rows("UPDATE files SET container = ?, duration_ms = ?, bitrate = ?, probed_stamp = ?, probe_error = NULL WHERE id = ?",
		info.container, info.duration_ms, info.bitrate, job.size .. ":" .. job.mtime, job.file_id)
	self:_rows("DELETE FROM streams WHERE file_id = ?", job.file_id)
	for _, s in ipairs(info.streams) do
		self:_rows([[INSERT INTO streams (file_id, idx, kind, codec, language, title, channels, width, height, hdr, is_default, is_forced)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], job.file_id, s.idx, s.kind, s.codec, s.language, s.title,
			s.channels, s.width, s.height, s.hdr and 1 or 0, s.is_default and 1 or 0, s.is_forced and 1 or 0)
	end
	self:_rows("DELETE FROM jobs WHERE id = ?", job.id)
end

--- Record a failed analysis. It retries with backoff, then stops and shows its reason.
function Catalog:failProbe(job, reason, now)
	local attempts = job.attempts + 1
	if attempts >= 3 then
		self:_rows("UPDATE jobs SET state = 'failed', attempts = ?, error = ? WHERE id = ?", attempts, reason, job.id)
		self:_rows("UPDATE files SET probe_error = ? WHERE id = ?", reason, job.file_id)
	else
		self:_rows("UPDATE jobs SET state = 'queued', attempts = ?, error = ?, next_run_at = ? WHERE id = ?",
			attempts, reason, now + 30 * attempts * attempts, job.id)
	end
end

--- Counts for the status page.
function Catalog:counts()
	return self:_one([[SELECT
		(SELECT COUNT(*) FROM works WHERE kind IN ('movie', 'show')) AS items,
		(SELECT COUNT(*) FROM files WHERE missing_at IS NULL) AS files,
		(SELECT COUNT(*) FROM files WHERE missing_at IS NOT NULL) AS missing,
		(SELECT COUNT(*) FROM jobs WHERE state IN ('queued', 'running')) AS analysing,
		(SELECT COUNT(*) FROM jobs WHERE state = 'failed') AS failed]])
end

return M
