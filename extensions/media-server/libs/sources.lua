--- Sources: libraries that live somewhere else.
-- A source is a provider plus what a person filled in. Syncing turns its answer into ordinary
-- catalog rows in a library of its own, so Home, filters and collections need no special cases.
-- A file from a source has an address instead of a path, and the desktop plays it directly.
-- @module libs.sources

local cjson = require("cjson")
local providers = require("libs.providers")

local Sources = {}
Sources.__index = Sources

local M = {}

M.RESYNC_S = 6 * 3600
M.TORRENT_PORT = 18721
M.TORRENT_START_S = 45
M.FETCH_LIMIT = 16 * 1024 * 1024
M.TIMEOUT_S = 30

--- Create the manager.
-- @tparam table opts `catalog`, `http(request, done)`, `get_secret(name)`, `set_secret(name, value)`,
--   `delete_secret(name)`, `spawn(argv)`, `now()`, `log`, `torrent_engine`
function M.new(opts)
	return setmetatable({ catalog = opts.catalog, http = opts.http, get_secret = opts.get_secret,
		set_secret = opts.set_secret, delete_secret = opts.delete_secret, spawn = opts.spawn, now = opts.now, log = opts.log,
		torrent_engine = opts.torrent_engine, syncing = {}, opened = {} }, Sources)
end

local function decode(text)
	local ok, data = pcall(cjson.decode, text or "")
	return ok and type(data) == "table" and data or nil
end

--- Every provider a source can be made from: those Lunar ships and those people have added.
function Sources:providers()
	local out = {}
	for _, provider in ipairs(providers.BUILTIN) do out[#out + 1] = provider end
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
	if not provider then return self.catalog:sourceSynced(id, "failed", "its provider is gone", 0, self.now()) end
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
	if ready then return ready end
	local remote = decode(target.remote)
	if not remote then return { error = "This file has no address." } end
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
	local answer = { url = remote.url }
	if remote.auth then
		local source = self.catalog:sourceOfFile(target.id)
		local key = source and self.get_secret(string.format("source-%d-%s", source.id, remote.auth))
		if key then answer.header = "X-Emby-Token: " .. key end
	end
	return answer
end

--- Stop anything still running.
function Sources:close()
	if self.torrent then
		self.torrent.process:kill()
		self.torrent.process:close()
		self.torrent = nil
	end
end

return M
