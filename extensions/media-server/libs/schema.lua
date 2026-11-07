--- The catalog schema. Migrations only ever add steps; a shipped step never changes.
-- A work is what a person watches, a file is one copy of it, and a stream is one track
-- in a file, so a second encode of a film adds a file and never a second film.
-- @module libs.schema

local M = {}

M.VERSION = 5

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

-- Art a person keeps beside their files is found by the scanner. A frame is taken from the
-- file for anything without one, and is only ever one row of `art_jobs` at a time.
local V2 = {
	[[CREATE TABLE art (
		work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
		kind TEXT NOT NULL CHECK (kind IN ('poster', 'backdrop')),
		origin TEXT NOT NULL CHECK (origin IN ('library', 'frame')), path TEXT NOT NULL,
		PRIMARY KEY (work_id, kind)
	) WITHOUT ROWID]],
	[[CREATE TABLE art_jobs (
		work_id INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE,
		file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
		state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'failed')),
		error TEXT
	)]],
}

-- What people keep beside their files, or in them. Collections are stored as written: a smart
-- one is a rule set the clients evaluate, so the server never has to guess at a new field.
local V3 = {
	"ALTER TABLE works ADD COLUMN overview TEXT",
	"ALTER TABLE works ADD COLUMN rating REAL",
	"ALTER TABLE works ADD COLUMN content_rating TEXT",
	"ALTER TABLE works ADD COLUMN studio TEXT",
	[[CREATE TABLE work_tags (
		work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
		kind TEXT NOT NULL CHECK (kind IN ('genre', 'person')), value TEXT NOT NULL,
		PRIMARY KEY (work_id, kind, value)
	) WITHOUT ROWID]],
	"CREATE INDEX work_tags_value ON work_tags (kind, value, work_id)",
	[[CREATE TABLE collections (
		id INTEGER PRIMARY KEY, name TEXT NOT NULL, icon TEXT, rules TEXT, created_at INTEGER NOT NULL
	)]],
	[[CREATE TABLE collection_items (
		collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
		work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
		position INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (collection_id, work_id)
	) WITHOUT ROWID]],
}

-- A source's items are ordinary works in a library of their own, whose files have an address
-- instead of a path. Provider definitions people add are stored as the data they are.
local V4 = {
	"ALTER TABLE libraries ADD COLUMN source_id INTEGER",
	"ALTER TABLE files ADD COLUMN remote TEXT",
	"ALTER TABLE works ADD COLUMN poster_url TEXT",
	"ALTER TABLE works ADD COLUMN backdrop_url TEXT",
	[[CREATE TABLE providers (id TEXT PRIMARY KEY, def TEXT NOT NULL, added_at INTEGER NOT NULL) WITHOUT ROWID]],
	[[CREATE TABLE sources (
		id INTEGER PRIMARY KEY, provider_id TEXT NOT NULL, name TEXT NOT NULL, config TEXT NOT NULL,
		enabled INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'new', error TEXT,
		items INTEGER NOT NULL DEFAULT 0, synced_at INTEGER, created_at INTEGER NOT NULL
	)]],
}

-- Provider metadata is separate from media files. Local sidecar fields remain authoritative.
local V5 = {
	[[CREATE TABLE metadata_local_fields (
		work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE, field TEXT NOT NULL,
		PRIMARY KEY (work_id, field)
	) WITHOUT ROWID]],
	[[CREATE TABLE work_metadata (
		work_id INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE,
		provider TEXT NOT NULL, external_id TEXT NOT NULL, source_url TEXT NOT NULL,
		fetched_at INTEGER NOT NULL, facts TEXT NOT NULL
	)]],
	[[CREATE TABLE metadata_jobs (
		work_id INTEGER PRIMARY KEY REFERENCES works(id) ON DELETE CASCADE,
		state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','matched','unmatched','failed')),
		attempts INTEGER NOT NULL DEFAULT 0, next_run_at INTEGER NOT NULL DEFAULT 0,
		error TEXT, updated_at INTEGER NOT NULL DEFAULT 0
	)]],
	"CREATE INDEX metadata_jobs_ready ON metadata_jobs (state, next_run_at, work_id)",
	-- Older versions did not record provenance: preserve existing descriptive facts conservatively.
	[[INSERT INTO metadata_local_fields (work_id, field)
		SELECT id, 'overview' FROM works WHERE overview IS NOT NULL AND overview <> '']],
	[[INSERT INTO metadata_local_fields (work_id, field)
		SELECT id, 'rating' FROM works WHERE rating IS NOT NULL]],
	[[INSERT INTO metadata_local_fields (work_id, field)
		SELECT id, 'studio' FROM works WHERE studio IS NOT NULL AND studio <> '']],
	[[INSERT INTO metadata_local_fields (work_id, field)
		SELECT id, 'content_rating' FROM works WHERE content_rating IS NOT NULL AND content_rating <> '']],
	[[INSERT OR IGNORE INTO metadata_local_fields (work_id, field)
		SELECT work_id, CASE kind WHEN 'genre' THEN 'genres' ELSE 'people' END FROM work_tags]],
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
		if previous < 2 then
			for _, statement in ipairs(V2) do
				local done, why = d:exec(statement)
				if not done then return nil, why end
			end
		end
		if previous < 3 then
			for _, statement in ipairs(V3) do
				local done, why = d:exec(statement)
				if not done then return nil, why end
			end
		end
		if previous < 4 then
			for _, statement in ipairs(V4) do
				local done, why = d:exec(statement)
				if not done then return nil, why end
			end
		end
		if previous < 5 then
			for _, statement in ipairs(V5) do
				local done, why = d:exec(statement)
				if not done then return nil, why end
			end
		end
		return true
	end)
end

return M
