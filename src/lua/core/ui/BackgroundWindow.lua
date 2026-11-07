--- Keeps Lunar running after its window closes, and brings the window back.
--
-- Closing the window hides it and leaves a tray icon, so timers, jobs and extensions carry
-- on and the next launch is instant: the Lunar shortcut starts a process that finds this
-- one through `core.lib.Instance`, sends `show` and exits. Quit, from the tray or the
-- command palette, is the only thing that ends the app.
--
-- The background service is a separate process. It is what keeps headless extensions
-- running with no desktop app at all; see `core.lib.Service`.
--
-- @module core.ui.BackgroundWindow

local Kit = require("core.ui.Kit")
local L = require("core.lib.CarbonLayout")
local Instance = require("core.lib.Instance")
local Service = require("core.lib.Service")
local platform = require("core.platform")

local M = {}

local POLL_MS = 250
local STATUS_EVERY = 8        -- polls between service status checks, while the window shows
local BALLOON_MS = 6000
local SW_RESTORE = 9

--- The instance name for this settings folder.
function M.instanceName()
	return "app-" .. Instance.key(platform.config_dir())
end

--- Claim the app, or hand over to the copy already running.
-- @treturn[1] table the instance, or nil when single-instance is unavailable
-- @treturn[2] boolean false when another copy took over: exit now
function M.claim()
	local name = M.instanceName()
	local held = Instance.acquire(name)
	if held == false then
		if Instance.send(name, "show") then return false end
		return nil   -- a copy is starting or stopping: better two windows than none
	end
	return held
end

local function restore_native(dialog)
	if not platform.is_windows then return end
	pcall(function()
		local ffi = require("ffi")
		pcall(ffi.cdef, "int IsIconic(void*); int ShowWindow(void*, int);")
		local IupFFI = require("core.classes.IupFFI")
		local user32 = ffi.load("user32")
		local handle = IupFFI.getptr(IupFFI.ptr(dialog), "HWND")
		if handle ~= nil and user32.IsIconic(handle) ~= 0 then user32.ShowWindow(handle, SW_RESTORE) end
	end)
end

-- Hand unused pages back while nobody is looking. They fault back in on demand.
local function trim_memory()
	if not platform.is_windows then return end
	pcall(function()
		local ffi = require("ffi")
		pcall(ffi.cdef, [[
			void* GetCurrentProcess(void);
			int SetProcessWorkingSetSize(void*, size_t, size_t);
		]])
		ffi.C.SetProcessWorkingSetSize(ffi.C.GetCurrentProcess(), ffi.cast("size_t", -1), ffi.cast("size_t", -1))
	end)
end

--- Take over the window's close button and start listening for later launches.
-- @tparam table opts
-- @tparam table opts.iup the IUP binding
-- @tparam userdata opts.dialog the main window
-- @tparam table opts.settings the `SettingsManager`
-- @tparam table opts.host the `HostAPI`
-- @tparam[opt] table opts.instance what `M.claim` returned
-- @tparam[opt] string opts.icon the tray icon's image name
-- @tparam[opt] boolean opts.packaged an installed copy turns the service on by default
-- @tparam[opt] table opts.panel what `M.registerSettings` returned
-- @treturn table `show()`, `hide()`, `quit()`, `hidden()`
function M.install(opts)
	local iup, dialog, settings, host = opts.iup, opts.dialog, opts.settings, opts.host
	local api = {}
	if opts.panel then opts.panel.background = api end
	local hidden, maximized = false, false
	local polls = 0

	local function keep_running()
		return settings:get("run_in_background") ~= false
	end

	function api.hidden() return hidden end

	function api.show()
		if hidden then
			hidden = false
			if maximized then iup.SetAttribute(dialog, "PLACEMENT", "MAXIMIZED") end
			iup.Show(dialog)
			host:_windowState("shown")
		else
			restore_native(dialog)
		end
		iup.SetAttribute(dialog, "BRINGFRONT", "YES")
	end

	function api.hide()
		if hidden then return end
		maximized = iup.GetAttribute(dialog, "MAXIMIZED") == "YES"
		hidden = true
		iup.Hide(dialog)
		host:_windowState("hidden")
		trim_memory()
		if not settings:get("background_notice_shown") then
			settings:set("background_notice_shown", true)
			settings:save()
			iup.SetAttribute(dialog, "TRAYTIPBALLOON", tostring(BALLOON_MS))
			iup.SetAttribute(dialog, "TRAYTIPBALLOONTITLE", "Lunar is still running")
			iup.SetAttribute(dialog, "TRAYTIP", "Open it again from here or from the Lunar shortcut.")
			iup.SetAttribute(dialog, "TRAYTIPBALLOON", "0")
			iup.SetAttribute(dialog, "TRAYTIP", "Lunar Extension Host")
		end
	end

	function api.quit()
		iup.ExitLoop()
	end

	local item_open = iup.item({ title = "Open Lunar" })
	local item_quit = iup.item({ title = "Quit Lunar" })
	function item_open:action() api.show() return iup.DEFAULT end
	function item_quit:action() api.quit() return iup.DEFAULT end
	local tray_menu = iup.menu({ item_open, iup.separator({}), item_quit })

	if iup.GetAttribute(dialog, "TRAY") ~= "YES" then
		iup.SetAttribute(dialog, "TRAY", "YES")
		iup.SetAttribute(dialog, "TRAYTIP", "Lunar Extension Host")
		if opts.icon then iup.SetAttribute(dialog, "TRAYIMAGE", opts.icon) end
	end
	function dialog:trayclick_cb(button, pressed, double)
		if button == 1 and pressed == 1 then
			api.show()
		elseif button == 3 and pressed == 1 then
			iup.SetAttribute(dialog, "BRINGFRONT", "YES")
			iup.Popup(tray_menu, iup.MOUSEPOS, iup.MOUSEPOS)
		end
		return iup.DEFAULT
	end

	-- The last hidden window would otherwise end the main loop, and with it the app.
	iup.SetGlobal("LOCKLOOP", "YES")
	function dialog:close_cb()
		if keep_running() then
			api.hide()
			return iup.IGNORE
		end
		return iup.CLOSE
	end

	local function show_status()
		if opts.panel then opts.panel.refresh() end
	end
	api.showStatus = show_status

	local timer = iup.timer({ time = POLL_MS, run = "NO" })
	function timer:action_cb()
		if opts.instance then
			for _, line in ipairs(opts.instance:poll()) do
				if line == "show" then
					api.show()
				elseif line == "quit" then
					api.quit()
				elseif line:sub(1, 8) == "lunar://" then
					api.show()
					pcall(host.dispatchRoute, host, line)
				end
			end
		end
		polls = polls + 1
		if polls >= STATUS_EVERY then
			polls = 0
			if not hidden then show_status() end
		end
		return iup.DEFAULT
	end
	iup.SetAttribute(timer, "RUN", "YES")
	api.timer = timer

	-- An installed copy turns the service on the first time it runs. A build from source
	-- never touches the sign-in list unless asked to.
	local wanted = settings:get("service_at_signin")
	if wanted == nil and opts.packaged then
		wanted = true
		settings:set("service_at_signin", true)
		settings:save()
		Service.install()
	end
	if wanted then Service.start() end

	return api
end

--- The Background section of Settings. Call it while the window is unmapped, like the host's
-- other sections, and pass the result to `M.install`.
-- @tparam table opts `iup`, `settings`, `host`
-- @treturn table `status` and `section`
function M.registerSettings(opts)
	local iup, settings = opts.iup, opts.settings
	local panel = {}

	local keep = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle",
		VALUE = settings:get("run_in_background") ~= false and "ON" or "OFF" })
	function keep:valuechanged_cb()
		settings:set("run_in_background", iup.GetAttribute(keep, "VALUE") == "ON")
		settings:save()
		return iup.DEFAULT
	end

	local signin = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle", VALUE = Service.installed() and "ON" or "OFF" })
	function signin:valuechanged_cb()
		local on = iup.GetAttribute(signin, "VALUE") == "ON"
		local ok, why
		if on then
			ok, why = Service.install()
			if ok then ok, why = Service.start() end
		else
			ok, why = Service.uninstall()
		end
		if ok then
			settings:set("service_at_signin", on)
			settings:save()
		else
			iup.SetAttribute(signin, "VALUE", on and "OFF" or "ON")
			opts.host:notify({ title = "Could not change the service", body = tostring(why), kind = "error" })
		end
		if panel.background then panel.background.showStatus() end
		return iup.DEFAULT
	end

	local status = Kit.statusLine(iup, "idle", "Stopped")
	local action
	action = Kit.button(iup, { title = "Start", action = function()
		local ok, why
		if Service.running() then ok, why = Service.stop() else ok, why = Service.start() end
		if not ok then opts.host:notify({ title = "Could not change the service", body = tostring(why), kind = "error" }) end
	end })

	function panel.refresh()
		local running = Service.running()
		Kit.setStatus(iup, status, running and "ok" or "idle", running and "Running" or "Stopped")
		if not running then Kit.bindIcon(iup, status, "stop--outline", { size = Kit.ICON_STATUS, role = "neutral" }) end
		iup.SetAttribute(action, "TITLE", running and "Stop" or "Start")
	end
	panel.refresh()

	panel.section = opts.host:addSettings("Background", { icon = "power", entries = {
		{ label = "Keep the app running when closed",
			description = "Closing the window leaves the app in the system tray. Opening Lunar brings it back, "
				.. "and Quit is in the tray menu.",
			widget = keep },
		{ label = "Start the service at sign-in",
			description = "The service is separate from the app. It runs media servers and other headless "
				.. "extensions, with or without a window.",
			widget = signin },
		{ label = "Service status",
			description = "Start or stop the service now. This does not change what happens at sign-in.",
			widget = iup.hbox({ status, action, GAP = L.gap(3), ALIGNMENT = "ACENTER" }) },
	} })
	return panel
end

return M
