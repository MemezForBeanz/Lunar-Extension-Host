--- The language servers extensions have contributed, and the running client
-- for each (server, workspace folder) pair.
--
-- A contribution says which files it serves and how to start its server; it
-- starts nothing. The first file opened for it resolves the command, finds the
-- workspace folder and starts a `core.lsp.Client`; files from another project
-- get a second client for that project's folder.
--
-- Contributions belong to an owner (the extension). `removeOwned` ends that
-- owner's servers and withdraws their diagnostics, which is what makes
-- unloading an extension stop its language server.
--
-- @classmod core.lsp.Registry
local Client = require("core.lsp.Client")
local Uri = require("core.lsp.Uri")

local Registry = {}
Registry.__index = Registry

local ID_PATTERN = "^[a-z0-9][a-z0-9._%-]*$"
local WINDOWS = package.config:sub(1, 1) == "\\"

local function default_exists(path)
	local ok, lfs = pcall(require, "lfs")
	if not ok then return false end
	return lfs.attributes(path, "mode") ~= nil
end

-- The names in a folder, for `*.ext` root markers.
local function default_list(dir)
	local ok, lfs = pcall(require, "lfs")
	if not ok then return {} end
	local out = {}
	local ok_dir, iter, state = pcall(lfs.dir, dir)
	if not ok_dir then return out end
	for name in iter, state do out[#out + 1] = name end
	return out
end

local function dirname(path)
	local dir = path:match("^(.*)[/\\][^/\\]+[/\\]*$")
	if not dir or dir == "" then return nil end
	if dir:match("^%a:$") then return dir .. "\\" end
	return dir
end

local function string_list(value, label, required)
	if value == nil then
		if required then return nil, label .. " is required" end
		return {}
	end
	if type(value) ~= "table" then return nil, label .. " must be an array of strings" end
	local out = {}
	for i, item in ipairs(value) do
		if type(item) ~= "string" or item == "" then
			return nil, string.format("%s[%d] must be a non-empty string", label, i)
		end
		out[#out + 1] = item
	end
	if required and #out == 0 then return nil, label .. " must not be empty" end
	return out
end

--- @tparam table opts
-- @tparam function opts.spawn `fn{ argv, cwd, env, stdin = true } -> process | nil, err`
-- @tparam core.lsp.Diagnostics opts.diagnostics where published diagnostics go
-- @tparam[opt] function opts.clock seconds
-- @tparam[opt] function opts.exists `fn(path) -> boolean`, for finding root markers
-- @tparam[opt] function opts.list `fn(dir) -> { name, ... }`, for `*.ext` root markers
-- @tparam[opt] function opts.log `fn(level, message)`
-- @tparam[opt] function opts.on_change `fn(server_id)`: a server's state changed,
--   or the set of servers did
-- @tparam[opt] function opts.on_active called when a client starts needing `pump`
function Registry.new(opts)
	assert(type(opts) == "table" and type(opts.spawn) == "function", "Registry.new: opts.spawn is required")
	assert(opts.diagnostics, "Registry.new: opts.diagnostics is required")
	return setmetatable({
		_spawn = opts.spawn,
		_diagnostics = opts.diagnostics,
		_clock = opts.clock,
		_exists = opts.exists or default_exists,
		_list = opts.list or default_list,
		_log = opts.log,
		_on_change = opts.on_change,
		_on_active = opts.on_active,
		_servers = {},       -- array of entries, in registration order
		_by_id = {},
		_clients = {},       -- "id\0root" -> client
	}, Registry)
end

function Registry:_changed(server_id)
	if self._on_change then pcall(self._on_change, server_id) end
end

--- Register a server.
--
-- @tparam table spec
-- @tparam string spec.id unique; lowercase letters, digits, `.`, `_`, `-`
-- @tparam[opt] string spec.name display name (default: the id)
-- @tparam {string,...} spec.languages protocol language ids; the first is the default
-- @tparam[opt] {string,...} spec.extensions file extensions with the dot, e.g. `".lua"`
-- @tparam[opt] {string,...} spec.filenames whole file names, e.g. `"Makefile"`
-- @tparam[opt] table spec.language_ids extension → language id, where it is not
--   the default (`{ [".h"] = "c", [".cpp"] = "cpp" }`)
-- @tparam[opt] {string,...} spec.root_markers files or folders that mark a
--   project root, nearest first match walking up from the file. `"*.sln"` matches
--   any file with that extension
-- @tparam function|table spec.command `fn(root) -> { argv, cwd, env } | nil, reason`,
--   or a fixed `{ argv = {...} }`
-- @tparam[opt] table spec.settings the server's configuration
-- @tparam[opt] table spec.init_options `initializationOptions`
-- @param owner the extension registering it
-- @treturn[1] table the stored entry
-- @treturn[2] nil
-- @treturn[2] string why it was refused
function Registry:register(spec, owner)
	if type(spec) ~= "table" then return nil, "a language server needs a table of options" end
	if type(spec.id) ~= "string" or not spec.id:match(ID_PATTERN) then
		return nil, "language server id must use lowercase letters, digits, '.', '_' or '-'"
	end
	if self._by_id[spec.id] then
		return nil, "a language server with id '" .. spec.id .. "' is already registered"
	end
	local languages, lang_err = string_list(spec.languages, "languages", true)
	if not languages then return nil, lang_err end
	local extensions, ext_err = string_list(spec.extensions, "extensions")
	if not extensions then return nil, ext_err end
	local filenames, name_err = string_list(spec.filenames, "filenames")
	if not filenames then return nil, name_err end
	if #extensions == 0 and #filenames == 0 then
		return nil, "a language server must list the extensions or filenames it serves"
	end
	local markers, marker_err = string_list(spec.root_markers, "root_markers")
	if not markers then return nil, marker_err end

	local command = spec.command
	if type(command) == "table" then
		local fixed = command
		command = function() return fixed end
	end
	if type(command) ~= "function" then
		return nil, "command must be a function or a table with argv"
	end

	local entry = {
		id = spec.id,
		name = type(spec.name) == "string" and spec.name ~= "" and spec.name or spec.id,
		owner = owner,
		languages = languages,
		extensions = {},
		filenames = {},
		language_ids = {},
		root_markers = markers,
		command = command,
		settings = spec.settings,
		init_options = spec.init_options,
	}
	for _, ext in ipairs(extensions) do
		ext = ext:lower()
		if ext:sub(1, 1) ~= "." then ext = "." .. ext end
		entry.extensions[ext] = true
	end
	for _, name in ipairs(filenames) do entry.filenames[name:lower()] = true end
	for ext, language in pairs(type(spec.language_ids) == "table" and spec.language_ids or {}) do
		if type(ext) == "string" and type(language) == "string" then
			ext = ext:lower()
			if ext:sub(1, 1) ~= "." then ext = "." .. ext end
			entry.language_ids[ext] = language
		end
	end

	self._servers[#self._servers + 1] = entry
	self._by_id[entry.id] = entry
	self:_changed(entry.id)
	return entry
end

--- Withdraw everything an owner registered: its servers end, their diagnostics go.
-- @treturn number how many servers were removed
function Registry:removeOwned(owner)
	local removed = 0
	for i = #self._servers, 1, -1 do
		local entry = self._servers[i]
		if entry.owner == owner then
			table.remove(self._servers, i)
			self._by_id[entry.id] = nil
			for key, client in pairs(self._clients) do
				if client.id == entry.id then
					client:kill()
					self._clients[key] = nil
				end
			end
			self._diagnostics:clearServer(entry.id)
			removed = removed + 1
			self:_changed(entry.id)
		end
	end
	return removed
end

--- The registered servers, in registration order.
function Registry:servers()
	local out = {}
	for i, entry in ipairs(self._servers) do out[i] = entry end
	return out
end

--- A server by id.
function Registry:get(id)
	return self._by_id[id]
end

local function basename(path)
	return (path:match("([^/\\]+)$") or path):lower()
end

--- Which server serves a file, by name. The first registered wins.
-- @tparam string path
-- @treturn table|nil the entry
-- @treturn string|nil the protocol language id for this file
function Registry:serverFor(path)
	if type(path) ~= "string" then return nil end
	local name = basename(path)
	local ext = name:match("(%.[^.]+)$")
	for _, entry in ipairs(self._servers) do
		if entry.filenames[name] or (ext and entry.extensions[ext]) then
			return entry, (ext and entry.language_ids[ext]) or entry.languages[1]
		end
	end
	return nil
end

--- The workspace folder for a file: the nearest folder above it holding one of
-- the server's root markers, or the file's own folder when there is none.
function Registry:rootFor(entry, path)
	local start = dirname(path)
	if not start then return nil end
	local dir, guard = start, 0
	while dir and guard < 64 do
		local names
		for _, marker in ipairs(entry.root_markers) do
			local suffix = marker:match("^%*(%..+)$")
			if suffix then
				names = names or self._list(dir)
				for _, name in ipairs(names) do
					if #name > #suffix and name:sub(-#suffix):lower() == suffix:lower() then return dir end
				end
			else
				local probe = dir
				if probe:sub(-1) ~= "/" and probe:sub(-1) ~= "\\" then probe = probe .. (WINDOWS and "\\" or "/") end
				if self._exists(probe .. marker) then return dir end
			end
		end
		local parent = dirname(dir)
		if not parent or parent == dir then break end
		dir = parent
		guard = guard + 1
	end
	return start
end

local function client_key(id, root)
	root = root or ""
	return id .. "\0" .. (WINDOWS and root:lower() or root)
end

--- The client for a file, created (not started) on first use.
-- @tparam string path an absolute file path
-- @treturn[1] core.lsp.Client
-- @treturn[1] table the server entry
-- @treturn[1] string the file's language id
-- @treturn[2] nil no server serves this file
function Registry:clientFor(path)
	local entry, language = self:serverFor(path)
	if not entry then return nil end
	local root = self:rootFor(entry, path)
	local key = client_key(entry.id, root)
	local client = self._clients[key]
	if not client then
		local registry = self
		client = Client.new({
			id = entry.id,
			name = entry.name,
			root = root,
			spawn = self._spawn,
			command = entry.command,
			settings = entry.settings,
			init_options = entry.init_options,
			clock = self._clock,
			on_state = function(state)
				-- A server that is down has nothing to say about any file.
				if state == "failed" or state == "stopped" or state == "unavailable" then
					local others = false
					for other_key, other in pairs(registry._clients) do
						if other_key ~= key and other.id == entry.id and other.state == "running" then
							others = true
						end
					end
					if not others then registry._diagnostics:clearServer(entry.id) end
				end
				if state == "starting" or state == "restarting" then
					if registry._on_active then pcall(registry._on_active) end
				end
				registry:_changed(entry.id)
			end,
			on_diagnostics = function(uri, list)
				registry._diagnostics:set(uri, entry.id, list)
			end,
			on_log = function(level, message)
				if registry._log then pcall(registry._log, level, entry.name .. ": " .. message) end
			end,
		})
		self._clients[key] = client
	end
	return client, entry, language
end

--- Every client that exists, running or not.
function Registry:runningClientFor(path)
	local entry, language = self:serverFor(path)
	if not entry then return nil end
	local client = self._clients[client_key(entry.id, self:rootFor(entry, path))]
	if client and client.state == "running" then return client, language end
end

function Registry:clients()
	local out = {}
	for _, client in pairs(self._clients) do out[#out + 1] = client end
	table.sort(out, function(a, b)
		if a.id ~= b.id then return a.id < b.id end
		return tostring(a.root) < tostring(b.root)
	end)
	return out
end

--- What a server is doing, for the UI. A server with several clients reports
-- the most alive of them.
-- @treturn string `"idle"` (never started), or a `core.lsp.Client` state
-- @treturn string|nil detail: why it failed or is unavailable
function Registry:status(id)
	local rank = { running = 6, starting = 5, restarting = 4, failed = 3, unavailable = 2, stopped = 1 }
	local best, detail
	for _, client in pairs(self._clients) do
		if client.id == id and (not best or (rank[client.state] or 0) > (rank[best] or 0)) then
			best, detail = client.state, client.detail
		end
	end
	if not best or (best == "stopped" and detail == nil) then return "idle" end
	return best, detail
end

--- Try a server's command now, without starting anything: is there a server to run?
-- @treturn[1] table the command
-- @treturn[2] nil
-- @treturn[2] string why not, in a sentence the UI can show
function Registry:probe(id, root)
	local entry = self._by_id[id]
	if not entry then return nil, "no such language server: " .. tostring(id) end
	local ok, command, reason = pcall(entry.command, root)
	if not ok then return nil, tostring(command) end
	if type(command) ~= "table" or type(command.argv) ~= "table" or not command.argv[1] then
		return nil, reason or (entry.name .. " has no command to run")
	end
	return command
end

--- Move every client forward. Call it from one timer.
-- @treturn boolean true while any client still needs pumping
function Registry:pump()
	local active = false
	for _, client in pairs(self._clients) do
		if client:isActive() then
			local ok, more = pcall(client.pump, client)
			if not ok and self._log then pcall(self._log, "error", client.name .. " pump failed: " .. tostring(more)) end
			if ok and more then active = true end
		end
	end
	return active
end

--- Is any client waiting on `pump`?
function Registry:isActive()
	for _, client in pairs(self._clients) do
		if client:isActive() then return true end
	end
	return false
end

--- End every server now (application exit).
function Registry:stopAll()
	for key, client in pairs(self._clients) do
		client:kill()
		self._clients[key] = nil
	end
end

--- The `file:` URI for a path. A convenience so callers need only this module.
function Registry.uri(path)
	return Uri.fromPath(path)
end

return Registry
