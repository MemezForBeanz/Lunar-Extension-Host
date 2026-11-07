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

--- The work a file belongs to, and the top of its tree: art hangs off the film or the show.
-- @treturn number|nil the id of the film or show
function Catalog:topWorkOfFile(library_id, rel_path)
	local row = self:_one([[SELECT w.id, w.parent_id FROM files f JOIN works w ON w.id = f.work_id
		WHERE f.library_id = ? AND f.rel_path = ?]], library_id, rel_path)
	while row and row.parent_id do
		row = self:_one("SELECT id, parent_id FROM works WHERE id = ?", row.parent_id)
	end
	return row and row.id or nil
end

--- Remember a picture. One a person chose always replaces a generated frame.
function Catalog:saveArt(work_id, kind, origin, path)
	if origin == "frame" and self:_one("SELECT id FROM works WHERE id = ? AND backdrop_url IS NOT NULL", work_id) then return end
	self:_rows([[INSERT INTO art (work_id, kind, origin, path) VALUES (?, ?, ?, ?)
		ON CONFLICT (work_id, kind) DO UPDATE SET origin = excluded.origin, path = excluded.path
		WHERE art.origin = 'frame' OR excluded.origin = 'library']], work_id, kind, origin, path)
	if origin == "library" and kind == "backdrop" then self:_rows("DELETE FROM art_jobs WHERE work_id = ?", work_id) end
	if origin == "library" then
		local column = kind == "poster" and "poster_url" or "backdrop_url"
		self:_rows("UPDATE works SET " .. column .. " = NULL WHERE id = ?", work_id)
	end
end

--- A picture to serve, with the library root or nil for a generated frame.
function Catalog:artTarget(work_id, kind)
	return self:_one([[SELECT a.origin, a.path, l.root FROM art a JOIN works w ON w.id = a.work_id
		JOIN libraries l ON l.id = w.library_id WHERE a.work_id = ? AND a.kind = ?]], work_id, kind)
end

--- Ask for a frame from this file, unless the work has a backdrop or a job already.
function Catalog:queueFrame(file_id)
	self:_rows([[INSERT OR IGNORE INTO art_jobs (work_id, file_id)
		SELECT top.id, ? FROM (WITH RECURSIVE up(id, parent_id) AS (
			SELECT w.id, w.parent_id FROM files f JOIN works w ON w.id = f.work_id WHERE f.id = ?
			UNION ALL SELECT w.id, w.parent_id FROM works w JOIN up ON w.id = up.parent_id)
			SELECT id FROM up WHERE parent_id IS NULL) top
		WHERE NOT EXISTS (SELECT 1 FROM art a WHERE a.work_id = top.id AND a.kind = 'backdrop')
		AND NOT EXISTS (SELECT 1 FROM works w WHERE w.id = top.id AND w.backdrop_url IS NOT NULL)]], file_id, file_id)
end

--- Take the next frame job, or nil.
function Catalog:claimFrame()
	local job = self:_one([[SELECT j.work_id, j.file_id, f.rel_path, f.duration_ms, l.root FROM art_jobs j
		JOIN files f ON f.id = j.file_id JOIN libraries l ON l.id = f.library_id
		WHERE j.state = 'queued' ORDER BY j.work_id LIMIT 1]])
	if job then self:_rows("UPDATE art_jobs SET state = 'running' WHERE work_id = ?", job.work_id) end
	return job
end

--- A frame arrived.
function Catalog:finishFrame(work_id, path)
	self:saveArt(work_id, "backdrop", "frame", path)
	self:_rows("DELETE FROM art_jobs WHERE work_id = ?", work_id)
end

--- A frame could not be taken. The work keeps its title tile, and the reason stays.
function Catalog:failFrame(work_id, reason)
	self:_rows("UPDATE art_jobs SET state = 'failed', error = ? WHERE work_id = ?", reason, work_id)
end

--- Record what a person wrote down about a work. A value already there is only replaced by
-- one from an .nfo, which someone chose, never by a tag some encoder left in a file.
-- @tparam number work_id
-- @tparam table facts `overview`, `rating`, `content_rating`, `studio`, `genres`, `people`
-- @tparam boolean chosen true for an .nfo
function Catalog:saveFacts(work_id, facts, chosen)
	if chosen then
		for _, field in ipairs({ "title", "year", "overview", "rating", "content_rating", "studio", "genres", "people" }) do
			local v = facts[field]
			if v ~= nil and (type(v) ~= "table" or #v > 0) then
				self:_rows("INSERT OR IGNORE INTO metadata_local_fields (work_id, field) VALUES (?, ?)", work_id, field)
			end
		end
		if facts.title then
			self:_rows("UPDATE works SET title = ?, sort_key = ? WHERE id = ?", facts.title, naming.sortKey(facts.title), work_id)
		end
		if facts.year then self:_rows("UPDATE works SET year = ? WHERE id = ?", facts.year, work_id) end
		self:_rows([[UPDATE works SET overview = COALESCE(?, overview), rating = COALESCE(?, rating),
			content_rating = COALESCE(?, content_rating), studio = COALESCE(?, studio) WHERE id = ?]],
			facts.overview, facts.rating, facts.content_rating, facts.studio, work_id)
	else
		self:_rows("UPDATE works SET overview = COALESCE(overview, ?) WHERE id = ?", facts.overview, work_id)
	end
	if chosen and #(facts.genres or {}) > 0 then self:_rows("DELETE FROM work_tags WHERE work_id = ? AND kind = 'genre'", work_id) end
	if chosen and #(facts.people or {}) > 0 then self:_rows("DELETE FROM work_tags WHERE work_id = ? AND kind = 'person'", work_id) end
	for _, pair in ipairs({ { "genres", "genre" }, { "people", "person" } }) do
		local protected = not chosen and (self:_one("SELECT field FROM metadata_local_fields WHERE work_id = ? AND field = ?", work_id, pair[1])
			or self:_one("SELECT work_id FROM work_metadata WHERE work_id = ?", work_id))
		if not protected then
			for _, tag in ipairs(facts[pair[1]] or {}) do
				self:_rows("INSERT OR IGNORE INTO work_tags (work_id, kind, value) VALUES (?, ?, ?)", work_id, pair[2], tag)
			end
		end
	end
end

--- Queue a bounded group of titles first seen since metadata last ran.
function Catalog:queueMissingMetadata(now, limit)
	self:_rows([[INSERT OR IGNORE INTO metadata_jobs (work_id, updated_at)
		SELECT w.id, ? FROM works w WHERE w.kind IN ('movie','show')
		AND NOT EXISTS (SELECT 1 FROM metadata_jobs j WHERE j.work_id = w.id)
		ORDER BY w.id LIMIT ?]], now, math.max(1, math.min(tonumber(limit) or 100, 1000)))
end

--- Explicit refresh resets exhausted/no-match work, preserving a job already in flight.
function Catalog:queueMetadata(work_id, now)
	if work_id then
		local work = self:_one("SELECT id FROM works WHERE id = ? AND kind IN ('movie','show')", work_id)
		if not work then return nil, "no movie or show with that id" end
		self:_rows([[INSERT INTO metadata_jobs (work_id, updated_at) VALUES (?, ?)
			ON CONFLICT (work_id) DO UPDATE SET state = 'queued', attempts = 0, next_run_at = 0, error = NULL,
			updated_at = excluded.updated_at WHERE metadata_jobs.state <> 'running']], work_id, now)
	else
		self:queueMissingMetadata(now, 1000)
		self:_rows([[UPDATE metadata_jobs SET state = 'queued', attempts = 0, next_run_at = 0,
			error = NULL, updated_at = ? WHERE state <> 'running']], now)
	end
	return true
end

function Catalog:recoverMetadata()
	self:_rows("UPDATE metadata_jobs SET state = 'queued' WHERE state = 'running'")
end

function Catalog:claimMetadata(now)
	local job = self:_one([[SELECT j.*, w.kind, w.title, w.year, m.external_id, m.provider FROM metadata_jobs j
		JOIN works w ON w.id = j.work_id LEFT JOIN work_metadata m ON m.work_id = w.id
		WHERE j.state IN ('queued','matched','unmatched') AND j.next_run_at <= ?
		ORDER BY j.next_run_at, j.work_id LIMIT 1]], now)
	if job then self:_rows("UPDATE metadata_jobs SET state = 'running' WHERE work_id = ?", job.work_id) end
	return job
end

function Catalog:metadataWork(id)
	return self:_one("SELECT id, kind, title, year FROM works WHERE id = ? AND kind IN ('movie','show')", id)
end

function Catalog:metadataStatus()
	return self:_one([[SELECT
		(SELECT COALESCE(MAX(fetched_at), 0) FROM work_metadata) AS revision,
		(SELECT COUNT(*) FROM metadata_jobs WHERE state IN ('queued','running')) AS queued,
		(SELECT COUNT(*) FROM metadata_jobs WHERE state = 'matched') AS matched,
		(SELECT COUNT(*) FROM metadata_jobs WHERE state = 'unmatched') AS unmatched,
		(SELECT COUNT(*) FROM metadata_jobs WHERE state = 'failed') AS failed]])
end

function Catalog:unmatchedMetadata(job, reason, now, retry_at)
	self:_rows([[UPDATE metadata_jobs SET state = 'unmatched', attempts = 0, error = ?, updated_at = ?,
		next_run_at = ? WHERE work_id = ?]], reason, now, retry_at, job.work_id)
end

function Catalog:failMetadata(job, reason, now, retry_at)
	local attempts = (job.attempts or 0) + 1
	self:_rows([[UPDATE metadata_jobs SET state = ?, attempts = ?, error = ?, updated_at = ?,
		next_run_at = ? WHERE work_id = ?]], attempts >= 3 and "failed" or "queued", attempts,
		reason, now, retry_at, job.work_id)
end

--- Store provider facts without modifying a media file or overriding a local sidecar choice.
function Catalog:saveMetadata(work_id, facts, now, refresh_at)
	return self:batch(function()
		for _, field in ipairs({ "title", "year", "overview", "rating", "content_rating", "studio" }) do
			if facts[field] ~= nil then
				self:_rows("UPDATE works SET " .. field .. [[ = ? WHERE id = ? AND NOT EXISTS
					(SELECT 1 FROM metadata_local_fields WHERE work_id = ? AND field = ?)]], facts[field], work_id, work_id, field)
			end
		end
		local title = self:_one("SELECT title FROM works WHERE id = ?", work_id)
		if not title then return nil, "work no longer exists" end
		self:_rows("UPDATE works SET sort_key = ? WHERE id = ?", naming.sortKey(title.title), work_id)
		for _, pair in ipairs({ { "poster", "poster_url" }, { "backdrop", "backdrop_url" } }) do
			if facts[pair[2]] then
				self:_rows("UPDATE works SET " .. pair[2] .. [[ = ? WHERE id = ? AND NOT EXISTS
					(SELECT 1 FROM art WHERE work_id = ? AND kind = ? AND origin = 'library')]],
					facts[pair[2]], work_id, work_id, pair[1])
			end
		end
		if facts.backdrop_url then self:_rows("DELETE FROM art_jobs WHERE work_id = ?", work_id) end
		if facts.backdrop_url then self:_rows("DELETE FROM art WHERE work_id = ? AND kind = 'backdrop' AND origin = 'frame'", work_id) end
		for _, pair in ipairs({ { "genres", "genre" }, { "people", "person" } }) do
			if not self:_one("SELECT field FROM metadata_local_fields WHERE work_id = ? AND field = ?", work_id, pair[1]) then
				self:_rows("DELETE FROM work_tags WHERE work_id = ? AND kind = ?", work_id, pair[2])
				for _, tag in ipairs(facts[pair[1]] or {}) do
					self:_rows("INSERT OR IGNORE INTO work_tags (work_id, kind, value) VALUES (?, ?, ?)", work_id, pair[2], tag)
				end
			end
		end
		self:_rows([[INSERT INTO work_metadata (work_id, provider, external_id, source_url, fetched_at, facts)
			VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (work_id) DO UPDATE SET provider = excluded.provider,
			external_id = excluded.external_id, source_url = excluded.source_url, fetched_at = excluded.fetched_at,
			facts = excluded.facts]], work_id, facts.provider, tostring(facts.external_id), facts.source_url, now, require("cjson").encode(facts))
		self:_rows([[INSERT INTO metadata_jobs (work_id, state, updated_at, next_run_at) VALUES (?, 'matched', ?, ?)
			ON CONFLICT (work_id) DO UPDATE SET state = 'matched', attempts = 0, error = NULL,
			updated_at = excluded.updated_at, next_run_at = excluded.next_run_at]], work_id, now, refresh_at)
		return true
	end)
end

--- Every collection, oldest first, with its members when it has any.
function Catalog:collections()
	local rows = self:_rows("SELECT id, name, icon, rules FROM collections ORDER BY created_at, id")
	for _, row in ipairs(rows) do
		row.items = {}
		for i, member in ipairs(self:_rows(
			"SELECT work_id FROM collection_items WHERE collection_id = ? ORDER BY position, work_id", row.id)) do
			row.items[i] = member.work_id
		end
	end
	return rows
end

--- Save a collection. `rules` is a JSON string; a collection without one holds `items`.
function Catalog:addCollection(name, icon, rules, items, now)
	self:_rows("INSERT INTO collections (name, icon, rules, created_at) VALUES (?, ?, ?, ?)", name, icon, rules, now)
	local id = self:_one("SELECT MAX(id) AS id FROM collections").id
	for position, work_id in ipairs(items or {}) do
		self:_rows("INSERT OR IGNORE INTO collection_items (collection_id, work_id, position) VALUES (?, ?, ?)",
			id, work_id, position)
	end
	return id
end

function Catalog:deleteCollection(id)
	self:_rows("DELETE FROM collections WHERE id = ?", id)
end

--- Provider definitions people have added.
function Catalog:savedProviders()
	return self:_rows("SELECT id, def FROM providers ORDER BY added_at, id")
end

function Catalog:saveProvider(id, def, now)
	self:_rows([[INSERT INTO providers (id, def, added_at) VALUES (?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET def = excluded.def]], id, def, now)
end

--- Every source, with the library that holds its items.
function Catalog:sources()
	return self:_rows([[SELECT s.*, l.id AS library_id FROM sources s
		LEFT JOIN libraries l ON l.source_id = s.id ORDER BY s.created_at, s.id]])
end

function Catalog:source(id)
	return self:_one("SELECT * FROM sources WHERE id = ?", id)
end

function Catalog:addSource(provider_id, name, config, now)
	self:_rows("INSERT INTO sources (provider_id, name, config, created_at) VALUES (?, ?, ?, ?)", provider_id, name, config, now)
	return self:_one("SELECT * FROM sources WHERE id = (SELECT MAX(id) FROM sources)")
end

--- Remove a source, and with it the library it filled and everyone's progress on it.
function Catalog:deleteSource(id)
	self:_rows("DELETE FROM libraries WHERE source_id = ?", id)
	self:_rows("DELETE FROM sources WHERE id = ?", id)
end

--- The library that holds a source's items. Its root can never be a real folder.
function Catalog:sourceLibrary(source)
	local library = self:_one("SELECT * FROM libraries WHERE source_id = ?", source.id)
	if library then return library end
	local root = "source:" .. source.id
	self:_rows("INSERT INTO libraries (name, kind, root, source_id) VALUES (?, 'movie', ?, ?)", source.name, root, source.id)
	return self:_one("SELECT * FROM libraries WHERE root = ?", root)
end

function Catalog:sourceSynced(id, status, why, items, now)
	self:_rows("UPDATE sources SET status = ?, error = ?, items = ?, synced_at = ? WHERE id = ?", status, why, items, now, id)
end

--- The source a file came from.
function Catalog:sourceOfFile(file_id)
	return self:_one([[SELECT s.* FROM files f JOIN libraries l ON l.id = f.library_id
		JOIN sources s ON s.id = l.source_id WHERE f.id = ?]], file_id)
end

--- Record one item from a source.
-- @tparam number library_id
-- @tparam table entry `key`, `title`, `year`, `url`, `resolve`, `auth`, `overview`, `duration_ms`,
--   `poster_url`, `backdrop_url`
-- @tparam number scan
function Catalog:saveRemote(library_id, entry, scan)
	local parsed = { kind = "movie", title = entry.title, year = entry.year }
	if entry.kind == "episode" and type(entry.show) == "string" and tonumber(entry.episode) then
		parsed = { kind = "episode", show = entry.show, show_year = entry.show_year, season = tonumber(entry.season) or 1, episode = tonumber(entry.episode) }
	end
	self:noteFile(library_id, entry.key, 0, 0, scan, parsed)
	local remote = require("cjson").encode({ url = entry.url, key = entry.key, resolve = entry.resolve, auth = entry.auth })
	self:_rows("UPDATE files SET remote = ?, duration_ms = COALESCE(?, duration_ms) WHERE library_id = ? AND rel_path = ?",
		remote, entry.duration_ms, library_id, entry.key)
	self:_rows([[UPDATE works SET overview = COALESCE(?, overview), poster_url = ?, backdrop_url = ?
		WHERE id = (SELECT work_id FROM files WHERE library_id = ? AND rel_path = ?)]],
		entry.overview, entry.poster_url, entry.backdrop_url, library_id, entry.key)
	if parsed.kind == "episode" then
		local top = self:topWorkOfFile(library_id, entry.key)
		self:_rows([[UPDATE works SET overview = COALESCE(overview, ?), poster_url = COALESCE(poster_url, ?)
			WHERE id = ?]], entry.overview, entry.poster_url, top)
		self:_rows("UPDATE works SET title = ? WHERE id = (SELECT work_id FROM files WHERE library_id = ? AND rel_path = ?)", entry.title, library_id, entry.key)
	end
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
	title = { [[SELECT id, kind, title, year, sort_key, added_at,
			(SELECT group_concat(kind) FROM art WHERE work_id = works.id) AS art,
			(SELECT group_concat(value) FROM work_tags WHERE work_id = works.id AND kind = 'genre') AS genres,
			(SELECT MAX(duration_ms) FROM files WHERE work_id = works.id) AS duration_ms,
			(SELECT MAX(s.height) FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video') AS height,
			(SELECT s.codec FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video' LIMIT 1) AS vcodec,
			(SELECT MAX(s.hdr) FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video') AS hdr,
			(SELECT watched FROM user_progress WHERE user = ? AND work_id = works.id) AS watched,
		(SELECT COUNT(*) FROM works s WHERE s.parent_id = works.id) AS seasons,
		(SELECT COUNT(*) FROM works s JOIN works e ON e.parent_id = s.id WHERE s.parent_id = works.id) AS episodes,
		(SELECT COUNT(*) FROM works s JOIN works e ON e.parent_id = s.id LEFT JOIN user_progress p
			ON p.work_id = e.id AND p.user = ? WHERE s.parent_id = works.id AND COALESCE(p.watched, 0) = 0) AS unwatched,
			overview, rating, library_id, poster_url, backdrop_url FROM works
		WHERE library_id = ? AND kind IN ('movie', 'show') AND (sort_key, id) > (?, ?)
		ORDER BY sort_key, id LIMIT ?]], "sort_key" },
	added = { [[SELECT id, kind, title, year, sort_key, added_at,
			(SELECT group_concat(kind) FROM art WHERE work_id = works.id) AS art,
			(SELECT group_concat(value) FROM work_tags WHERE work_id = works.id AND kind = 'genre') AS genres,
			(SELECT MAX(duration_ms) FROM files WHERE work_id = works.id) AS duration_ms,
			(SELECT MAX(s.height) FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video') AS height,
			(SELECT s.codec FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video' LIMIT 1) AS vcodec,
			(SELECT MAX(s.hdr) FROM files f JOIN streams s ON s.file_id = f.id WHERE f.work_id = works.id AND s.kind = 'video') AS hdr,
			(SELECT watched FROM user_progress WHERE user = ? AND work_id = works.id) AS watched,
			(SELECT COUNT(*) FROM works s WHERE s.parent_id = works.id) AS seasons,
			(SELECT COUNT(*) FROM works s JOIN works e ON e.parent_id = s.id WHERE s.parent_id = works.id) AS episodes,
			(SELECT COUNT(*) FROM works s JOIN works e ON e.parent_id = s.id LEFT JOIN user_progress p
				ON p.work_id = e.id AND p.user = ? WHERE s.parent_id = works.id AND COALESCE(p.watched, 0) = 0) AS unwatched,
			overview, rating, library_id, poster_url, backdrop_url FROM works
			WHERE library_id = ? AND kind IN ('movie', 'show') AND (added_at, id) < (?, ?)
		ORDER BY added_at DESC, id DESC LIMIT ?]], "added_at" },
}

--- One page of a library.
-- @tparam table opts `sort` (`title`, `added`), `limit`, `after_key`, `after_id`, `user`
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
	local user = opts.user or ""
	local rows = self:_rows(spec[1], user, user, library_id, key, id, limit + 1)
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
	work.files = self:_rows([[SELECT id, rel_path, size, container, duration_ms, bitrate, missing_at, probe_error,
		remote IS NOT NULL AS is_remote FROM files WHERE work_id = ? ORDER BY id]], id)
	for _, file in ipairs(work.files) do
		file.streams = self:_rows([[SELECT idx, kind, codec, language, title, channels, width, height, hdr,
			is_default, is_forced FROM streams WHERE file_id = ? ORDER BY idx]], file.id)
	end
	work.children = self:_rows([[SELECT id, kind, title, season, episode FROM works
		WHERE parent_id = ? ORDER BY season, episode, id LIMIT 1000]], id)
	work.people, work.genres = {}, {}
	for _, tag in ipairs(self:_rows("SELECT kind, value FROM work_tags WHERE work_id = ? ORDER BY value LIMIT 64", id)) do
		local list = tag.kind == "genre" and work.genres or work.people
		list[#list + 1] = tag.value
	end
	work.progress = self:_one(
		"SELECT position_ms, watched, updated_at FROM user_progress WHERE user = ? AND work_id = ?", user, id)
	work.metadata = self:_one("SELECT provider, external_id, source_url, fetched_at, facts FROM work_metadata WHERE work_id = ?", id)
	if work.metadata then
		local ok, facts = pcall(require("cjson").decode, work.metadata.facts)
		work.metadata.facts = nil
		if ok and type(facts) == "table" then
			work.metadata.cast, work.metadata.original_title, work.metadata.tagline = facts.cast, facts.original_title, facts.tagline
		end
	end
	return work
end

--- A show's seasons with their episodes and this user's progress. Bounded by the show's size,
-- which a person chose, so a show is one query rather than a page.
-- @tparam number show_id
-- @tparam string user
-- @treturn table seasons, in order
function Catalog:episodes(show_id, user)
	local rows = self:_rows([[SELECT s.id AS season_id, s.title AS season_title, s.season, e.id, e.title, e.episode,
		(SELECT MAX(duration_ms) FROM files WHERE work_id = e.id) AS duration_ms, p.position_ms, p.watched
		FROM works s JOIN works e ON e.parent_id = s.id
		LEFT JOIN user_progress p ON p.work_id = e.id AND p.user = ?
		WHERE s.parent_id = ? ORDER BY s.season, e.episode, e.id LIMIT 10000]], user, show_id)
	local seasons, by_id = {}, {}
	for _, row in ipairs(rows) do
		local season = by_id[row.season_id]
		if not season then
			season = { season = row.season, title = row.season_title, episodes = {} }
			by_id[row.season_id] = season
			seasons[#seasons + 1] = season
		end
		season.episodes[#season.episodes + 1] = { id = row.id, title = row.title, episode = row.episode,
			duration_ms = row.duration_ms, position_ms = row.position_ms, watched = row.watched }
	end
	return seasons
end

--- Mark a work watched or not, and everything under it: a show carries its episodes.
function Catalog:setWatched(user, work_id, watched, now)
	return self.db:transaction(function()
		for _, row in ipairs(self:_rows([[WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL
			SELECT w.id FROM works w JOIN tree ON w.parent_id = tree.id) SELECT id FROM tree]], work_id)) do
			self:_rows([[INSERT INTO user_progress (user, work_id, position_ms, watched, updated_at) VALUES (?, ?, 0, ?, ?)
				ON CONFLICT (user, work_id) DO UPDATE SET position_ms = 0, watched = excluded.watched,
				updated_at = excluded.updated_at]], user, row.id, watched and 1 or 0, now)
		end
		return true
	end)
end

--- The file behind a streaming request, with the root it must stay inside.
function Catalog:fileTarget(file_id)
	return self:_one([[SELECT f.id, f.rel_path, f.container, f.missing_at, f.size, f.remote, l.root
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
	return self:_rows([[SELECT w.id, w.kind, w.title, w.year, p.position_ms, p.updated_at,
		(SELECT MAX(duration_ms) FROM files WHERE work_id = w.id) AS duration_ms
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
	self:_rows("UPDATE art_jobs SET state = 'queued' WHERE state = 'running'")
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
	self:queueFrame(job.file_id)
	if info.facts then
		local work = self:_one("SELECT work_id FROM files WHERE id = ?", job.file_id)
		if work then self:saveFacts(work.work_id, info.facts, false) end
	end
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

--- Read the facts the repair workbench describes. Never expose source credentials.
function Catalog:repairData()
	return {
		offline = self:_rows([[SELECT l.id, l.name, COUNT(*) AS count FROM files f
			JOIN libraries l ON l.id = f.library_id WHERE f.missing_at IS NOT NULL
			GROUP BY l.id, l.name ORDER BY l.id]]),
		analysis = self:_rows([[SELECT f.id, w.title, j.error FROM jobs j JOIN files f ON f.id = j.file_id
			JOIN works w ON w.id = f.work_id WHERE j.state = 'failed' ORDER BY f.id]]),
		frames = self:_rows([[SELECT w.id, w.title, j.error FROM art_jobs j JOIN works w ON w.id = j.work_id
			WHERE j.state = 'failed' ORDER BY w.id]]),
		sources = self:_rows("SELECT id, name, error FROM sources WHERE status = 'failed' ORDER BY id"),
	}
end

function Catalog:retryAnalysis(id)
	if not self:_one([[SELECT j.id FROM jobs j JOIN files f ON f.id = j.file_id
		WHERE f.id = ? AND f.missing_at IS NULL AND j.state = 'failed']], id) then return false end
	self:_rows("UPDATE jobs SET state = 'queued', attempts = 0, next_run_at = 0, error = NULL WHERE file_id = ?", id)
	self:_rows("UPDATE files SET probe_error = NULL WHERE id = ?", id)
	return true
end

function Catalog:retryFrame(id)
	if not self:_one([[SELECT j.work_id FROM art_jobs j JOIN files f ON f.id = j.file_id
		WHERE j.work_id = ? AND j.state = 'failed' AND f.missing_at IS NULL]], id) then return false end
	self:_rows("UPDATE art_jobs SET state = 'queued', error = NULL WHERE work_id = ?", id)
	return true
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
