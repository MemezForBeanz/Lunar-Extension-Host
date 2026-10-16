--- Update checks against the org's release share, and the offer to install.
--
-- `core.lib.Updater` decides what is newer and builds the relauncher; this owns
-- the rest: when checks run, the status-bar indicator, the prompt, and handing
-- over to the relauncher. Checks run on the host's cooperative scheduler
-- (`HostAPI:runAsync`), never inline: reading an unreachable share blocks for the
-- OS's SMB timeout, which once froze the window right after launch.
--
-- @classmod core.ui.UpdateCheck

local Updater = require("core.lib.Updater")

local UpdateCheck = {}
UpdateCheck.__index = UpdateCheck

-- How long the TCP probe of the share's SMB port may take. A probe is a socket,
-- which the scheduler can yield on, unlike a file read of the share.
local PROBE_TIMEOUT = 1.5

local function default_read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

local function default_reachable(root)
	local async = require("core.lib.async")
	local host_name = async.uncHost(root)
	if not host_name then return true end   -- a local folder; nothing to probe
	-- Rules out a dead server; a server that accepts and then stalls can still
	-- block the read that follows.
	return async.probeTcp(host_name, 445, PROBE_TIMEOUT)
end

--- @tparam table opts
-- @tparam table opts.iup
-- @tparam table opts.host the `HostAPI` (runAsync, notify, addStatusElement)
-- @tparam table opts.status_bar the `core.ui.StatusBar`
-- @tparam string opts.root the share root (no trailing separator)
-- @tparam string opts.app_title
-- @tparam string opts.app_version
-- @tparam function opts.installed returns `{ [lowercase name] = version }` of loaded extensions
-- @tparam function opts.launch `launch(msi_path)`: start the relauncher; true or nil, err
-- @tparam[opt] function opts.read `read(path)` -> text (default: io.open)
-- @tparam[opt] function opts.reachable `reachable(root)` -> bool (default: TCP probe)
-- @tparam[opt] function opts.exit called after the relauncher starts (default: os.exit(0))
function UpdateCheck.new(opts)
	return setmetatable({
		_o = opts,
		_read = opts.read or default_read,
		_reachable = opts.reachable or default_reachable,
		_exit = opts.exit or function() os.exit(0) end,
		_checking = false,
		_announced = false,
	}, UpdateCheck)
end

--- Put the indicator in the status bar (call once the host exists).
function UpdateCheck:install()
	local o, sb = self._o, self._o.status_bar
	o.host:addStatusElement(sb:updateIcon():widget(), {
		persistent = true,
		position = 1,   -- closest to the org logo
		padding = 0,
		tooltip = sb.UPDATE_STATES.current.tip .. sb.UPDATE_CLICK_HINT,
		on_click = function() self:checkNow() end,
	})
end

--- Check the share and offer to install. Runs inside the scheduler.
-- @treturn string `"current"`, `"available"` or `"unavailable"`
function UpdateCheck:check()
	local o = self._o
	if not self._reachable(o.root) then return "unavailable" end
	local result = Updater.check({
		root = o.root, app_version = o.app_version, installed = o.installed(), read = self._read,
	})
	if result.status ~= "available" then return result.status end

	local lines = {}
	if result.app_update then
		lines[#lines + 1] = string.format("Main application: %s -> %s", o.app_version, result.latest)
	end
	if #result.extensions > 0 then
		lines[#lines + 1] = "Extensions:"
		for _, line in ipairs(result.extensions) do lines[#lines + 1] = "  - " .. line end
	end
	local answer = o.iup.Alarm(o.app_title,
		"An update is available from the share.\n\n" .. table.concat(lines, "\n") .. "\n\nInstall the update now?",
		"Install Now", "Later")
	if answer ~= 1 then return "available" end

	local ok, err = o.launch(Updater.installer_path(o.root, result.latest))
	if not ok then
		o.iup.Message(o.app_title, "Unable to launch the update installer.\n\n" .. tostring(err))
		return "available"
	end
	-- The relauncher is waiting for this process to exit.
	o.iup.Message(o.app_title,
		"The update is being installed. This application will now close and reopen automatically when the update completes.")
	self._exit()
	return "available"
end

-- Show the outcome. An available update is also announced once as a toast: the
-- icon changes quietly at the bottom of the window, and checks repeat, so a toast
-- every time would nag.
function UpdateCheck:_settle(ok, status)
	local o = self._o
	status = ok and status or "unavailable"
	o.status_bar:setUpdateState(status)
	if status == "available" and not self._announced then
		self._announced = true
		pcall(function()
			o.host:notify({
				title = "Update available",
				body  = "A newer release was found on the update share. Click the update icon in the status bar to install it.",
				kind  = "info",
			})
		end)
	end
	return status
end

--- The startup check: the indicator shows "checking" until it settles.
function UpdateCheck:startup()
	local o = self._o
	o.status_bar:setUpdateState("checking")
	o.host:runAsync(function() return self:check() end, function(ok, status) self:_settle(ok, status) end)
end

--- A check the user asked for (clicking the indicator). The icon spins while it
-- runs; a click during a check is ignored. The short timer lets the spinner
-- paint a frame before the check starts.
function UpdateCheck:checkNow()
	if self._checking then return end
	self._checking = true
	local o = self._o
	o.status_bar:startUpdateSpin()
	local function run()
		o.host:runAsync(function() return self:check() end, function(ok, status)
			o.status_bar:stopUpdateSpin()
			self:_settle(ok, status)
			self._checking = false
		end)
	end
	if not o.iup.timer then return run() end
	self._run = run
	if not self._timer then
		local timer, check = o.iup.timer({ TIME = 150, RUN = "NO" }), self
		function timer:action_cb()
			pcall(o.iup.SetAttribute, self, "RUN", "NO")
			check._run()
			return o.iup.DEFAULT
		end
		self._timer = timer
	end
	pcall(o.iup.SetAttribute, self._timer, "RUN", "YES")
end

return UpdateCheck
