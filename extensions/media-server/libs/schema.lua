--- The catalog schema. Migrations only ever add steps; a shipped step never changes.
-- A work is what a person watches, a file is one copy of it, and a stream is one track
-- in a file, so a second encode of a film adds a file and never a second film.
-- @module libs.schema

local M = {}

M.VERSION = 1

local V1 = {
	[[CREATE TABLE libraries (
		id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('movie', 'show')),
		root TEXT NOT NULL UNIQUE, scanned_at INTEGER, scan_count INTEGER NOT NULL DEFAULT 0,
		available INTEGER NOT NULL DEFAULT 1
	)]],
	[[CREATE TABLE works (
		id INTEGER PRIMARY KEY, library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
		parent_id INTEGER REFERENCES works(id) ON DELETE CASCADE,
		kind TEXT NOT NULL CHECK (kind IN ('movie', 'show', 'season', 'episode')),
		identity TEXT NOT NULL, title TEXT NOT NULL, sort_key TEXT NOT NULL, year INTEGER,
		season INTEGER, episode INTEGER, added_at INTEGER NOT NULL,
		UNIQUE (library_id, identity)
	)]],
	"CREATE INDEX works_browse ON works (library_id, kind, sort_key, id)",
	"CREATE INDEX works_recent ON works (library_id, kind, added_at DESC, id)",
	"CREATE INDEX works_children ON works (parent_id, season, episode, id)",
	[[CREATE TABLE files (
		id INTEGER PRIMARY KEY, library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
		work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
		rel_path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL, seen_scan INTEGER NOT NULL,
		missing_at INTEGER, probed_stamp TEXT, container TEXT, duration_ms INTEGER, bitrate INTEGER, probe_error TEXT,
		UNIQUE (library_id, rel_path)
	)]],
	"CREATE INDEX files_work ON files (work_id, id)",
	[[CREATE TABLE streams (
		id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
		idx INTEGER NOT NULL, kind TEXT NOT NULL, codec TEXT, language TEXT, title TEXT, channels INTEGER,
		width INTEGER, height INTEGER, hdr INTEGER NOT NULL DEFAULT 0,
		is_default INTEGER NOT NULL DEFAULT 0, is_forced INTEGER NOT NULL DEFAULT 0,
		UNIQUE (file_id, idx)
	)]],
	[[CREATE TABLE user_progress (
		user TEXT NOT NULL, work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
		position_ms INTEGER NOT NULL DEFAULT 0, watched INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
		PRIMARY KEY (user, work_id)
	) WITHOUT ROWID]],
	"CREATE INDEX progress_recent ON user_progress (user, updated_at DESC)",
	[[CREATE TABLE jobs (
		id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE,
		state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'failed')),
		attempts INTEGER NOT NULL DEFAULT 0, next_run_at INTEGER NOT NULL DEFAULT 0, error TEXT
	)]],
	"CREATE INDEX jobs_ready ON jobs (state, next_run_at, id)",
}

--- Bring a database up to `VERSION`.
function M.migrate(db)
	return db:migrate(M.VERSION, function(d, previous)
		if previous < 1 then
			for _, statement in ipairs(V1) do
				local done, why = d:exec(statement)
				if not done then return nil, why end
			end
		end
		return true
	end)
end

return M
