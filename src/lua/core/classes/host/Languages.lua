--- Language servers for core.classes.HostAPI: the one registry, the timer that
-- pumps it, and the owner-scoped registration extensions use.
--
-- A language server is contributed by an extension and by nothing else, the
-- built-in ones included (plugins/lsp-lua, plugins/lsp-c). That keeps one path:
-- the manifest declares the `language_server` capability, the extension calls
-- `ctx:addLanguageServer`, and unloading it ends the server.
--
-- @module core.classes.host.Languages
-- @local
local Manifest = require("core.lib.ExtensionManifest")

local M = {}

--- How often the servers are pumped while any of them is alive, in ms.
M.PUMP_MS = 30

--- The settings key holding a user-chosen path for a server.
function M.pathSetting(id)
	return "lsp." .. tostring(id) .. ".path"
end

local function start_pump(self)
	local registry = self._languages
	if not registry or self._language_pumping then return end
	local iup = self.iup
	if iup then
		if not self._language_timer then
			local host = self
			local timer = iup.timer({ TIME = tostring(M.PUMP_MS), RUN = "NO" })
			function timer:action_cb()
				-- A handler may open a dialog, which runs a nested loop that fires
				-- this timer again; the clients are not re-entrant.
				if host._language_in_pump then return iup.DEFAULT end
				host._language_in_pump = true
				local ok, active = pcall(registry.pump, registry)
				host._language_in_pump = false
				if not ok or not active then
					pcall(iup.SetAttribute, timer, "RUN", "NO")
					host._language_pumping = false
				end
				return iup.DEFAULT
			end
			self._language_timer = timer
		end
		self._language_pumping = true
		pcall(iup.SetAttribute, self._language_timer, "RUN", "YES")
	elseif self.loop then
		if not self._language_timer then
			self._language_timer = self.loop:every(M.PUMP_MS, function() registry:pump() end, true,
				{ keep_on_error = true })
		end
		self._language_pumping = true
	end
end

--- The registry, created on first use. Nil when this host cannot run processes.
function M.registry(self)
	if self._languages ~= nil then return self._languages or nil end
	local ok_process, process = pcall(require, "process")
	if not ok_process then
		self._languages = false
		return nil
	end
	local Registry = require("core.lsp.Registry")
	local Diagnostics = require("core.lsp.Diagnostics")
	local host = self
	self._language_diagnostics = Diagnostics.new()
	self._language_listeners = {}
	self._languages = Registry.new({
		diagnostics = self._language_diagnostics,
		-- The registry owns these processes and ends them itself, by owner; they
		-- are not also recorded as the extension's, or unload would close each twice.
		spawn = function(opts) return process.spawn(opts) end,
		log = function(level, message)
			local log = host.log
			if not log then return end
			if level == "error" then log:error(message)
			elseif level == "warning" then log:warn(message)
			else log:debug(message) end
		end,
		on_active = function() start_pump(host) end,
		on_change = function(id)
			-- A change usually means there is pumping to do (a start, a restart).
			if host._languages and host._languages:isActive() then start_pump(host) end
			for _, fn in ipairs(host._language_listeners) do pcall(fn, id) end
		end,
	})
	return self._languages
end

--- The diagnostics store shared by every server, or nil without a registry.
function M.diagnostics(self)
	if not M.registry(self) then return nil end
	return self._language_diagnostics
end

--- Be told when a server is added, removed or changes state. `fn(server_id)`.
function M.onChange(self, fn)
	if not M.registry(self) then return end
	self._language_listeners[#self._language_listeners + 1] = fn
end

function M.addLanguageServer(self, spec, owner)
	local manifest = self._manifest_by_owner[owner]
	if not manifest or not Manifest.hasCapability(manifest, "language_server") then
		return nil, "addLanguageServer requires a registered owner with language_server capability"
	end
	local registry = M.registry(self)
	if not registry then return nil, "language servers are unavailable in this host" end
	local entry, err = registry:register(spec, owner)
	if not entry then return nil, err end
	entry.extension = manifest.id
	self:_record(owner).language_servers = true
	return entry
end

function M.findLanguageServer(self, spec)
	if type(spec) ~= "table" then return nil, "findLanguageServer needs a table of options" end
	local Discover = require("core.lsp.Discover")
	local configured = spec.id and self.settings and self.settings:get(M.pathSetting(spec.id)) or nil
	return Discover.find({
		label = spec.label or spec.id or "The language server",
		names = spec.names,
		bundled = spec.bundled,
		install = spec.install,
		configured = type(configured) == "string" and configured or nil,
		app_dir = self.app and self.app.dir or nil,
	})
end

--- End an owner's servers. Called from `HostAPI:removeOwned`.
function M.removeOwned(self, owner)
	if self._languages then self._languages:removeOwned(owner) end
end

--- End every server: the application is closing.
function M.stopAll(self)
	if self._languages then self._languages:stopAll() end
end

return M
