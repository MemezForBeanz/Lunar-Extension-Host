--- Sources: libraries that live somewhere else.
-- A source is a provider plus what a person filled in. Syncing turns its answer into ordinary
-- catalog rows in a library of its own, so Home, filters and collections need no special cases.
-- A file from a source has an address instead of a path, and the desktop plays it directly.
-- @module libs.sources

local cjson = require("cjson")
local providers = require("libs.providers")
local lfs = require("lfs")

local Sources = {}
Sources.__index = Sources

local M = {}

M.RESYNC_S = 6 * 3600
M.TORRENT_PORT = 18721
M.TORRENT_START_S = 45
M.FETCH_LIMIT = 16 * 1024 * 1024
M.TIMEOUT_S = 30
M.DOWNLOAD_LIMIT = 8 * 1024 * 1024 * 1024
M.MAX_DOWNLOADS = 2
M.MAX_QUEUED_DOWNLOADS = 32
M.PROGRESS_BYTES = 256 * 1024
M.PROGRESS_S = 1

--- Create the manager.
-- @tparam table opts `catalog`, `http(request, done)`, `get_secret(name)`, `set_secret(name, value)`,
--   `delete_secret(name)`, `spawn(argv)`, `now()`, `log`, `torrent_engine`
function M.new(opts)
	local self = setmetatable({ catalog = opts.catalog, http = opts.http, get_secret = opts.get_secret,
		set_secret = opts.set_secret, delete_secret = opts.delete_secret, spawn = opts.spawn, now = opts.now, log = opts.log,
		torrent_engine = opts.torrent_engine, on_scan = opts.on_scan, syncing = {}, opened = {}, downloads = {}, download_dir = opts.download_dir }, Sources)
	self.discovery = require("libs.discovery").new({ http = opts.http, spawn = opts.spawn, extractor = opts.extractor,
		now = opts.now, providers = function() return self:providers() end })
	return self
end

local function safe_rel(key, title)
	local value = type(key) == "string" and key or ""
	value = value:gsub("\\", "/"):gsub("^/+", "")
	local parts = {}
	for part in value:gmatch("[^/]+") do
		if part ~= "." and part ~= ".." and not part:find(":", 1, true) then parts[#parts + 1] = part end
	end
	if #parts == 0 then parts[1] = title end
	local leaf = parts[#parts]:gsub("[<>:\"|%?%*]", "_")
	if not leaf:match("%.[%w]+$") then leaf = leaf .. ".mp4" end
	parts[#parts] = leaf
	return table.concat(parts, "/")
end

local function mkdirs(root, rel)
	local current = root
	for part in rel:gmatch("[^/]+") do
		current = current .. "/" .. part
		lfs.mkdir(current)
	end
end

local function safe_path(root, rel)
	if type(rel) ~= "string" or rel == "" or rel:match("^[\\/]")
		or rel:match("^[%a]:") then return nil, "invalid destination path" end
	local current = root
	for part in rel:gmatch("[^/\\]+") do
		if part == "." or part == ".." or part:find("[:<>\"|%?%*]") or part:match("[ .]$") then
			return nil, "invalid destination path"
		end
		current = current .. "/" .. part
		local link_attr = lfs.symlinkattributes and lfs.symlinkattributes(current)
		if link_attr and link_attr.mode == "link" then return nil, "destination contains a link" end
	end
	return root .. "/" .. rel
end

local function decode(text)
	local ok, data = pcall(cjson.decode, text or "")
	return ok and type(data) == "table" and data or nil
end

local function manifest_url(address)
	return type(address) == "string" and address:lower():match("^[^?#]*"):match("%.m3u8$") ~= nil
end

--- Every provider a source can be made from: those Lunar ships and those people have added.
function Sources:providers()
	local out = {}
	for _, provider in ipairs(providers.BUILTIN) do out[#out + 1] = provider end
	for _, provider in ipairs(require("libs.websources").SITES) do out[#out + 1] = provider end
	for _, row in ipairs(self.catalog:savedProviders()) do
		local def = decode(row.def)
		if def then
			def.added = true
			out[#out + 1] = def
		end
	end
	return out
end

function Sources:_provider(id)
	for _, provider in ipairs(self:providers()) do
		if provider.id == id then return provider end
	end
end

--- Add a provider to the database.
-- @tparam table def
-- @treturn[1] table the clean definition
-- @treturn[2] nil
-- @treturn[2] string why
function Sources:addProvider(def)
	local clean, why = providers.validate(def)
	if not clean then return nil, why end
	for _, provider in ipairs(providers.BUILTIN) do
		if provider.id == clean.id then return nil, "that id belongs to a built-in provider" end
	end
	self.catalog:saveProvider(clean.id, cjson.encode(clean), self.now())
	return clean
end

function Sources:_config(source)
	local provider = self:_provider(source.provider_id)
	local config = decode(source.config) or {}
	for _, field in ipairs(provider and provider.fields or {}) do
		if field.secret then config[field.id] = self.get_secret(string.format("source-%d-%s", source.id, field.id)) end
	end
	return config, provider
end

--- Add a source and start its first sync.
-- @tparam table body `provider`, `name`, `config`, `accept_notice`
-- @treturn[1] table the source
-- @treturn[2] nil
-- @treturn[2] string why
function Sources:add(body)
	local provider = self:_provider(body.provider)
	if not provider then return nil, "no such provider" end
	if provider.off_by_default and body.accept_notice ~= true then
		return nil, "torrents stay off until the notice is accepted"
	end
	local given = type(body.config) == "table" and body.config or {}
	local stored, secrets = {}, {}
	for _, field in ipairs(provider.fields or {}) do
		local value = given[field.id]
		if field.secret then secrets[field.id] = value else stored[field.id] = value end
	end
	local probe = {}
	for key, value in pairs(given) do probe[key] = value end
	local request, why = providers.request(provider, probe)
	if not request then return nil, why end
	local name = type(body.name) == "string" and body.name ~= "" and body.name or provider.name
	local source = self.catalog:addSource(provider.id, name, cjson.encode(stored), self.now())
	for id, value in pairs(secrets) do
		if type(value) == "string" and value ~= "" then
			local saved, problem = self.set_secret(string.format("source-%d-%s", source.id, id), value)
			if not saved then
				self.catalog:deleteSource(source.id)
				return nil, "could not keep that secret safely: " .. tostring(problem)
			end
		end
	end
	self:sync(source.id)
	return source
end

--- Remove a source and everything it brought.
function Sources:remove(id)
	local source = self.catalog:source(id)
	if not source then return false end
	local provider = self:_provider(source.provider_id)
	for _, field in ipairs(provider and provider.fields or {}) do
		if field.secret then self.delete_secret(string.format("source-%d-%s", id, field.id)) end
	end
	self.catalog:deleteSource(id)
	return true
end

function Sources:_store(source, entries)
	local library = self.catalog:sourceLibrary(source)
	local scan = (library.scan_count or 0) + 1
	self.catalog:batch(function()
		for _, entry in ipairs(entries) do self.catalog:saveRemote(library.id, entry, scan) end
		self.catalog:finishScan(library.id, scan, self.now())
		return true
	end)
	self.catalog:sourceSynced(source.id, "ok", nil, #entries, self.now())
	if self.log then self.log:info(string.format("source %s: %d items", source.name, #entries)) end
end

--- Fetch a source and refresh its library. Never waits: the answer arrives later.
function Sources:sync(id)
	local source = self.catalog:source(id)
	if not source or self.syncing[id] then return end
	local config, provider = self:_config(source)
	if config.saved_discoveries then return end
	if not provider then return self.catalog:sourceSynced(id, "failed", "its provider is gone", 0, self.now()) end
	if config.website_series then
		local job, problem = self.discovery:begin({ provider = provider.id, url = config.website_series, details = true })
		if not job then return self.catalog:sourceSynced(id, "failed", problem, source.items or 0, self.now()) end
		self.series_sync = self.series_sync or {}
		self.series_sync[id] = job.id
		self.syncing[id] = true
		return
	end
	local request, why = providers.request(provider, config)
	if not request then return self.catalog:sourceSynced(id, "failed", why, 0, self.now()) end
	if request.local_text then return self:_store(source, providers.parse(provider, config, request.local_text)) end
	self.syncing[id] = true
	request.timeout, request.max_bytes = M.TIMEOUT_S, M.FETCH_LIMIT
	self.http(request, function(response, err)
		self.syncing[id] = nil
		if not response or not response.ok then
			local problem = response and ("it answered " .. tostring(response.status)) or tostring(err or "no answer")
			return self.catalog:sourceSynced(id, "failed", problem, source.items or 0, self.now())
		end
		self:_store(source, providers.parse(provider, config, response.body or ""))
	end)
end

--- Refresh sources that are due.
function Sources:tick()
	local now = self.now()
	for id, job_id in pairs(self.series_sync or {}) do
		local source, job = self.catalog:source(id), self.discovery:poll(job_id)
		if not source or not job or job.state == "failed" or job.state == "ready" then
			self.series_sync[id], self.syncing[id] = nil, nil
			if source then
				if job and job.state == "ready" and not job.result.truncated then
					local episodes = {}
					for _, entry in ipairs(job.result.items or {}) do if entry.kind == "episode" then episodes[#episodes + 1] = entry end end
					if #episodes > 0 then self:_store(source, episodes)
					else self.catalog:sourceSynced(id, "failed", "No playable episode entries were returned. Open the source to inspect it.", source.items or 0, now) end
				else self.catalog:sourceSynced(id, "failed", job and job.result and job.result.truncated and
					"This episode list reached the adapter's page limit. Existing episodes were kept; save entries individually or use a paginated adapter."
					or (job and job.error or "Source discovery expired."), source.items or 0, now) end
			end
		end
	end
	for _, source in ipairs(self.catalog:sources()) do
		if source.enabled == 1 and now - (source.synced_at or 0) >= M.RESYNC_S then self:sync(source.id) end
	end
	self:_tick_torrent(now)
end

--- Sources for the API, without anything secret.
function Sources:list()
	local out = {}
	for _, source in ipairs(self.catalog:sources()) do
		local provider = self:_provider(source.provider_id)
		out[#out + 1] = { id = source.id, name = source.name, provider = source.provider_id,
			provider_name = provider and provider.name, kind = provider and provider.kind, status = source.status,
			error = source.error, items = source.items, synced_at = source.synced_at, library_id = source.library_id }
	end
	return out
end

-- Opening ------------------------------------------------------------------------

function Sources:_finish_open(file_id, answer)
	self.opened[file_id] = answer
end

--- Save an explicitly selected discovery result, without removing previously saved titles.
function Sources:importDiscovery(id, key)
	local entry, provider = self.discovery:entry(id, key)
	if not entry then return nil, provider end
	if entry.is_series then
		local source
		for _, candidate in ipairs(self.catalog:sources()) do
			local config = decode(candidate.config)
			if candidate.provider_id == provider.id and config and config.website_series == entry.url then source = candidate; break end
		end

		if not source then source = self.catalog:addSource(provider.id, entry.title, cjson.encode({ website_series = entry.url }), self.now()) end
		local library = self.catalog:sourceLibrary(source)
		self:sync(source.id)
		return { source_id = source.id, library_id = library.id, title = entry.title, syncing = true }
	end
	local source
	for _, candidate in ipairs(self.catalog:sources()) do
		local config = decode(candidate.config)
		if candidate.provider_id == provider.id and config and config.saved_discoveries then source = candidate; break end
	end
	if not source then source = self.catalog:addSource(provider.id, provider.name .. " — saved titles", cjson.encode({ saved_discoveries = true }), self.now()) end
	local library = self.catalog:sourceLibrary(source)
	self.catalog:batch(function()
		self.catalog:saveRemote(library.id, entry, library.scan_count or 0)
		local count = self.catalog:_one("SELECT COUNT(*) AS count FROM works WHERE library_id = ? AND kind IN ('movie', 'show')", library.id).count
		self.catalog:sourceSynced(source.id, "ok", nil, count, self.now())
		return true
	end)
	return { source_id = source.id, library_id = library.id, title = entry.title }
end

--- Download a direct discovered file into an existing server library.
function Sources:downloadDiscovery(discovery_id, entry_key, library_id)
	local entry, provider = self.discovery:entry(discovery_id, entry_key)
	if not entry then return nil, provider end
	local library = self.catalog:library(tonumber(library_id) or 0)
	if not library or library.source_id then return nil, "choose an existing local library" end
	local archive = entry.resolve == "archive" and provider.kind == "archive"
	local webpage = entry.resolve == "webpage" and require("libs.websources").web(entry.url)
	local transfer_url = entry.url
	local source_url = entry.source_url or entry.page_url
	if archive then
		if type(entry.key) ~= "string" or not entry.key:match("^[%w%._-]+$") then
			return nil, "this Archive result has an invalid identifier"
		end
		source_url = "https://archive.org/details/" .. entry.key
	elseif not webpage and (type(transfer_url) ~= "string" or not transfer_url:match("^https?://") or
		(entry.resolve and entry.resolve ~= "direct")) then
		return nil, "this result is a catalogue or streaming entry, not a direct downloadable file"
	end
	if manifest_url(transfer_url) then
		return nil, "manifest downloads are not supported"
	end
	if not source_url then source_url = transfer_url end
	if self.catalog:downloadCount({ "queued", "running" }) >= M.MAX_QUEUED_DOWNLOADS then
		return nil, "too many downloads are queued"
	end
	local rel = safe_rel(entry.key, entry.title or "download")
	local stem, extension = rel:match("^(.*)(%.[^./]+)$")
	local suffix = 2
	while true do
		local absolute = safe_path(library.root, rel)
		if not absolute then return nil, "invalid destination path" end
		if not lfs.attributes(absolute, "mode") and not self.catalog:downloadPathInUse(library.id, rel) then break end
		rel = (stem or rel) .. " (" .. suffix .. ")" .. (extension or "")
		suffix = suffix + 1
	end
	local absolute = assert(safe_path(library.root, rel))
	local temp = absolute .. ".lunar-part"
	local parent = rel:match("^(.*)/[^/]+$")
	if parent then mkdirs(library.root, parent) end
	local row = self.catalog:addDownload({ library_id = library.id, source_id = nil, provider_id = provider.id,
		source_url = source_url, transfer_url = not webpage and transfer_url or nil,
		resolve_url = webpage and entry.url or nil,
		request_headers = entry.headers and cjson.encode(entry.headers) or nil,
		rel_path = rel, temp_path = temp, title = entry.title or rel, now = self.now() })
	self:_start_download(row)
	return self.catalog:publicDownload(self.catalog:download(row.id))
end

function Sources:_start_download(row)
	if self.downloads[row.id] then return end
	if self:_active_downloads() >= M.MAX_DOWNLOADS then return end
	local library = self.catalog:library(row.library_id)
	if not library then return self:_fail_download(row, "destination library was removed") end
	local destination, path_error = safe_path(library.root, row.rel_path)
	if not destination or self.catalog:downloadPathInUse(row.library_id, row.rel_path, row.id)
		or lfs.attributes(destination, "mode") then
		return self:_fail_download(row, path_error or "destination already exists")
	end
	local parent = row.rel_path:match("^(.*)/[^/]+$")
	if parent then mkdirs(self.catalog:library(row.library_id).root, parent) end
	self.catalog:updateDownload(row.id, { state = "running", updated_at = self.now() })
	if row.resolve_url and not row.resolved then return self:_resolve_web_download(row) end
	if not row.transfer_url then
		if row.source_url:match("^https://archive%.org/details/[%w%._-]+$") then
			return self:_resolve_archive_download(row)
		end
		row.transfer_url = row.source_url
		self.catalog:updateDownload(row.id, { transfer_url = row.transfer_url, updated_at = self.now() })
	end
	local file, why = io.open(row.temp_path, "wb")
	if not file then
		self.catalog:updateDownload(row.id, { state = "failed", error = "could not create temporary file: " .. tostring(why), updated_at = self.now() })
		self:resumeDownloads()
		return
	end

	local run = { row = row, file = file, handle = nil, bytes = 0, sample = "", last_flush = self.now(), cancelled = false }
	self.downloads[row.id] = run
	local request_headers = decode(row.request_headers) or {}
	if request_headers[1] then
		local mapped = {}
		for _, line in ipairs(request_headers) do
			local name, value = tostring(line):match("^([^:]+):%s*(.*)$")
			if name and value then mapped[name] = value end
		end
		request_headers = mapped
	end
	run.handle = self.http({ url = row.transfer_url, method = "GET", timeout = M.TIMEOUT_S, max_bytes = M.DOWNLOAD_LIMIT,
		headers = request_headers,
		sink = function(chunk)
			if run.cancelled or not run.file then return nil, "download cancelled" end
			local ok, write_error = run.file:write(chunk)
			if not ok then return nil, write_error end
			run.bytes = run.bytes + #chunk
			if #run.sample < 256 then run.sample = run.sample .. chunk:sub(1, 256 - #run.sample) end
			local now = self.now()
			if run.bytes >= (run.flushed_bytes or 0) + M.PROGRESS_BYTES or now - run.last_flush >= M.PROGRESS_S then
				self.catalog:updateDownload(row.id, { bytes = run.bytes, updated_at = now })
				run.flushed_bytes, run.last_flush = run.bytes, now
			end
			return true
		end }, function(response, err)
		if run.cancelled then return end
		self.downloads[row.id] = nil
		local closed, close_error = run.file:close()
		run.file = nil
		if not closed then return self:_fail_download(row, "could not close temporary file: " .. tostring(close_error)) end
		local total = response and response.headers and (response.headers["content-length"] or response.headers["Content-Length"])
		total = total and tonumber(total)
		if total then self.catalog:updateDownload(row.id, { total_bytes = total, updated_at = self.now() }) end
		if not response or not response.ok then
			return self:_fail_download(row, response and ("HTTP " .. tostring(response.status)) or tostring(err or "download failed"))
		end
		local content_type = response.headers and (response.headers["content-type"] or response.headers["Content-Type"]) or ""
		if run.bytes == 0 then return self:_fail_download(row, "download returned no bytes") end
		local sample = run.sample:lower():gsub("^%s+", "")
		if content_type:lower():match("text/html") or content_type:lower():match("mpegurl")
			or sample:match("^<!doctype html") or sample:match("^<html") or sample:match("^#extm3u")
			or manifest_url(row.transfer_url) then
			return self:_fail_download(row, "download response is not a direct media file")
		end
		if total and total ~= run.bytes then return self:_fail_download(row, "content length did not match downloaded bytes") end
		library = self.catalog:library(row.library_id)
		if not library then return self:_fail_download(row, "destination library was removed") end
		destination, path_error = safe_path(library.root, row.rel_path)
		if not destination or self.catalog:downloadPathInUse(row.library_id, row.rel_path, row.id)
			or lfs.attributes(destination, "mode") or not os.rename(row.temp_path, destination) then
			os.remove(row.temp_path)
			return self:_fail_download(row, path_error or "could not finalize downloaded file")
		end
		self.catalog:updateDownload(row.id, { state = "complete", bytes = run.bytes, updated_at = self.now() })
		if self.on_scan then self.on_scan(self.catalog:library(row.library_id)) end
			self:resumeDownloads()
	end)
end

function Sources:_resolve_web_download(row)
	local run = { row = row, resolving = true, cancelled = false }
	self.downloads[row.id] = run
	local id = self.discovery:resolve(row.resolve_url, function(answer, why)
		if run.cancelled then return end
		self.downloads[row.id] = nil
		if not answer or not require("libs.websources").web(answer.url) then
			return self:_fail_download(row, why or "website did not return a downloadable stream")
		end
		if manifest_url(answer.url) then return self:_fail_download(row, "HLS manifest downloads are not supported") end
		row.transfer_url, row.resolved = answer.url, true
		row.request_headers = answer.headers and cjson.encode(answer.headers) or row.request_headers
		self.catalog:updateDownload(row.id, { transfer_url = answer.url, updated_at = self.now() })
		self:_start_download(row)
	end)
	run.handle = { cancel = function() if id and self.discovery.cancel then self.discovery:cancel(id) end end }
end

function Sources:_resolve_archive_download(row)
	local identifier = row.source_url:match("^https://archive%.org/details/([%w%._-]+)$")
	if not identifier then return self:_fail_download(row, "invalid Archive item URL") end
	local run = { row = row, resolving = true, cancelled = false, handle = nil }
	self.downloads[row.id] = run
	run.handle = self.http({
		url = "https://archive.org/metadata/" .. identifier,
		method = "GET", timeout = M.TIMEOUT_S, max_bytes = M.FETCH_LIMIT,
	}, function(response, err)
		if run.cancelled then return end
		self.downloads[row.id] = nil
		if not response or not response.ok then
			return self:_fail_download(row, response and ("Archive metadata HTTP " .. tostring(response.status))
				or tostring(err or "Archive metadata request failed"))
		end
		local transfer_url = providers.archiveFile(response.body or "", identifier)
		if not transfer_url then return self:_fail_download(row, "Archive item has no supported direct media file") end
		self.catalog:updateDownload(row.id, { transfer_url = transfer_url, updated_at = self.now() })
		row.transfer_url = transfer_url
		self:_start_download(row)
	end)
end

function Sources:_active_downloads()
	local count = 0
	for _ in pairs(self.downloads) do count = count + 1 end
	return count
end

function Sources:_fail_download(row, message)
	os.remove(row.temp_path)
	self.catalog:updateDownload(row.id, { state = "failed", error = message, updated_at = self.now() })
	self:resumeDownloads()
end

function Sources:resumeDownloads()
	for _, row in ipairs(self.catalog:downloads()) do
		if row.state == "queued" or row.state == "running" then self:_start_download(row) end
	end
end

function Sources:downloadsList()
	return self.catalog:publicDownloads()
end

function Sources:cancelDownload(id)
	local run = self.downloads[id]
	local row = self.catalog:download(id)
	if not row or (row.state ~= "queued" and row.state ~= "running") then return false end
	if run then run.cancelled = true end
	if run and run.handle and run.handle.cancel then run.handle:cancel() end
	if run and run.file then run.file:close(); run.file = nil end
	os.remove(row.temp_path)
	self.downloads[id] = nil
	self.catalog:updateDownload(id, { state = "cancelled", error = "cancelled by user", updated_at = self.now() })
	self:resumeDownloads()
	return true
end

function Sources:retryDownload(id)
	local row = self.catalog:download(id)
	if not row or (row.state ~= "failed" and row.state ~= "cancelled") then return nil, "that download cannot be retried" end
	os.remove(row.temp_path)
	local library = self.catalog:library(row.library_id)
	local destination = library and safe_path(library.root, row.rel_path)
	if not destination or self.catalog:downloadPathInUse(row.library_id, row.rel_path, row.id)
		or lfs.attributes(destination, "mode") then
		return nil, "the destination already exists or is invalid"
	end
	self.catalog:updateDownload(id, { state = "queued", clear_error = true, bytes = 0, updated_at = self.now() })
	row.state = "queued"
	self:_start_download(row)
	return self.catalog:publicDownload(self.catalog:download(id))
end

function Sources:_start_torrent(target, remote)
	if not self.torrent_engine then
		return self:_finish_open(target.id, { error = "Set LUNAR_TORRENT_ENGINE to a torrent streamer to play this." })
	end
	if self.torrent then
		self.torrent.process:kill()
		self.torrent.process:close()
		self.opened[self.torrent.file_id] = nil
		self.torrent = nil
	end
	local process, why = self.spawn({ self.torrent_engine, "download", remote.url, "--port", tostring(M.TORRENT_PORT) })
	if not process then return self:_finish_open(target.id, { error = tostring(why) }) end
	self.torrent = { process = process, file_id = target.id, started = self.now(), next_try = 0 }
end

function Sources:_tick_torrent(now)
	local run = self.torrent
	if not run or run.ready or now < run.next_try then return end
	if now - run.started > M.TORRENT_START_S then
		self:_finish_open(run.file_id, { error = "No peers answered. This torrent may have nobody sharing it." })
		run.process:kill()
		run.process:close()
		self.torrent = nil
		return
	end
	run.next_try = now + 1
	local url = "http://127.0.0.1:" .. M.TORRENT_PORT .. "/0"
	self.http({ url = url, method = "HEAD", timeout = 2 }, function(response)
		if response and response.ok and self.torrent == run then
			run.ready = true
			self:_finish_open(run.file_id, { url = url })
		end
	end)
end

function Sources:_resolve_archive(target, remote)
	local identifier = remote.key
	self.http({ url = "https://archive.org/metadata/" .. identifier, timeout = M.TIMEOUT_S, max_bytes = M.FETCH_LIMIT },
		function(response)
			local url = response and response.ok and providers.archiveFile(response.body or "", identifier)
			self:_finish_open(target.id, url and { url = url }
				or { error = "The archive has no playable file for this title." })
		end)
end

--- Find out how to play a remote file. Returns nil while the answer is on its way.
-- @tparam table target from `Catalog:fileTarget`
-- @treturn table|nil `{ url, header }` or `{ error }`
function Sources:open(target)
	local ready = self.opened[target.id]
	if ready and (not ready.expires_at or ready.expires_at > self.now()) then return ready end
	self.opened[target.id] = nil
	local remote = decode(target.remote)
	if not remote then return { error = "This file has no address." } end
	if remote.resolve == "webpage" then
		self.opening = self.opening or {}
		if not self.opening[target.id] then
			self.opening[target.id] = true
			self.discovery:resolve(remote.url, function(answer, why)
				self.opening[target.id] = nil
				self:_finish_open(target.id, answer or { error = why, expires_at = self.now() + 30 })
			end)
		end
		return nil
	end
	if remote.resolve == "archive" then
		if not self.opening or not self.opening[target.id] then
			self.opening = self.opening or {}
			self.opening[target.id] = true
			self:_resolve_archive(target, remote)
		end
		return nil
	end
	if remote.resolve == "torrent" then
		if not self.torrent or self.torrent.file_id ~= target.id then self:_start_torrent(target, remote) end
		return self.opened[target.id]
	end
	local answer = { url = remote.url, headers = remote.headers, alternatives = remote.alternatives,
		source_url = remote.source_url, provider_id = remote.provider_id }
	if remote.auth then
		local source = self.catalog:sourceOfFile(target.id)
		local key = source and self.get_secret(string.format("source-%d-%s", source.id, remote.auth))
		if key then answer.header = "X-Emby-Token: " .. key end
	end
	return answer
end

--- Stop anything still running.
function Sources:close()
	if self.discovery then self.discovery:close() end
	if self.torrent then
		self.torrent.process:kill()
		self.torrent.process:close()
		self.torrent = nil
	end
	for id, run in pairs(self.downloads) do
		run.cancelled = true
		if run.handle and run.handle.cancel then run.handle:cancel() end
		if run.file then run.file:close(); run.file = nil end
		self.catalog:updateDownload(id, { state = "queued", clear_error = true, updated_at = self.now() })
		self.downloads[id] = nil
	end
end

return M
