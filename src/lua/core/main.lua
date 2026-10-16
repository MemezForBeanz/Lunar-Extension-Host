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
local subprocess = require("subprocess")

-- Module search path. A development build (LUNAR_DEV_BUILD, set by the C host from
-- the CMake option, and actually running inside the repo's build tree) keeps the
-- default paths so edits are picked up. Packaged builds are never dev builds.
-- An installed build searches only its own folder: neither the current directory
-- nor LUA_PATH/LUA_CPATH can put a module in front of the shipped ones.
local DEV_BUILD
do
	local sep = package.config:sub(1, 1)
	local exe_dir = (type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR ~= "" and LUNAR_EXE_DIR) or lfs.currentdir()
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

local L = require("core.lib.CarbonLayout")
local SettingsManager = require("core.classes.SettingsManager")
local ExtensionMgr = require("core.classes.ExtensionManager")
local HostAPI = require("core.classes.HostAPI")
local SettingsView = require("core.ui.SettingsView")
local MenuBar = require("core.ui.MenuBar")
local StatusBar = require("core.ui.StatusBar")
local UpdateCheck = require("core.ui.UpdateCheck")
local ThemeManager = require("core.classes.ThemeManager")
local TabOrder = require("core.classes.TabOrder")
local TabGroups = require("core.classes.TabGroups")
local MotionDirector = require("core.classes.MotionDirector")
local MotionOverlay = require("core.ui.MotionOverlay")
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
local platform = require("core.platform")

-- =======================================================================
-- 2. CONSTANTS & GENERIC HOST SERVICES
-- =======================================================================

-- Which organization this install belongs to (core.lib.OrgProfile). nil means
-- neutral Lunar: no org branding, no org endpoints, no update checks. Resolved
-- from local files only, so startup never waits on the network.
local ORG_PROFILE, ORG_INFO
do
	-- A broken profile install must never stop the app from starting.
	-- LUNAR_PROFILE=<id> picks a profile by hand, but only in a dev build: an
	-- installed build never lets an environment variable choose its org.
	local ok, profile, info = pcall(OrgProfile.resolve, {
		dev_select = DEV_BUILD and os.getenv("LUNAR_PROFILE") or nil,
	})
	if ok then
		ORG_PROFILE, ORG_INFO = profile, info
	else
		ORG_INFO = { reason = "error", errors = { tostring(profile) }, warnings = {}, available = {} }
	end
end

-- The same in every org: an org shows up as its tool group, not a rename.
local APP_TITLE = "Lunar Extension Host"
local APP_VERSION = "1.0.0"
-- Folder or share holding the update manifest.json, from the update_share
-- setting once settings load (an org profile supplies it). nil: no update checks.
local SHARE_ROOT

-- Application install directory: the folder containing the executable, provided by
-- the C host as the LUNAR_EXE_DIR global. Stable regardless of the process working
-- directory, so bundled resources like plugins/ resolve reliably. Falls back to the
-- cwd for the CLI/dev harness which doesn't set the global.
local APP_DIR = (LUNAR_EXE_DIR and LUNAR_EXE_DIR ~= "" and LUNAR_EXE_DIR) or lfs.currentdir()

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
-- an IupImage handle. assets/LunarExtensionHost.rc declares `IUP ICON "lunar.ico"`,
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
		or (APP_DIR .. "\\LunarExtensionHost.exe")
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
if ORG_PROFILE and (ORG_PROFILE.trusted or DEV_BUILD) then
	extension_roots[#extension_roots + 1] = {
		dir = platform.path:join(ORG_PROFILE.dir, "extensions"),
		source = "org:" .. ORG_PROFILE.id,
		-- The pack's tabs open together in the org's group, e.g. "Acme Tools".
		group = ORG_PROFILE.tool_group,
	}
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

-- Carbon UI shell header: the band that names the product.
--
-- Carbon's shell is the first thing in its content-entrance order and the last
-- thing that should ever move, which is why it is a static band rather than
-- anything interactive -- the menu bar above it already owns the actions.
--
-- It is what was missing structurally. Without it the window opened straight onto
-- a tab strip, so there was nothing establishing the application's own frame of
-- reference and every tab read as the top of the hierarchy. Carbon puts the shell
-- on $background and the content on $layer-01, and that one step of contrast is
-- most of what makes the layout read as deliberate.
--
-- Brand and product are two labels, not one, so the brand can be semibold and the
-- product name regular -- Carbon's shell treatment, one typeface at two weights.
--
-- ### Height is the text, not Carbon's 48px
--
-- Carbon specifies a 48px shell header, and this used to pin exactly that with a
-- zero-width child carrying an explicit RASTERSIZE. It was wrong here and the
-- reason is worth keeping: Carbon's shell header is the application's *only*
-- chrome -- it carries the nav, the actions and the account menu, so 48px is
-- working space. This app already has a native Win32 menu bar directly above it,
-- so the band holds nothing but a product name, and 48px of it was a third of an
-- inch of empty grey above every screen.
--
-- Following the token here would be following it past the point where it means
-- anything. The band is sized to its text.
--
-- EXPAND is HORIZONTAL only, for the same reason the status bar's is: a
-- vertically-expanding child gets handed `naturalheight + empty`, and `empty` goes
-- negative once the content is taller than the window, which is how the status bar
-- once got squeezed to nothing. Horizontal-only makes this a fixed-height row that
-- the vbox skips when distributing a deficit.
-- The first word of the product name is the brand ("Lunar" | "Extension Host").
local SHELL_BRAND, SHELL_PRODUCT = APP_TITLE:match("^(%S+)%s*(.*)$")
local shell_header = iup.hbox({
	iup.flatlabel({ TITLE = SHELL_BRAND or APP_TITLE, THEMEROLE = "shellbrand" }),
	iup.flatlabel({ TITLE = SHELL_PRODUCT or "", THEMEROLE = "shellproduct" }),
	iup.fill({}),
	iup.flatlabel({ TITLE = "v" .. APP_VERSION, THEMEROLE = "shellmeta" }),
	THEMEROLE  = "shellheader",
	-- Horizontal padding only. Vertical is zero so the band is exactly as tall as
	-- the labels inside it.
	MARGIN     = L.margin(5, 0),
	GAP        = L.gap(2),
	ALIGNMENT  = "ACENTER",
	EXPAND     = "HORIZONTAL",
})

-- Native gradient accent strip (a thin bar above the tabs). Themes that opt in (via
-- palette.gradEnabled/gradTop/gradBottom) render a real horizontal gradient here through
-- the forked flat controls; non-gradient themes paint it in the dialog background color
-- so it blends away. Themed via the "accentstrip" rule (see fluent_rules).
local gradient_strip = iup.flatlabel({
	TITLE      = "",
	RASTERSIZE = "x4",
	EXPAND     = "HORIZONTAL",
	THEMEROLE  = "accentstrip",
})

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
		org = ORG_PROFILE and { id = ORG_PROFILE.id, name = ORG_PROFILE.name } or nil,
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

-- Appearance settings: theme and motion (core.ui.AppearanceSettings).
AppearanceSettings.register({
	iup = iup, settings = settings_mgr, host = host,
	theme_manager = theme_mgr, motion = motion_director,
	org_name = ORG_PROFILE and ORG_PROFILE.name,
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
local content_box = iup.vbox({
	shell_header,
	gradient_strip,
	tabs,
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

-- The motion surface. Created now rather than earlier because the overlay is a
-- child window of the main dialog, which only exists at this point.
--
-- ONE OVERLAY PER CONSUMER, deliberately. An overlay owns a single frame composer,
-- a single back buffer and a single window; two users sharing one instance means
-- whichever acted last owns the pixels, and the other keeps driving redraws and
-- hides against state that is no longer its own. During a drag both consumers are
-- live at once -- the transition from the press that started the gesture, the drag
-- feedback from the gesture itself -- so sharing one produced exactly that
-- collision, and with it an intermittent hard crash. The windows are created
-- lazily, so the second one costs nothing until it is actually used.
--
-- Both degrade to today's instant behaviour on their own if the overlay turns out
-- to be unusable (no FFI, no HWND, a rejected layered style), so nothing below
-- needs to check.
local motion_overlays = {}
local function make_overlay()
	local ov = MotionOverlay:new({
		iup = iup,
		dialog = dlg,
		-- host.log is the host's own namespaced application logger. The overlay
		-- only ever logs once, when it latches itself off, so this records WHY
		-- animations silently stopped happening on a machine rather than leaving
		-- it a mystery.
		log = function(msg) host.log:info(msg) end,
	})
	motion_overlays[#motion_overlays + 1] = ov
	return ov
end

local tab_transition = TabTransition:new({
	iup = iup,
	director = motion_director,
	overlay = make_overlay(),
	-- Without this the transition failed silently: every reason it can decline to
	-- animate (no overlay, a capture that came back blank, a press that turned out
	-- to be a drag) was discarded, so "tab switching has no motion" was
	-- indistinguishable from "tab switching is disabled" from the outside. Each
	-- distinct reason is logged once -- see TabTransition:_note.
	log = function(msg) host.log:info(msg) end,
})

tab_order:setMotion(TabDragMotion:new({
	iup = iup,
	director = motion_director,
	overlay = make_overlay(),
	spring_ms = 500,
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
	on_change = function() host:_applyTabScopes() end,
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

-- Rebuild the saved arrangement now that every extension tab and the host's own
-- Settings tab are in the strip, and while the pages are still unmapped.
tab_groups:restore()

-- The first time an org's tool group applies on this machine, move the org's
-- tools into it whatever the saved layout says (a layout from before tool groups
-- keeps them wherever they were). Recorded per org and group name, so moves the
-- user makes afterwards are theirs; renaming the group in the profile applies
-- once more. Only recorded once the org's tabs were actually there to move.
if ORG_PROFILE and ORG_PROFILE.tool_group then
	local group = ORG_PROFILE.tool_group
	local applied = settings_mgr:get("tool_group_applied")
	applied = type(applied) == "table" and applied or {}
	if applied[ORG_PROFILE.id] ~= group then
		local ok, matched = pcall(tab_groups.applyHints, tab_groups, function(_, hint)
			return hint == group or hint:sub(1, #group + 1) == group .. "/"
		end)
		if ok and matched > 0 then
			applied[ORG_PROFILE.id] = group
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

-- Build the motion overlay windows NOW, while nothing is happening.
--
-- Deferred to here rather than done at construction because the overlays are child
-- windows of the main dialog and need it on screen first. Doing it here rather
-- than lazily is the point: the first animation of a drag would otherwise create
-- and map a native window from inside a mouse-move callback, while the tab strip
-- holds the Win32 mouse capture -- which crashed the process a drag or two into a
-- session. After this, showing an overlay is only a SetWindowPos.
for _, ov in ipairs(motion_overlays) do
	pcall(function() ov:prepare() end)
end

-- Same reasoning for the scrim's own window: a modal is very often opened from a
-- menu or button callback, which is exactly the re-entrant context that made
-- creating a native window lazily crash the process above.
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
theme_mgr:apply(settings_mgr:get("theme") or "classic_dark", { skip_save = true })

if not settings_mgr:get("welcome_tour_completed")
	and not settings_mgr:get("welcome_tour_dismissed") then
	show_welcome_tour()
end

iup.MainLoop()
