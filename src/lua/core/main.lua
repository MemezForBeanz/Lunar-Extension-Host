-- Lunar Extension Host host shell (main.lua)
--
-- A generic, lightweight extension host. It owns no features of its own — not even
-- the build queue, which now ships as an extension (plugins/buildqueue/). The host's
-- only jobs are:
--   1. Build the application chrome: dialog, an (initially empty) tab strip, menu
--      bar, status bar, and ONE host-owned, searchable "Settings" tab.
--   2. Expose a single HostAPI instance to extensions as their `ctx`.
--   3. Discover and load extensions from plugins/. Extensions populate the tab strip,
--      menus, and the Settings tab with whatever they need.
--
-- Structure:
--   1. Module imports + path setup
--   2. Constants & generic host services (settings, status bar)
--   3. Chrome assembly (tabs, settings view, menu, status bar, dialog)
--   4. Extension load, host-owned Settings tab, show + main loop

-- iup global is set by iuplua_open() in the C host; capture as local for speed
local iup = iup
local lfs = require("lfs")

-- Module search path. A development build (LUNAR_DEV_BUILD, set by the C host from
-- the CMake option, and actually running inside the repo's build tree) keeps the
-- default paths so edits are picked up. Packaged builds are never dev builds.
-- An installed build searches only its own folder: neither the current directory
-- nor LUA_PATH/LUA_CPATH can put a module in front of the shipped ones.
local DEV_BUILD

-- The folder holding the executable, from the C host. A packaged build that can't
-- tell (LUNAR_DEV_BUILD == false and no LUNAR_EXE_DIR) stops here: falling back to
-- the working directory would load code from wherever the app was started. Dev
-- builds and the CLI/test harness, which don't set the global, use the cwd.
local function exe_dir_or_fail()
	if type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR ~= "" then return LUNAR_EXE_DIR end
	if LUNAR_DEV_BUILD == false then
		error("Lunar could not determine the folder it was installed in, so it will not load any code."
			.. " Reinstall Lunar, or report this with your Windows version.", 0)
	end
	return lfs.currentdir()
end

do
	local sep = package.config:sub(1, 1)
	local exe_dir = exe_dir_or_fail()
	local lua_dir = exe_dir .. sep .. "lua" .. sep
	-- The repo comes from the build (LUNAR_SOURCE_DIR), not from guessing how deep
	-- the build tree is; a moved or copied dev exe without its repo runs as installed.
	DEV_BUILD = LUNAR_DEV_BUILD == true and type(LUNAR_SOURCE_DIR) == "string"
		and lfs.attributes(LUNAR_SOURCE_DIR .. sep .. "plugins", "mode") == "directory"
	if DEV_BUILD then
		package.path = lua_dir .. "?.lua;" .. package.path
	else
		package.path = lua_dir .. "?.lua;" .. lua_dir .. "?" .. sep .. "init.lua"
		package.cpath = exe_dir .. sep .. "?." .. (sep == "\\" and "dll" or "so")
	end
end

local platform = require("core.platform")
local subprocess = platform.is_windows and require("subprocess") or nil

-- Native widget metrics (GTK menu bar and entries) before any window is built:
-- their sizes feed IUP's layout. A no-op on Windows.
platform.apply_native_style()

local L = require("core.lib.CarbonLayout")
local SettingsManager = require("core.classes.SettingsManager")
local ExtensionMgr = require("core.classes.ExtensionManager")
local HostAPI = require("core.classes.HostAPI")
local SettingsView = require("core.ui.SettingsView")
local MenuBar = require("core.ui.MenuBar")
local StatusBar = require("core.ui.StatusBar")
local ShellBudget = require("core.ui.ShellBudget")
local UpdateCheck = require("core.ui.UpdateCheck")
local ThemeManager = require("core.classes.ThemeManager")
local SystemTheme = require("core.lib.SystemTheme")
local TabOrder = require("core.classes.TabOrder")
local TabGroups = require("core.classes.TabGroups")
local PaneGrid = require("core.classes.PaneGrid")
local CommandRegistry = require("core.classes.CommandRegistry")
local CommandPalette = require("core.ui.CommandPalette")
local VectorIcon = require("core.ui.VectorIcon")
local MotionDirector = require("core.classes.MotionDirector")
local Scrim = require("core.ui.Scrim")
local ModalMotion = require("core.ui.ModalMotion")
local Toast = require("core.ui.Toast")
local TabTransition = require("core.ui.TabTransition")
local TabDragMotion = require("core.ui.TabDragMotion")
local NameDialog = require("core.ui.NameDialog")
local WelcomeTour = require("core.ui.WelcomeTour")
local AppearanceSettings = require("core.ui.AppearanceSettings")
local Diagnostics = require("core.ui.Diagnostics")
local NativeStatus = require("core.lib.NativeStatus")
local MonitorFit = require("core.ui.MonitorFit")
local FeedbackDialog = require("core.ui.FeedbackDialog")
local AddressDialog = require("core.ui.AddressDialog")
local FeedbackClient = require("core.lib.FeedbackClient")
local machine = require("core.lib.machine")
local OrgProfile = require("core.lib.OrgProfile")
local Updater = require("core.lib.Updater")

-- =======================================================================
-- 2. CONSTANTS & GENERIC HOST SERVICES
-- =======================================================================

-- Which organization this install belongs to (core.lib.OrgProfile). nil means
-- neutral Lunar: no org branding, no org endpoints, no update checks. Resolved
-- from local files only, so startup never waits on the network.
local ORG_PROFILE, ORG_INFO

-- The pack chosen with the command bar's Load Org Pack. Read straight from the file:
-- the settings manager is configured from the profile, so it does not exist yet.
local function saved_pack_pick()
	local ok, pick = pcall(function()
		local file = io.open(platform.path:join(platform.config_dir(), "settings.json"), "rb")
		if not file then return nil end
		local text = file:read("*a")
		file:close()
		return require("cjson").decode(text).org_pack_pick
	end)
	return ok and type(pick) == "string" and pick or nil
end

do
	-- A broken profile install must never stop the app from starting.
	-- LUNAR_PROFILE=<id> picks a profile by hand, but only in a dev build: an
	-- installed build never lets an environment variable choose its org.
	local ok, profile, info = pcall(OrgProfile.resolve, {
		dev_select = DEV_BUILD and os.getenv("LUNAR_PROFILE") or nil,
		user_select = saved_pack_pick(),
	})
	if ok then
		ORG_PROFILE, ORG_INFO = profile, info
	else
		ORG_INFO = { reason = "error", errors = { tostring(profile) }, warnings = {}, available = {} }
	end
end

local ORG_PROFILES = ORG_PROFILE and (ORG_PROFILE.profiles or { ORG_PROFILE }) or {}

-- The same in every org: an org shows up as its tool group, not a rename.
local APP_TITLE = "Lunar Extension Host"
local APP_VERSION = "1.2.0"
-- Folder or share holding the update manifest.json, from the update_share
-- setting once settings load (an org profile supplies it). nil: no update checks.
local SHARE_ROOT

-- Application install directory: the folder containing the executable, provided by
-- the C host as the LUNAR_EXE_DIR global. Stable regardless of the process working
-- directory, so bundled resources like plugins/ resolve reliably (see exe_dir_or_fail).
local APP_DIR = exe_dir_or_fail()

-- Linux: GTK takes the window/taskbar icon from a default icon list (Windows uses
-- the exe's ICON resource). Before any window exists, so all of them get it.
platform.set_app_icon(platform.path:join(APP_DIR, "assets", "app-icon"))

-- A dev build loads plugins/ straight from the repo, so edits show up without a
-- rebuild; an installed build loads the copy next to the exe.
local function resolve_plugins_dir(app_dir)
	if DEV_BUILD then return platform.path:join(LUNAR_SOURCE_DIR, "plugins") end
	return platform.path:join(app_dir, "plugins")
end

-- The status bar logo belongs to the org profile (brand.logo, an SVG inside the
-- profile folder); the neutral build shows none.
local ICON_DIR = platform.path:join(APP_DIR, "assets", "Icons")

-- Window/taskbar icon: the name of the Win32 ICON RESOURCE in the executable, not
-- an IupImage handle. assets/Lunar.rc declares `IUP ICON "lunar.ico"`,
-- so "IUP" is that resource's name.
--
-- This has to be a resource name because of how IUP applies the attribute
-- (winDialogSetIconAttrib in iupwin_dialog.c): it resolves the value through
-- LoadImage against the executable's resources FIRST, at both the small and the
-- large system icon size, and only falls back to iupImageGetIcon -- for ICON_BIG
-- ALONE -- if the large resource lookup fails. Handing it an IupImage handle name
-- therefore leaves ICON_SMALL unset entirely and gives ICON_BIG a single 32px
-- bitmap stretched to whatever size the shell asked for, which is why the taskbar
-- icon disappeared. lunar.ico is a proper multi-resolution icon, so pointing at
-- the resource gets both sizes rendered correctly.
local APP_ICON_RESOURCE = "IUP"

-- Start the update relauncher (core.lib.Updater.relauncher_script) for `msi`,
-- detached: subprocess.start_detached escapes the kill-on-close job, so it
-- survives this process exiting.
local function launch_update_installer(msi)
	local exe = (type(LUNAR_EXE_PATH) == "string" and LUNAR_EXE_PATH ~= "" and LUNAR_EXE_PATH)
		or (APP_DIR .. "\\Lunar.exe")
	local script, err = Updater.relauncher_script({ msi = msi, exe = exe, pid = LUNAR_PID })
	if not script then return nil, err end
	local temp_dir = os.getenv("TEMP") or os.getenv("TMP")
	if not Updater.safe_path(temp_dir) then return nil, "no usable TEMP folder" end
	local script_path = string.format("%s\\lunar_update_%d.bat", temp_dir, os.time())
	-- Binary mode: the script already has CRLF endings.
	local f, ferr = io.open(script_path, "wb")
	if not f then return nil, "unable to write updater script: " .. tostring(ferr) end
	f:write(script)
	f:close()
	return subprocess.start_detached('"' .. script_path .. '"', temp_dir)
end

-- Forward-declare chrome handles + the single host context.
local tabs, ext_menu
local settings_view
local host
-- Built near the bottom, once every extension tab exists, but referenced by the
-- menu bar's reload handler which is created long before that.
local tab_groups
-- Built with the chrome below; the menu bar needs set_status before that.
local status_bar
local function set_status(msg)
	if status_bar then status_bar:setStatus(msg) end
end

-- Generic host services
local settings_mgr = SettingsManager:new({
	legacy_dir_name = ORG_PROFILE and ORG_PROFILE.legacy_config_dir,
})
settings_mgr:load()
settings_mgr:applyProfile(ORG_PROFILE)
do
	local org_log = require("core.lib.log").get("org")
	if ORG_PROFILE then
		org_log:info(string.format("profile %s (%s, %s)", ORG_PROFILE.id, ORG_INFO.reason,
			ORG_PROFILE.trusted and "trusted" or "untrusted: locks ignored"))
	else
		org_log:info("no org profile (" .. tostring(ORG_INFO.reason) .. "); running neutral")
	end
	for _, err in ipairs(ORG_INFO.errors) do org_log:warn("skipped profile " .. err) end
	for _, warning in ipairs(ORG_INFO.warnings) do org_log:warn(warning) end

	-- The updater installs an MSI, so update checks are Windows-only for now;
	-- Linux builds will update through their package format instead.
	local share = settings_mgr:get("update_share")
	if platform.is_windows and type(share) == "string" and share ~= "" then
		SHARE_ROOT = share:gsub("[/\\]+$", "")
	end
end
-- Where extension code may come from: the built-in plugins folder, then the
-- selected org pack's extensions/ folder. A pack's code loads only when the pack
-- itself is trusted (admin-installed); a dev build also takes LUNAR_PROFILE_DIR
-- packs so pack extensions can be developed without installing them.
local extension_roots = { { dir = resolve_plugins_dir(APP_DIR), source = "built-in", create = true } }
for _, profile in ipairs(ORG_PROFILES) do
	if profile.trusted or DEV_BUILD then
		extension_roots[#extension_roots + 1] = {
			dir = platform.path:join(profile.dir, "extensions"),
			source = "org:" .. profile.id,
			group = profile.tool_group,
		}
	end
end
local ext_mgr = ExtensionMgr:new(extension_roots)

-- The single HostAPI instance persists for the lifetime of the process and is reused
-- across extension reloads, so build_ext_ctx just returns it.
local function build_ext_ctx()
	return host
end

-- =======================================================================
-- 3. CHROME ASSEMBLY
-- =======================================================================

-- Empty tab strip — use flat tabs so tab background/border/text can be themed.
--
-- IupFlatTabs scrolls its own strip: once the tabs no longer fit it draws arrow
-- buttons at each end and pages through them. That is native behaviour and needs
-- no configuration here — but it only reaches the user because
-- core.classes.TabOrder hooks FLAT_BUTTON_CB rather than replacing the control's
-- internal BUTTON_CB, which is what dispatches those arrows. See TabOrder.
tabs = iup.flattabs({})

-- No band above the tabs. The window's title bar names the product, the tab strip names
-- the tool, and a third row saying "Lunar Extension Host" over a coloured line pushed
-- every page down by another 30px to repeat the title bar.

-- Host-owned, centralized settings surface (search box + collapsible sections).
-- `settings` persists which categories the user collapsed; `icon_dir` supplies the
-- Carbon chevron. The motion director does not exist yet and is attached below.
settings_view = SettingsView:new({
	iup      = iup,
	settings = settings_mgr,
	icon_dir = ICON_DIR,
})

-- Menu bar (needs tabs for extension reload; returns the Extensions menu handles)
local menu_bar, mh = MenuBar.build({
	iup = iup,
	app_title = APP_TITLE,
	app_version = APP_VERSION,
	ext_mgr = ext_mgr,
	tabs = tabs,
	set_status = set_status,
	build_ext_ctx = build_ext_ctx,
	-- A reload appends every extension tab back at the root strip, so the group
	-- layout has to be re-applied afterwards or the user's groups come back empty.
	on_reload = function()
		if tab_groups then tab_groups:restore() end
	end,
	on_show_tab_bars = function()
		if tab_groups then tab_groups:showAllTabBars() end
	end,
})
ext_menu = mh.ext_menu

-- Theme swapper: build the manager and drop a "Theme" submenu next to Extensions.
local theme_mgr = ThemeManager:new({ iup = iup, settings = settings_mgr })
iup.Insert(menu_bar, mh.help_submenu, theme_mgr:buildMenu())

-- Optional native modules all fall back quietly; say once which ones are active.
local NATIVE = NativeStatus.probe(require, platform.is_windows)
do
	local line, missing = NativeStatus.summary(NATIVE, theme_mgr:fastPaths())
	local native_log = require("core.lib.log").get("native")
	if missing then native_log:warn(line) else native_log:info(line) end
end

-- Wire the shared theme-reactivity registry to the manager ONCE. ThemeReactor installs
-- a single onApply hook that repaints every registered paint-time widget (e.g. the
-- role-colored VectorIcon SVG icons) on a theme switch. Native flat controls get their
-- gradients/rounded corners from the ThemeManager attribute walk directly and need no
-- registration here.
require("core.ui.ThemeReactor").bindThemeManager(theme_mgr)

-- Status bar (built before HostAPI, which takes its extension status box).
status_bar = StatusBar.new({
	iup = iup,
	icon_dir = ICON_DIR,
	search_icon = VectorIcon.imageHandle(iup, {
		path = platform.path:join(ICON_DIR, "search.svg"), size = 14, color = "#9aa0b0",
	}),
	-- The org's logo, when its profile ships one; the neutral build shows none.
	logo = ORG_PROFILE and ORG_PROFILE.brand.logo,
})

-- The single host context handed to every extension.
host = HostAPI:new({
	theme_manager = theme_mgr,
	iup = iup,
	-- `org` lets an extension tell which organization it is running for (id and
	-- display name only); org settings reach it through ctx.settings as usual.
	app = {
		title = APP_TITLE, version = APP_VERSION, dir = APP_DIR,
		org = ORG_PROFILE and not ORG_PROFILE.profiles and { id = ORG_PROFILE.id, name = ORG_PROFILE.name } or nil,
	},
	settings = settings_mgr,
	subprocess = subprocess,
	tabs = tabs,
	ext_menu = ext_menu,
	file_menu = mh.file_menu,
	file_exit = mh.file_exit,
	help_menu = mh.help_menu,
	help_about = mh.help_about,
	settings_view = settings_view,
	set_status = set_status,
	set_update_state = function(state, tooltip) status_bar:setUpdateState(state, tooltip) end,
	status_box = status_bar:extBox(),
})

-- Update checks (core.ui.UpdateCheck), only when there is an update share: on
-- the neutral build the indicator would claim "up to date" about nothing.
local update_check = SHARE_ROOT and UpdateCheck.new({
	iup = iup,
	host = host,
	status_bar = status_bar,
	root = SHARE_ROOT,
	app_title = APP_TITLE,
	app_version = APP_VERSION,
	installed = function()
		local installed = {}
		for _, ext in ipairs(ext_mgr.extensions or {}) do
			if type(ext.name) == "string" and ext.name ~= "" then
				installed[ext.name:lower()] = ext.version or "0.0"
			end
		end
		return installed
	end,
	launch = launch_update_installer,
})
if update_check then update_check:install() end

-- Re-apply the active theme whenever the widget tree changes, so newly added tabs and
-- settings rows get themed too (fully generic -- no per-extension knowledge). When a
-- specific widget is supplied, only that subtree is (coalesced and) re-themed instead
-- of walking the whole dialog, which keeps tab/settings additions cheap.
host._on_tree_change = function(widget) theme_mgr:themeWidget(widget) end

-- =======================================================================
-- UI MOTION
-- =======================================================================
--
-- One director schedules every animation in the process, host and extensions
-- alike (see core.classes.MotionDirector), so concurrent motion is frame-locked
-- and a single setting governs all of it. Durations and easing come from the IBM
-- Carbon motion system, matching the Carbon-derived themes and layout.
--
-- Built here, before the dialog exists, because the settings UI below needs the
-- director to bind its controls to. The overlay it draws on is created later, once
-- there is a dialog to parent it to.
local motion_director = MotionDirector:new({
	iup = iup,
	enabled = settings_mgr:get("motion_enabled") ~= false,
	scale = tonumber(settings_mgr:get("motion_scale")) or 1.0,
	respect_system = settings_mgr:get("motion_respect_system") ~= false,
})
host:setMotionDirector(motion_director)
status_bar:setMotion(motion_director)

-- Motion follows the theme. A theme's `motion()` overrides are installed by the
-- same `apply` that paints its colors, so the two halves of the design language
-- can never drift apart. Bound here rather than at ThemeManager construction
-- because the director does not exist until now.
theme_mgr:setMotionDirector(motion_director)

-- Settings sections animate their expand/collapse through the same director, so
-- the accordion honours the motion switch and speed like everything else.
settings_view:setMotion(motion_director)

-- "Match system theme" (core.lib.SystemTheme): the user's theme picks go through
-- it so that, while matching, a pick is remembered for the current light/dark mode.
local system_theme = SystemTheme.new({
	settings = settings_mgr, theme_manager = theme_mgr,
	system_dark = platform.system_dark, system_dark_probe = platform.system_dark_probe, iup = iup,
})
theme_mgr:setChooser(function(id) system_theme:choose(id) end)

-- Appearance settings: theme and motion (core.ui.AppearanceSettings).
AppearanceSettings.register({
	iup = iup, settings = settings_mgr, host = host,
	theme_manager = theme_mgr, motion = motion_director,
	system_theme = system_theme,
	org_name = ORG_PROFILE and not ORG_PROFILE.profiles and ORG_PROFILE.name,
})

-- Startup sizes for the main window: the primary monitor's usable area, until
-- the window is shown and can ask which monitor it is on (core.ui.MonitorFit).
local ok_iupffi, IupFFI = pcall(require, "core.classes.IupFFI")
if not ok_iupffi then IupFFI = nil end
local STARTUP = MonitorFit.startup(iup)
local WORK_W, WORK_H, TASKBAR = STARTUP.work_w, STARTUP.work_h, STARTUP.taskbar

-- Main dialog
--
-- GAP is set to a 2px Carbon gutter rather than zero. The shell header, accent
-- strip, tab strip and status bar are all painted on $layer-01 surfaces; the vbox
-- background is $background. A 1-step (2px) gap between each band lets that
-- background show through as a seam, which is how Carbon tile and shell layouts
-- establish structure without drawn borders. L.gutter() returns the spacing-step-1
-- pixel value (2) and reads at a glance as "this is a seam, not a margin".
-- The workspace: the main tab strip plus the panes a tab can be split into. Empty
-- panes take no space, so with nothing split this is exactly the single strip.
local pane_grid = PaneGrid:new({ iup = iup, main = tabs, settings = settings_mgr })

local content_box = iup.vbox({
	pane_grid:widget(),
	status_bar:widget(),
	MARGIN = L.margin(0),
	GAP = tostring(L.gutter()),
})

local dlg = iup.dialog({
	content_box,
	TITLE = APP_TITLE,
	MENU = menu_bar,
	ICON = APP_ICON_RESOURCE,
	MINSIZE = STARTUP.minsize,
	-- A hard ceiling on the window height. IUP sizes a dialog from its content and
	-- answers WM_GETMINMAXINFO with MAXSIZE, which defaults to 65535, so without
	-- this nothing stops the window growing past the screen (the status bar ended
	-- up below the edge, on scaled displays especially). Windows enforces it
	-- whatever the cause. Height only: capping width would shrink the window on a
	-- secondary monitor wider than the primary. The +40 lets a maximized window
	-- extend by its invisible resize border, as Windows 10/11 expects. A backstop:
	-- HostAPI:addTab already keeps page content from inflating the window.
	MAXSIZE = STARTUP.maxsize,
	-- Restore size used when the user un-maximizes; the dialog itself opens
	-- maximized (PLACEMENT is set just before IupShow below).
	--
	-- SIZE, not RASTERSIZE. RASTERSIZE on a dialog sets userwidth/userheight, which
	-- PERSIST and pin the window -- setting it here fought the maximize and is why
	-- the app stopped opening full screen.
	SIZE = "HALFxHALF",
	SHRINK = "YES",
	-- COMPOSITED=NO makes IUP use WS_CLIPCHILDREN instead of WS_EX_COMPOSITED.
	-- WS_EX_COMPOSITED is unreliable on modern Windows (10/11) and caused heavy
	-- tearing of the native child controls (Tests/Utilities flatlists) during
	-- window/splitter resize. WS_CLIPCHILDREN clips each child's rectangle so the
	-- parent containers no longer repaint over them mid-resize -- the standard
	-- Win32 anti-flicker behaviour.
	COMPOSITED = "NO",
})

-- Keep MAXSIZE/MINSIZE on the monitor the window is on (core.ui.MonitorFit).
local monitor_fit = MonitorFit.new({ iup = iup, dialog = dlg, ffi = IupFFI })
local shell_budget = { bands = {} }
local function measured_height(widget, attribute)
	local ok, size = pcall(iup.GetAttribute, widget, attribute or "RASTERSIZE")
	local height = ok and type(size) == "string" and tonumber(size:match("x(%d+)$"))
	return height and height > 0 and height or nil
end

local function recalc_shell_budget(client_h)
	client_h = client_h or measured_height(dlg, "CLIENTSIZE")
	if not client_h or client_h <= 0 then return false end
	local bands = {
		status = measured_height(status_bar:widget()) or 0,
	}
	local cap = ShellBudget.cap(client_h, bands, L.gutter(), 4)
	shell_budget.bands, shell_budget.cap = bands, cap
	local value = "65535x" .. cap
	if iup.GetAttribute(tabs, "MAXSIZE") == value then return false end
	iup.SetAttribute(tabs, "MAXSIZE", value)
	iup.SetAttribute(pane_grid:widget(), "MAXSIZE", value)
	return true
end

-- Settings reads as a form, so it keeps a form's width on any monitor.
local SETTINGS_MAX_WIDTH = 940

-- Page widths are only known after the layout pass a resize triggers.
local recenter_timer = iup.timer({ time = 30 })
function recenter_timer:action_cb()
	self.run = "NO"
	if host then
		host:recenterPages()
		iup.Refresh(dlg)
	end
	return iup.DEFAULT
end
local function schedule_recenter()
	recenter_timer.run = "NO"
	recenter_timer.run = "YES"
end

function dlg:resize_cb(_, h)
	recalc_shell_budget(h)
	schedule_recenter()
	return iup.DEFAULT -- winDialogResize performs the layout after this callback.
end

local function refresh_shell_budget()
	-- Theme/font and status-scope changes need fresh band measurements first.
	iup.Refresh(dlg)
	if recalc_shell_budget() then iup.Refresh(dlg) end
end
theme_mgr:onApply(refresh_shell_budget)
-- A lowercase method is how iuplua binds callbacks; setting dlg.MOVE_CB would
-- store an attribute IUP never calls.
function dlg:move_cb(x, y)   -- luacheck: ignore x y
	monitor_fit:refit()
end

-- =======================================================================
-- 4. EXTENSION LOAD & MAIN LOOP
-- =======================================================================

-- Hand the dialog to the host so it can install the dialog-level keyboard-shortcut
-- dispatcher (K_ANY) that extensions feed via host:registerShortcut.
host:setDialog(dlg)
theme_mgr:setRoot(dlg)

local function show_welcome_tour()
	WelcomeTour.show({
		iup = iup,
		settings = settings_mgr,
		parent = dlg,
		notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
	})
end

local function show_feedback()
	local identity = machine.identify(settings_mgr)
	local client_feedback_id = machine.new_id()
	FeedbackDialog.show({
		iup = iup,
		app = { title = APP_TITLE, version = APP_VERSION },
		host = host,
		route = host:currentRoute(),
		parent = dlg,
		set_status = set_status,
		submit = function(message, done)
			host:runAsync(function() return FeedbackClient.submit(settings_mgr:get("backend_url"), {
				client_feedback_id = client_feedback_id,
				category = "general",
				message = message,
				app_version = APP_VERSION,
				current_route = host:currentRoute(),
				extensions = host:listLoadedExtensions(),
				client_hostname = identity.hostname,
				windows_user = identity.user,
				client_ipv4 = identity.ipv4,
				machine_id = identity.machine_id,
				client_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			}, {
				timeout = 5,
				user_agent = "Lunar/" .. APP_VERSION,
				tls_verify = settings_mgr:get("backend_tls_verify"),
				ca_file = settings_mgr:get("backend_ca_file"),
			}) end, function(ok, result, err)
				if ok then done(result, err) else done(nil, result) end
			end)
		end,
		notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
	})
end

local function show_address_dialog()
	AddressDialog.show({
		iup = iup,
		host = host,
		value = host:currentRoute() or "lunar://host/settings",
		parent = dlg,
		notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
	})
end

-- The command bar. Registered before the menu items below and before extensions
-- load, so every menu item lands in it (core.classes.host.Menus).
local commands = CommandRegistry:new({
	settings = settings_mgr,
	open_address = function(uri)
		local ok, err = host:dispatchRoute(uri)
		if ok then return true end
		return nil, type(err) == "table" and err.message or tostring(err)
	end,
})
host:setCommands(commands)

local command_palette = CommandPalette.new({
	iup = iup,
	registry = commands,
	parent = dlg,
	notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
	on_error = function(message) host:setStatus(message) end,
	round = function(window) require("core.lib.desktop").roundWindow(iup, window) end,
	search_icon = VectorIcon.imageHandle(iup, {
		path = platform.path:join(ICON_DIR, "search.svg"), size = 16, color = "#9aa0b0",
	}),
	anchor = function()
		local bar = status_bar:commandWidget()
		local x, y = tostring(iup.GetAttribute(bar, "SCREENPOSITION") or ""):match("(-?%d+),(-?%d+)")
		local w = tostring(iup.GetAttribute(bar, "RASTERSIZE") or ""):match("^(%d+)x")
		if not (x and w) then return nil end
		return tonumber(x), tonumber(y), tonumber(w)
	end,
})
status_bar:onCommand(function() command_palette:toggle() end)
host:registerShortcut(iup.K_cP, function() command_palette:toggle() end)
host:_installKeyDispatch(dlg)

local function add_host_command(id, title, run, extra)
	local spec = { id = "host." .. id, title = title, run = function()
		run()
		return true
	end }
	for k, v in pairs(extra or {}) do spec[k] = v end
	commands:register(spec)
end

add_host_command("address", "Open Lunar Address", function() command_palette:open("lunar://") end,
	{ keywords = "go to route url link" })
add_host_command("settings", "Open Settings", function() host:dispatchRoute("lunar://host/settings") end,
	{ keywords = "preferences options" })
add_host_command("reload", "Restart Extensions", function() mh.reload_extensions() end,
	{ keywords = "reload refresh plugins" })
add_host_command("updates", "Check for Updates", function() update_check:checkNow() end,
	{ when = function() return update_check ~= nil end })
add_host_command("tabbars", "Show All Tab Bars", function() tab_groups:showAllTabBars() end)
add_host_command("splits.reset", "Close All Splits", function() pane_grid:reset() end,
	{ keywords = "unsplit panes merge" })

local function split_active(zone)
	return function()
		local page = tab_groups:activeLeaf()
		if page then pane_grid:move(page, zone) end
		host:_applyTabScopes()
	end
end
add_host_command("split.right", "Split Tab Right", split_active("right"), { keywords = "pane side by side" })
add_host_command("split.down", "Split Tab Down", split_active("bottom"), { keywords = "pane below" })

-- Load Org Pack: the packs this machine has, one of which the user may choose when
-- nothing else assigns one (see OrgProfile.resolve, step 3).
add_host_command("orgpack", "Load Org Pack", function()
	local items = {}
	for _, id in ipairs(ORG_INFO.available or {}) do
		local loaded = ORG_PROFILE and ORG_PROFILE.id == id
		items[#items + 1] = {
			id = "orgpack." .. id, title = id, category = loaded and "Loaded" or "Org Pack",
			run = function()
				settings_mgr:set("org_pack_pick", id)
				settings_mgr:save()
				host:setStatus("Restart Lunar to load " .. id)
				return true
			end,
		}
	end
	if #items == 0 then
		host:setStatus("No org packs are installed on this machine")
		return
	end
	command_palette:open("", {
		items = items, placeholder = "Choose an org pack",
		hint = "Takes effect the next time Lunar starts",
	})
end, { keywords = "profile organization" })

commands:addProvider({
	id = "tabs",
	items = function()
		local out = {}
		if not tab_groups then return out end
		for _, page in ipairs(tab_groups:leaves()) do
			local title = iup.GetAttribute(page, "TABTITLE")
			if title and title ~= "" then
				out[#out + 1] = {
					id = "tab." .. tostring(tab_groups:keyOf(page) or title),
					title = title, category = "Go to",
					run = function()
						host:_activateTabWidget(page)
						return true
					end,
				}
			end
		end
		return out
	end,
})

commands:addProvider({
	id = "themes",
	items = function()
		local out = {}
		for _, theme in ipairs(theme_mgr:themes()) do
			out[#out + 1] = {
				id = "theme." .. theme.id, title = theme.label, category = "Theme",
				run = function()
					theme_mgr:apply(theme.id)
					return true
				end,
			}
		end
		return out
	end,
})

-- Tasks answer from here, once they exist. The prefix is reserved now so an extension
-- can supply them and the bar already knows how to show them.
commands:addProvider({
	id = "tasks",
	prefix = "task ",
	title = "Tasks",
	empty = "No tasks are defined yet",
	items = function() return {} end,
})

-- For scripts/ui_capture.lua, which drives these from outside.
if DEV_BUILD then
	_G.LUNAR_DEV_SHELL = {
		palette = command_palette,
		panes = pane_grid,
		groups = function() return tab_groups end,
	}
end

host:addMenuItem("Open Lunar Address...", show_address_dialog, "file")
host:addMenuItem("Welcome Tour...", show_welcome_tour, "help")
host:addMenuItem("Feedback...", show_feedback, "help")

-- Load extensions from plugins
ext_mgr:loadAll(host)

-- Append the host-owned Settings tab BEFORE restoring tab order, so it participates
-- in drag-reordering and order persistence alongside the extension tabs.
iup.Append(tabs, settings_view:widget())
host:installKeyDispatch(settings_view:widget())
host:registerHostTab("settings", settings_view:widget())

-- Tab groups + drag-and-drop.
--
-- TabGroups owns the tree (a group is a tab whose page is another flattabs, so
-- groups nest to any depth) and its persistence; TabOrder owns the pointer
-- gestures and is installed on every strip the manager creates, so a group's
-- sub-bar behaves exactly like the main one.
--
-- The on_switch hook keeps per-tab menu and status scoping in sync for the
-- switches these two perform programmatically -- spring-open, follow-the-drop,
-- route activation -- which IUP does not report through TABCHANGE_CB.
local tab_order = TabOrder:new({
	iup = iup,
	settings = settings_mgr,
	on_switch = function() host:_applyTabScopes() end,
	prompt = function(title, default)
		return NameDialog.show({
			iup = iup,
			title = title,
			label = "Group name:",
			value = default,
			parent = dlg,
			notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
		})
	end,
})

-- The motion surface. Every effect on the main window draws through the dialog's
-- compositor (`core.lib.Compositor.forDialog`): one native overlay per dialog, one
-- present per director tick, however many effects are animating. Each effect owns
-- its own group in it, so the tab transition, the drag feedback and the scrim
-- never touch each other's sprites.
--
-- The compositor is a child window of the main dialog, so it is made lazily after
-- the dialog is shown (see `modal_scrim:prepare()` below). Every effect fails
-- closed to today's instant behaviour if it turns out to be unavailable (no
-- backend on this platform, or the overlay couldn't be created), so nothing here
-- needs to check.
local tab_transition = TabTransition:new({
	iup = iup,
	dialog = dlg,
	director = motion_director,
	-- Without this the transition failed silently: every reason it can decline to
	-- animate (no compositor, a capture that came back blank, a press that turned
	-- out to be a drag) was discarded, so "tab switching has no motion" was
	-- indistinguishable from "tab switching is disabled" from the outside. Each
	-- distinct reason is logged once -- see TabTransition:_note.
	log = function(msg) host.log:info(msg) end,
})

tab_order:setMotion(TabDragMotion:new({
	iup = iup,
	dialog = dlg,
	director = motion_director,
	spring_ms = 500,
	log = function(msg) host.log:info(msg) end,
}))

-- The scrim that dims the page behind every modal.
--
-- Covers `content_box` rather than the dialog: Carbon dims the *page*, and the
-- title bar is window chrome rather than part of it. Dimming the whole dialog
-- would also cover the frame Windows itself draws, which is not ours to grey out.
--
-- Installed on `core.ui.ModalMotion` as a module-level singleton, which is what
-- lets the seven unrelated dialog modules dim the page without any of them being
-- handed a scrim through their constructors. There is exactly one page.
local modal_scrim = Scrim:new({
	iup = iup,
	dialog = dlg,
	cover = content_box,
	director = motion_director,
	log = function(msg) host.log:info(msg) end,
})
ModalMotion.setScrim(modal_scrim)

-- Carbon notifications. Built here for the same reason the overlays are: a toast
-- is a child window of the main dialog, which only exists at this point.
--
-- The status bar answers "what is the app doing right now" and is overwritten
-- freely; a toast answers "this finished, and you were not necessarily watching".
-- They are different questions, which is why this is a surface of its own rather
-- than a longer status string.
host:setToastHost(Toast.ToastHost.new({
	iup = iup,
	director = motion_director,
	dialog = dlg,
	notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
}))

-- Wired BEFORE TabGroups is constructed. Building the group manager prepares the
-- root strip and every restored group strip, and each of those calls back into
-- tab_order:install -- which is where the transition's page-change hooks go on. A
-- transition attached afterwards would be re-installed on the existing strips
-- anyway, but doing it in this order means each strip is hooked exactly once.
tab_order:setTransition(tab_transition)

-- A theme switch rewrites attributes across the whole tree and repaints under a
-- process-global window lock (core.classes.ThemeManager). A transition in flight
-- during that would be compositing snapshots of the OLD theme over the newly
-- themed widgets. Settle it first; the tab still ends up where it was going.
theme_mgr:onApply(function() tab_transition:settle() end)

tab_groups = TabGroups:new({
	iup = iup,
	root_strip = tabs,
	settings = settings_mgr,
	extra_icon = function(name)
		return VectorIcon.imageHandle(iup, {
			path = platform.path:join(ICON_DIR, name .. ".svg"), size = 14, color = "#9aa0b0",
		})
	end,
	on_change = function()
		host:_applyTabScopes()
		refresh_shell_budget()
	end,
	on_strip_created = function(strip) tab_order:install(strip) end,
	on_new_group = function(strip)
		local name = NameDialog.show({
			iup = iup,
			title = "New Tab Group",
			label = "Group name:",
			parent = dlg,
			notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
		})
		if name then tab_groups:createGroup(strip, name, "user") end
	end,
	notify_tree_change = function(w) theme_mgr:themeWidget(w) end,
	-- Same ceiling HostAPI:addTab applies to a top-level page; TabGroups tightens
	-- it per nesting level, since each sub-bar eats into the page below it.
	height_cap = math.max(320, WORK_H - 130),
})
tab_order:setGroups(tab_groups)
host:setTabGroups(tab_groups)
tab_groups:setPanes(pane_grid:extraStrips())
pane_grid:setGroups(tab_groups)
tab_order:setPanes(pane_grid, dlg)
for _, strip in pairs(pane_grid:extraStrips()) do theme_mgr:themeWidget(strip) end
theme_mgr:onApply(function()
	pane_grid:sync()
	host:syncScrollHosts()
end)
pane_grid:onLayout(schedule_recenter)
host:centerPage(settings_view:widget(), SETTINGS_MAX_WIDTH, L.px(L.ROLE.page))

-- Rebuild the saved arrangement now that every extension tab and the host's own
-- Settings tab are in the strip, and while the pages are still unmapped.
tab_groups:restore()
pane_grid:sync()
host:syncScrollHosts()

-- The first time an org's tool group applies on this machine, move the org's
-- tools into it whatever the saved layout says (a layout from before tool groups
-- keeps them wherever they were). Recorded per org and group name, so moves the
-- user makes afterwards are theirs; renaming the group in the profile applies
-- once more. Only recorded once the org's tabs were actually there to move.
for _, profile in ipairs(ORG_PROFILES) do
	local group = profile.tool_group
	local applied = settings_mgr:get("tool_group_applied")
	applied = type(applied) == "table" and applied or {}
	if applied[profile.id] ~= group then
		local ok, matched = pcall(tab_groups.applyHints, tab_groups, function(_, hint)
			return hint == group or hint:sub(1, #group + 1) == group .. "/"
		end)
		if ok and matched > 0 then
			applied[profile.id] = group
			settings_mgr:set("tool_group_applied", applied)
			settings_mgr:save()
		end
	end
end

-- Open maximized. PLACEMENT must be set BEFORE IupShow: IUP turns it into the
-- SW_SHOWMAXIMIZED passed to ShowWindow (winDialogShow in iupwin_dialog.c), and
-- setting it afterwards is a no-op. MAXIMIZED (not FULLSCREEN) keeps the title
-- bar, so the window stays restorable and movable.
pcall(iup.SetAttribute, dlg, "PLACEMENT", "MAXIMIZED")
iup.Show(dlg)

-- Build the dialog's compositor NOW, while nothing is happening. The scrim, the tab
-- transition and the drag feedback all share it (it is cached per dialog), and the
-- first animation of a drag or a modal would otherwise create and map a native
-- window from inside a mouse-move or menu callback -- the re-entrant context that
-- crashed the process when overlays were made lazily.
pcall(function() modal_scrim:prepare() end)

-- Now that the window has an HWND, size it for the monitor it opened on (the
-- startup sizes were the primary monitor's).
monitor_fit:refit()

-- Help > Tab Group Diagnostics: what the host believes each page is. Several tab
-- tree bugs looked identical from outside (wrong nesting, wrong labels, a page
-- mistaken for a group) and could only be told apart this way.
host:addMenuItem("Tab Group Diagnostics...", function()
	local ok, text = pcall(function() return tab_groups:describe() end)
	iup.Message("Tab Group Diagnostics", ok and text or ("unavailable: " .. tostring(text)))
end, "help")

-- Help > Window Diagnostics (core.ui.Diagnostics).
host:addMenuItem("Window Diagnostics...", function()
	local function attr(h, name)
		local ok, v = pcall(iup.GetAttribute, h, name)
		return (ok and v) and tostring(v) or "(nil)"
	end
	local ok_rep, report = pcall(function() return tab_transition:report() end)
	iup.Message("Window Diagnostics", Diagnostics.window_report({
		fullsize = iup.GetGlobal("FULLSIZE"),
		screensize = iup.GetGlobal("SCREENSIZE"),
		work = { w = WORK_W, h = WORK_H },
		-- The rect MonitorFit last sized for; nil until the first fit (no IupFFI).
		monitor = monitor_fit.applied,
		taskbar = TASKBAR,
		profile = ORG_PROFILE,
		org_info = ORG_INFO,
		dev_build = DEV_BUILD,
		roots = extension_roots,
		loaded = ext_mgr.extensions,
		skipped = ext_mgr.skipped,
		window = {
			RASTERSIZE = attr(dlg, "RASTERSIZE"), CLIENTSIZE = attr(dlg, "CLIENTSIZE"),
			MAXIMIZED = attr(dlg, "MAXIMIZED"), MAXSIZE = attr(dlg, "MAXSIZE"), MINSIZE = attr(dlg, "MINSIZE"),
		},
		layout = {
			tabs_raster = attr(tabs, "RASTERSIZE"),
			statusbar_raster = attr(status_bar:widget(), "RASTERSIZE"),
			statusbar_expand = attr(status_bar:widget(), "EXPAND"),
			shell_cap = shell_budget.cap,
			shell_bands = shell_budget.bands,
		},
		transition = ok_rep and report or tostring(report),
		native = NativeStatus.lines(NATIVE, theme_mgr:fastPaths()),
	}))
end, "help")

-- The first update check, on the scheduler so the window is usable at once.
if update_check then update_check:startup() end

-- Extension list popluation
host:_markShown()

-- Apply the saved theme now that the full widget tree is mapped. The app ships with
-- the IBM Carbon Design System look; Classic Dark (Carbon Gray 100) is the default
-- when the user has not yet chosen a theme.
-- With "Match system theme" on, the system's mode decides; otherwise (or when the
-- system can't say) the saved theme.
if not system_theme:sync(true) then
	theme_mgr:apply(settings_mgr:get("theme") or "lunar_dark", { skip_save = true })
end
system_theme:start()

if not settings_mgr:get("welcome_tour_completed")
	and not settings_mgr:get("welcome_tour_dismissed") then
	show_welcome_tour()
end

iup.MainLoop()
