--- The surface the application host exposes to extensions.
--
-- A single `HostAPI` instance is created by the host (`main.lua`) and handed to
-- every extension's `register(ctx)` call as `ctx`. It is the ONLY thing an
-- extension needs in order to integrate with the application: add tabs, add menu
-- items, post status, register settings, routes and shortcuts, schedule work for
-- after the window is shown, and own timers that are cleaned up automatically on
-- unload.
--
-- ### Why this exists
--
-- * Tabs added during extension load happen BEFORE the dialog is shown. Calling
--   `iup.Map()` on a tab at that point — before the dialog owns a native window —
--   corrupts dynamically-populated children (e.g. a scrollbox that later has rows
--   appended).
-- * Extensions frequently need to run setup that requires fully-mapped widgets
--   (populating lists, selecting defaults). `HostAPI:onReady` provides a reliable
--   post-show hook instead of fragile ad-hoc timers.
--
-- ### Ownership
--
-- Every registration takes an optional `owner` value - by convention the extension
-- table itself. The host records what each owner created and removes all of it in
-- `HostAPI:removeOwned`, which the `core.classes.ExtensionManager` calls on unload
-- and reload. Registrations made without an owner belong to a shared default owner
-- and live for the lifetime of the process.
--
-- ### Fields (read-only for extensions)
--
-- @field iup the IUP binding table
-- @field app application info: `{ title, version, dir }`
-- @field settings the `core.classes.SettingsManager` instance
-- @field subprocess the native `subprocess` module (Windows only; `nil` elsewhere),
--   wrapped so `start` and `start_argv` take an optional trailing `owner`: owned
--   processes are ended on unload. Prefer `HostAPI:startJob` or `HostAPI:spawn`.
-- @field tabs the main tab strip handle
-- @field ext_menu the Extensions menu handle
-- @field file_menu the File menu handle
-- @field help_menu the Help menu handle
-- @field dialog the main dialog handle (set by `HostAPI:setDialog`)
-- @field log the host's own `core.lib.log` logger
-- @field ui reusable widget classes: `ContextMenu`, `FlatDropdown`, `ReorderableList`,
--   `CheckList`, `SettingsView`
--
-- @classmod core.classes.HostAPI
-- @usage
--    local M = {}
--
--    function M.register(ctx)
--        local iup = ctx.iup
--        ctx:addTab("Example", iup.vbox{ iup.label{ title = "hi" } }, M)
--        ctx:addMenuItem("Do the thing", function() ctx:setStatus("done") end, "extensions", M)
--        ctx:onReady(function() ctx:setStatus("Example ready") end, M)
--    end
--
--    return M

local class = require("middleclass")
local applog = require("core.lib.log")

-- Reusable UI toolkit exposed to extensions as ctx.ui (and also require-able as
-- core.ui.*). These cover the common heavy-lifting widgets so extensions don't each
-- reimplement them: popup menus, drag-reorderable multi-select lists, and checkbox
-- browsers.
local UI_TOOLKIT = {
    ContextMenu     = require("core.ui.ContextMenu"),
    FlatDropdown    = require("core.ui.FlatDropdown"),
    ReorderableList = require("core.ui.ReorderableList"),
    CheckList       = require("core.ui.CheckList"),
    SettingsView    = require("core.ui.SettingsView"),
}

local Secrets = require("core.classes.host.Secrets")
local Network = require("core.classes.host.Network")
local Layout = require("core.classes.host.Layout")
local Routing = require("core.classes.host.Routing")
local Keys = require("core.classes.host.Keys")
local Menus = require("core.classes.host.Menus")

local HostAPI = class("HostAPI")

-- Sentinel owner for registrations made without an explicit owner.
local DEFAULT_OWNER = require("core.classes.host.Owners")

--- Construct the host context. Called once by the host; extensions never call this.
-- @local
-- @tparam table opts host-supplied handles (iup, app, settings, subprocess, tabs,
--   menus, status callbacks, settings view)
function HostAPI:initialize(opts)
    self.iup        = opts.iup
    self.app        = opts.app
    self.settings   = opts.settings
    self._subprocess_owner = {}   -- legacy subprocess handle -> owner record
    self.subprocess = opts.subprocess and self:_ownedSubprocess(opts.subprocess)
    self.tabs       = opts.tabs
    self.ext_menu   = opts.ext_menu
    self._theme_mgr = opts.theme_manager   -- for ctx:registerTheme
    self.ui = UI_TOOLKIT

    self.log = applog.get("host")

    -- Menu handles
    self.file_menu   = opts.file_menu
    self._file_exit  = opts.file_exit
    self.help_menu   = opts.help_menu
    self._help_about = opts.help_about
    self._file_sep   = nil   -- lazy separator above Exit
    self._help_sep   = nil   -- lazy separator above About

    self._status_fn     = opts.set_status
    self._update_state_fn = opts.set_update_state
    self._settings_view = opts.settings_view   -- host owned SettingsView
    self._status_box    = opts.status_box      -- ordered container for all status elements
    self._shown         = false
    self._ready         = {}   -- queue of { fn, owner } pending the first show
    self._owners        = {}   -- owner -> { tabs={}, items={}, timers={}, settings={}, shortcuts={}, statuswidgets={} }

    self._shortcuts  = {}   -- key code -> { {key=,fn=}, ... }  (dialog-level K_ANY)
    self.dialog      = opts.dialog   -- usually set later via setDialog()
    self._tab_scoped = {}   -- { {owner,item,target,present}, ... } items shown only
                            -- while the owning extension's tab is the active one
    self._status_scoped = {} -- ordered, owner-aware status-bar element registrations
    self._status_seq    = 0
    self._tab_seq      = 0  -- counter for unique per-tab owner-id attributes
    self._owner_by_tab = {} -- tab-id string -> owner (robust active-tab resolution)
    self._manifest_by_owner = {}
    self._root_group_by_owner = {}  -- owner -> its org pack's tool group
    self._owner_by_extension_id = {}
    self._host_tabs = {}
    self._route_handlers = {}
    self._route_serializers = {}

    -- Show/hide each extension's contributed menu items (and status-bar widgets) as
    -- the active tab changes, so a plugin's File/Help/Extensions entries and status
    -- indicators appear only while its tab is active.
    if self.tabs then
        local host = self
        local iup  = self.iup
        function self.tabs:tabchange_cb()
            host:_applyTabScopes()
            return iup.DEFAULT
        end
    end

    -- Back-compat: some callers use ctx.set_status(msg) as a plain function.
    self.set_status = function(msg) self:setStatus(msg) end
end

--- Fetch (creating on demand) the ownership record for `owner`.
-- @local
function HostAPI:_record(owner)
    owner = owner or DEFAULT_OWNER
    local r = self._owners[owner]
    if not r then
        r = { tabs = {}, items = {}, timers = {}, settings = {}, shortcuts = {}, statuswidgets = {}, themes = {},
              requests = {}, jobs = {}, processes = {}, subprocesses = {} }
        self._owners[owner] = r
    end
    return r
end

--- Associate a validated manifest with an extension owner.
--
-- Called by the `core.classes.ExtensionManager` while loading an extension;
-- extensions do not call this themselves. Manifest ids must be unique across all
-- loaded extensions — a duplicate id is rejected instead of silently shadowing
-- the extension that claimed it first.
--
-- @tparam table owner the extension table that owns the registration
-- @tparam table manifest a manifest validated by `core.lib.ExtensionManifest`
-- @tparam[opt] table entry the discovery entry; its `group` (the org pack's tool
--   group) becomes the outer group of every tab the extension adds
-- @treturn boolean|nil `true` on success, `nil` on failure
-- @treturn string|nil error message when registration failed
function HostAPI:registerExtension(owner, manifest, entry)
    if owner == nil or type(manifest) ~= "table" then
        return nil, "extension owner and manifest are required"
    end
    local existing = self._owner_by_extension_id[manifest.id]
    if existing and existing ~= owner then
        return nil, "duplicate extension id: " .. tostring(manifest.id)
    end
    self._manifest_by_owner[owner] = manifest
    self._root_group_by_owner[owner] = entry and entry.group or nil
    if type(manifest.id) == "string" and manifest.id ~= "" then
        self._owner_by_extension_id[manifest.id] = owner
    end
    return true
end

--- Look up a loaded extension's manifest.
-- @tparam table|string owner_or_id the owning extension table, or its manifest id
-- @treturn table|nil the manifest, or `nil` when the extension is not loaded
-- @usage local version = ctx:getManifest("hello").version
function HostAPI:getManifest(owner_or_id)
    if type(owner_or_id) == "string" then
        local owner = self._owner_by_extension_id[owner_or_id]
        return owner and self._manifest_by_owner[owner] or nil
    end
    return self._manifest_by_owner[owner_or_id]
end

--- List the manifests of every loaded extension, sorted by display name.
-- @treturn {table,...} manifest tables
function HostAPI:listLoadedExtensions()
    local list = {}
    for _, manifest in pairs(self._manifest_by_owner) do
        list[#list + 1] = manifest
    end
    table.sort(list, function(a, b)
        return tostring(a.name or a.id or "") < tostring(b.name or b.id or "")
    end)
    return list
end

--- Register a host-owned tab under a routing id (e.g. the Settings tab).
--
-- Host-internal: it is what makes `lunar://host/<id>` addresses resolvable.
-- @local
-- @tparam string id routing id
-- @tparam userdata widget the tab widget
function HostAPI:registerHostTab(id, widget) return Layout.registerHostTab(self, id, widget) end

--- Adopt the tab-group manager. Host-internal; called once by `main.lua`.
-- @local
-- @tparam TabGroups groups the `core.classes.TabGroups` instance
function HostAPI:setTabGroups(groups) return Layout.setTabGroups(self, groups) end

--- Update the status bar text.
-- @tparam string msg message to display
function HostAPI:setStatus(msg)
    if self._status_fn then self._status_fn(msg) end
end

--- Return a namespaced application logger for an extension.
--
-- Messages fan out to the host's console and rotated log file, are level-filtered,
-- and pretty-print any table arguments.
--
-- @tparam[opt="extension"] string name logger namespace
-- @treturn table a `core.lib.log` logger
-- @usage
--    local log = ctx:getLogger("hello")
--    log:info("queued", { count = n })
function HostAPI:getLogger(name)
    return applog.get(name or "extension")
end

--- Update the bottom-bar software-update indicator.
-- @tparam string state one of `"current"`, `"available"`, `"unavailable"`, `"ready"`
-- @tparam[opt] string tooltip overrides the default hover text for the state
function HostAPI:setUpdateState(state, tooltip)
    if self._update_state_fn then self._update_state_fn(state, tooltip) end
end

--- Ask the host to (re)apply theming to a widget tree.
--
-- Extensions that build UI asynchronously (e.g. after an async repo scan) call this
-- so freshly created widgets are themed to match the active theme. It is a no-op
-- before the main window is shown, because the host themes everything at that point.
--
-- @tparam[opt] userdata widget re-theme only this subtree; omit for the whole dialog
function HostAPI:notifyTreeChange(widget)
    if self._shown and self._on_tree_change then
        self._on_tree_change(widget)
    end
end

--- Run `fn` on the shared cooperative scheduler; `cb(ok, ...)` gets the result.
--
-- Use this for anything that talks to the network (for HTTP, `HostAPI:http` does
-- it for you). IUP timer actions and widget callbacks run on the UI thread, so a
-- blocking socket call inside one freezes the whole window.
--
-- The scheduler is single-threaded and cooperative: tasks resume on the main
-- thread during the pump, so touching IUP widgets from inside `fn` or `cb` is
-- safe. ONE pump timer is owned by the host and shared by every caller, rather
-- than each extension running its own; it only ticks while tasks are live.
--
-- Degrades to a synchronous call when copas is unavailable, so callers never need
-- a separate fallback path.
--
-- @tparam function fn work to run
-- @tparam[opt] function cb completion callback receiving `pcall` results
-- @treturn boolean true when scheduled asynchronously
-- @usage ctx:runAsync(function() return client:health() end, function(ok, healthy) ... end)
function HostAPI:runAsync(fn, cb) return Network.runAsync(self, fn, cb) end

--- The shared `core.lib.async` module (copas bridge, `.http` transport, probeTcp).
-- @treturn table the async module
function HostAPI:async() return Network.async(self) end

--- Make an HTTP(S) request without blocking the window.
--
-- The request runs on the shared scheduler and `callback(res, err)` is called on
-- the UI thread when it finishes, so it may update widgets directly. HTTPS checks
-- the certificate chain and the host name unless the request says
-- `verify = "none"`. See `core.lib.http` for the request and response fields.
--
-- A non-2xx status is still a response (`res.ok` is false); `err` is set only
-- when there is no response at all. The callback is dropped if the owner unloads
-- first, or after `handle:cancel()`.
--
-- @tparam table request `{ url, method, headers, body | json, timeout, verify, cafile, max_bytes }`
-- @tparam function callback `callback(res, err)`
-- @tparam[opt] table owner owning extension
-- @treturn table a handle with `cancel()`
-- @usage
--    ctx:http({ url = "https://api.example.com/items", headers = { accept = "application/json" } },
--        function(res, err)
--            if not res then return ctx:setStatus("Couldn't load items: " .. err) end
--            local items = res.ok and res:json()
--        end, M)
function HostAPI:http(request, callback, owner) return Network.http(self, request, callback, owner) end

--- Run a tool as a JSON-lines job owned by an extension.
--
-- Starts a `core.lib.ProcessJob` (see it for `opts` and the protocol) and drives
-- it from the shared job timer. Unloading the owner cancels the job, which ends
-- the tool and everything it started, and no callback runs against the unloaded
-- extension afterwards.
--
-- @tparam table opts `core.lib.ProcessJob.start` options (`argv`, `cwd`, `env`,
--   `stdin`, `on_event`, `on_stderr`, `on_protocol_error`, `on_exit`, ...)
-- @tparam[opt] table owner owning extension
-- @treturn[1] table the job (`cancel()`, `done()`, `result()`)
-- @treturn[2] nil
-- @treturn[2] string why the tool could not be started
-- @usage
--    local job, err = ctx:startJob({
--        argv = { engine, "collect", "--json" },
--        on_event = function(ev) ctx:setStatus(ev.message or ev.type) end,
--        on_exit = function(res) ctx:setStatus(res.status .. ": " .. tostring(res.summary)) end,
--    }, M)
function HostAPI:startJob(opts, owner) return Network.startJob(self, opts, owner) end

--- Start a process owned by an extension (the native `process` module).
--
-- Same options and handle as `process.spawn`: argv only, separate non-blocking
-- stdout/stderr, child-only `cwd`/`env`, optional `stdin`. Unloading the owner
-- closes the handle, which ends the process and everything it started. Use
-- `HostAPI:startJob` for tools that speak the JSON-lines protocol.
--
-- @tparam table opts `{ argv, cwd, env, stdin }`
-- @tparam[opt] table owner owning extension
-- @treturn[1] userdata the process (`read`, `poll`, `kill`, `pid`, `close`)
-- @treturn[2] nil
-- @treturn[2] string why it could not be started
-- @usage local p, err = ctx:spawn({ argv = { "git", "status", "--porcelain" }, cwd = repo }, M)
function HostAPI:spawn(opts, owner) return Network.spawn(self, opts, owner) end
function HostAPI:_ownedSubprocess(module) return Network._ownedSubprocess(self, module) end
function HostAPI:_secretTarget(owner, name) return Secrets._secretTarget(self, owner, name) end

function HostAPI:_secretStore() return Secrets._secretStore(self) end

--- Read a secret (an API token, say) from the OS store: Windows Credential
-- Manager, or the desktop keyring on Linux. Never put secrets in settings.
-- @tparam table owner the extension
-- @tparam string name e.g. `"api-token"`
-- @treturn[1] string the value
-- @treturn[2] nil
-- @treturn[2] string `"not found"`, or why the store failed
-- @usage local token = ctx:getSecret(M, "api-token")
function HostAPI:getSecret(owner, name) return Secrets.getSecret(self, owner, name) end

--- Store (or replace) a secret in the OS store.
-- @tparam table owner the extension
-- @tparam string name
-- @tparam string value
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why it couldn't be stored
function HostAPI:setSecret(owner, name, value) return Secrets.setSecret(self, owner, name, value) end

--- Sign in to a file server (`\\server`) with an account other than the desktop
-- login, e.g. a separate file-server account. Remembered like Explorer's
-- "Remember my credentials", so `\\server\...` paths then work for every
-- program, including tools an extension runs. Test-connects before returning.
-- On Linux the share is mounted by the system instead; this returns why.
-- @tparam string server e.g. `"fileserver"`
-- @tparam string user e.g. `"DOMAIN\\name"` or `"name"`
-- @tparam string password
-- @tparam[opt=true] boolean remember keep it after signing out of Windows
-- @tparam[opt] string check_path a folder the account must be able to list for the
--   sign-in to count (recommended: some servers accept any account as a guest)
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why, in plain words
function HostAPI:networkLogin(server, user, password, remember, check_path) return Network.networkLogin(self, server, user, password, remember, check_path) end

--- Forget a file-server sign-in made with `networkLogin`.
function HostAPI:networkLogout(server) return Network.networkLogout(self, server) end

--- Delete a secret. Deleting one that doesn't exist succeeds.
-- @tparam table owner the extension
-- @tparam string name
function HostAPI:deleteSecret(owner, name) return Secrets.deleteSecret(self, owner, name) end

-- =======================================================================
-- MOTION
-- =======================================================================

--- Adopt the shared animation scheduler. Host-internal; called once by `main.lua`.
--
-- Also forwards the director to the toast host when one is already installed,
-- because startup order has the director set before the toast host in some
-- configurations and after in others.
--
-- @tparam MotionDirector director the `core.classes.MotionDirector`
-- @local
function HostAPI:setMotionDirector(director)
    self._motion = director
    if self._toasts then
        pcall(function() self._toasts:setDirector(director) end)
    end
end

--- The shared `core.classes.MotionDirector`.
--
-- Every animation in the application runs on this one scheduler, so extension
-- motion stays frame-locked with the host's and honours the user's motion
-- settings automatically. Prefer `HostAPI:animate` unless you need the
-- director's own methods (`enabled`, `cancel`, `finish`).
--
-- @treturn MotionDirector|nil the director, or `nil` if the host has none
-- @usage if ctx:motion() and ctx:motion():enabled() then ... end
function HostAPI:motion()
    return self._motion
end

--- Animate a value over time, following the Carbon motion system.
--
-- `spec` is passed through to `core.classes.MotionDirector:animate` -- see that
-- class for the full field list. The essentials:
--
--   * `duration` in ms, or `distance` in px to derive a Carbon-correct duration
--   * `curve` -- `"standard"` (default), `"entrance"` or `"exit"`
--   * `style` -- `"productive"` (default) or `"expressive"`
--   * `from`, `to` -- numeric endpoints
--   * `on_frame(value, t)` -- called per frame; keep it cheap
--   * `on_done(completed)` -- called once
--
-- The animation is tagged with the calling extension, so unloading it cancels
-- anything still in flight rather than leaving callbacks firing against destroyed
-- widgets.
--
-- **When motion is disabled** -- by the user, or by the OS reduce-motion setting --
-- `on_frame` is invoked once with the final value and `on_done(true)` follows,
-- both synchronously. So an animation is always safe to write as the only way a
-- property reaches its destination; there is no need to set the end state
-- separately or to branch on whether motion is on.
--
-- @tparam table spec animation specification
-- @tparam[opt] table owner owning extension (defaults to the host)
-- @treturn table|nil handle with `cancel()`, `finish()` and `done()`
-- @usage
--   ctx:animate{
--     distance = 240, curve = "entrance", style = "productive",
--     from = 0, to = 240,
--     on_frame = function(v) iup.SetAttribute(panel, "RASTERSIZE", "x" .. math.floor(v)) end,
--   }
function HostAPI:animate(spec, owner)
    local director = self._motion
    if not director then return nil end
    spec = spec or {}
    if spec.owner == nil then spec.owner = owner or DEFAULT_OWNER end
    return director:animate(spec)
end

-- =======================================================================
-- TOAST NOTIFICATIONS
-- =======================================================================

--- Adopt the toast host. Host-internal; called once by `main.lua`.
--
-- The toast host manages the live stack of Carbon notifications: their windows,
-- animations and cleanup. It must be created after the main dialog exists so it
-- can parent its per-toast windows there.
--
-- @tparam ToastHost host a `core.ui.Toast.ToastHost` instance
-- @local
function HostAPI:setToastHost(host)
    self._toasts = host
    -- Wire the director in so toasts respect motion settings even when the
    -- director is installed after the toast host (the normal startup order).
    if host and self._motion then
        host:setDirector(self._motion)
    end
end

--- The shared `core.ui.Toast.ToastHost`, or `nil` if the host has none.
--
-- Prefer `HostAPI:notify` unless you need the host's own methods.
--
-- @treturn ToastHost|nil
function HostAPI:toasts()
    return self._toasts
end

--- Post a Carbon toast notification.
--
-- The toast slides into the top-right corner of the main window, holds for
-- `spec.timeout` ms (or the `toast_enter` role's `hold` extra), then
-- dismisses itself. Clicking the close affordance dismisses immediately.
-- Multiple toasts stack vertically; when one leaves the others reflow.
--
-- `spec` fields:
--
--   * `title`   -- *(required)* heading text (`heading-compact-01`)
--   * `body`    -- *(optional)* secondary text (`body-compact-01`)
--   * `kind`    -- `"error"` | `"success"` | `"warning"` | `"info"` (default)
--   * `timeout` -- milliseconds before auto-dismiss; overrides the role default
--
-- The call is a silent no-op when there is no toast host or when window
-- creation fails -- callers never need to guard it.
--
-- @tparam table spec notification specification (see above)
-- @tparam[opt] table owner owning extension (toasts are dismissed on unload)
-- @usage
--   ctx:notify({ title = "Build complete", kind = "success" }, M)
--   ctx:notify({ title = "Connection failed",
--                body  = "Check the backend URL in Settings.",
--                kind  = "error" })
function HostAPI:notify(spec, owner)
    local host = self._toasts
    if not host then return end
    spec = spec or {}
    if spec.owner == nil then spec.owner = owner or DEFAULT_OWNER end
    pcall(function() host:show(spec) end)
end
function HostAPI:_ensureAsyncPump() return Network._ensureAsyncPump(self) end

--- Show the themed, in-app folder picker and return the chosen folder.
--
-- Extensions should call this instead of `iup.filedlg{ DIALOGTYPE = "DIR" }`: the
-- native Win32 folder browser is shell-drawn and stays light under every Lunar dark
-- theme. This wrapper supplies the parent dialog and the theme hook, so the picker
-- always matches the active theme.
--
-- @tparam[opt] table opts forwarded to `core.ui.FolderDialog.show`
-- @tparam[opt] string opts.title dialog caption
-- @tparam[opt] string opts.value folder to open at
-- @treturn string|nil selected absolute folder path, or `nil` if cancelled
-- @usage local dir = ctx:pickFolder{ title = "Select tool repository folder", value = current }
function HostAPI:pickFolder(opts)
    opts = opts or {}
    local FolderDialog = require("core.ui.FolderDialog")
    return FolderDialog.show({
        iup = self.iup,
        title = opts.title,
        value = opts.value,
        -- Carbon SVGs for the row/toolbar glyphs, and the settings store that backs
        -- the picker's pinned + recent folders. Both are optional in FolderDialog.
        icon_dir = opts.icon_dir
            or require("core.platform").path:join(self.app and self.app.dir or ".", "assets", "Icons"),
        settings = opts.settings or self.settings,
        parent = opts.parent or self.dialog,
        notify_tree_change = function(w) self:notifyTreeChange(w) end,
    })
end


--- The usable desktop area in pixels: the screen MINUS the taskbar.
--
-- SCREENSIZE is IUP's name for SPI_GETWORKAREA (see iupdrvGetScreenSize in
-- iupwin_info.c) -- the area a maximized window actually gets. FULLSIZE is the raw
-- panel size and INCLUDES the space behind the taskbar, so sizing against it makes
-- the app believe it has 40-60px of height (or width, on a side-docked taskbar)
-- that the shell will never give it. That is how the bottom of the UI ended up
-- underneath the taskbar. SCREENSIZE is therefore checked first and FULLSIZE is
-- only a fallback.
-- @treturn number width in pixels
-- @treturn number height in pixels
function HostAPI:workArea() return Layout.workArea(self) end

function HostAPI:_getScreenWidth() return Layout._getScreenWidth(self) end

--- The primary monitor's width in pixels (falls back to 1920 if IUP can't say).
-- @treturn number screen width in pixels
function HostAPI:screenWidth() return Layout.screenWidth(self) end

--- Scale a pixel measurement that was authored against a 1920px-wide screen.
--
-- Hard-coded pixel sizes (`RASTERSIZE = "132x32"` and friends) are why several
-- panels look right on a desktop monitor but have buttons running off the edge or
-- overlapping their neighbours on a laptop: the pixels stay put while the space
-- around them shrinks. Feeding them through this keeps their proportion of the
-- screen instead.
--
-- The result is clamped: below `min_scale` controls stop being clickable, and
-- above `max_scale` they turn cartoonish on ultrawides.
--
-- @tparam number px measurement authored at `base_width`
-- @tparam[opt] table opts options
-- @tparam[opt=1920] number opts.base_width reference screen width
-- @tparam[opt=0.72] number opts.min_scale lower clamp
-- @tparam[opt=1.25] number opts.max_scale upper clamp
-- @treturn number the scaled, rounded pixel value
-- @usage iup.SetAttribute(btn, "RASTERSIZE", ctx:scaleUi(132) .. "x" .. ctx:scaleUi(32))
function HostAPI:scaleUi(px, opts) return Layout.scaleUi(self, px, opts) end

function HostAPI:_scaleSidePadding(side_padding, opts) return Layout._scaleSidePadding(self, side_padding, opts) end

function HostAPI:_wrapTabForPadding(widget, opts) return Layout._wrapTabForPadding(self, widget, opts) end
function HostAPI:_wrapTabForScroll(widget) return Layout._wrapTabForScroll(self, widget) end

--- Append a tab to the main tab strip.
--
-- Lifecycle-aware: the tab is mapped immediately only when the dialog is already
-- visible; otherwise mapping is deferred to `IupShow`. The tab is recorded against
-- `owner` and destroyed by `HostAPI:removeOwned` on unload or reload.
--
-- @tparam string title tab title
-- @tparam userdata widget tab content
-- @tparam[opt] table owner owning extension (defaults to the shared host owner)
-- @tparam[opt] table opts layout options
-- @tparam[opt] number opts.side_padding side pixels requested in addition to auto-centering
-- @tparam[opt] number opts.vertical_padding top/bottom pixels; defaults to `side_padding`
--   so the tab is inset equally on all four edges
-- @tparam[opt=true] boolean opts.scale_side_padding scale `side_padding` with monitor width
-- @tparam[opt=1920] number opts.base_screen_width reference width used when scaling
-- @tparam[opt] number opts.max_content_width cap on tab content width; extra width
--   becomes symmetric side padding
-- @tparam[opt] string opts.group default tab group for this tab, e.g. `"Diagnostics"`
--   or `"Tools/Parsers"` to nest. Overrides the manifest's `group` field. Applied
--   only on first run — a user who moves the tab keeps their arrangement.
-- @tparam[opt=false] boolean opts.scroll wrap the tab in a scroll host so content taller
--   than the window stays reachable. Off by default: the scroll host is a native
--   container and becomes the background parent for every flat control inside it
--   (see `_wrapTabForScroll`), so opt in per tab and check the result visually.
-- @treturn userdata the original `widget` (not the padding/scroll wrappers)
-- @usage ctx:addTab("Hello", root_vbox, M, { max_content_width = 1400 })
function HostAPI:addTab(title, widget, owner, opts) return Layout.addTab(self, title, widget, owner, opts) end


--- Add any widget to the ordered status area at the right of the status bar (left of
--
-- Non-persistent elements are visible only while one of their owner's tabs is
-- active. Registrations are removed automatically with the owning extension.
--
-- @tparam userdata widget the widget to place in the status bar
-- @tparam[opt] table opts placement options
-- @tparam[opt=false] boolean opts.persistent remain visible when another owner's tab is active
-- @tparam[opt] number opts.position lower values render closer to the right edge
--   (defaults to registration order)
-- @tparam[opt] number|string opts.padding number or IUP `"HxV"` string applied only
--   around this element
-- @tparam[opt] string opts.tooltip hover text applied to the supplied widget
-- @tparam[opt] func opts.on_click `callback(widget, button, pressed, x, y, status_entry)`
-- @tparam[opt] table owner owning extension
-- @treturn userdata the supplied `widget`
-- @usage ctx:addStatusElement(icon, { persistent = true, position = 2 }, M)
function HostAPI:addStatusElement(widget, opts, owner) return Layout.addStatusElement(self, widget, opts, owner) end

--- Add a tab-scoped status-bar widget.
--
-- Backward-compatible wrapper around `HostAPI:addStatusElement`: extension-owned
-- widgets remain tab-scoped by default.
--
-- @tparam userdata widget the widget to place in the status bar
-- @tparam[opt] table owner owning extension
-- @treturn userdata the supplied `widget`
function HostAPI:addStatusWidget(widget, owner) return Layout.addStatusWidget(self, widget, owner) end
function HostAPI:_ensureFileSeparator() return Menus._ensureFileSeparator(self) end
function HostAPI:_ensureHelpSeparator() return Menus._ensureHelpSeparator(self) end
function HostAPI:_resetMenuSeparators() return Menus._resetMenuSeparators(self) end

--- Append or insert an extension menu item.
--
-- The item is shown only while one of the owning extension's tabs is active
-- (owners that contribute no tabs are always visible).
--
-- @tparam string title menu entry text
-- @tparam[opt] func callback invoked when the entry is selected
-- @tparam[opt="extensions"] string target destination menu: `"file"` (above the
--   File menu's separator, keeping Exit pinned at the bottom), `"help"` (above the
--   Help menu's separator, keeping About pinned at the bottom), or `"extensions"`
-- @tparam[opt] table owner owning extension
-- @treturn userdata the created IUP menu item
-- @usage ctx:addMenuItem("Open Repo...", open_repo, "file", M)
function HostAPI:addMenuItem(title, callback, target, owner) return Menus.addMenuItem(self, title, callback, target, owner) end

--- Add a color theme (host API 2).
--
-- `theme_class` subclasses `core.classes.Themes.Theme` (require it as
-- `"core.classes.Themes.Theme"`). The theme appears in the Theme menu and the
-- Settings selector, and is removed when the extension unloads. Themes are
-- applied after extensions load, so a user's saved choice of it is honoured.
--
-- @param theme_class Theme subclass.
-- @tparam[opt] table owner owning extension
-- @treturn[1] string the theme id
-- @treturn[2] nil
-- @treturn[2] string why it was refused (e.g. duplicate id)
-- @since host API 2
function HostAPI:registerTheme(theme_class, owner)
    if not self._theme_mgr then return nil, "themes are unavailable" end
    local id, err = self._theme_mgr:registerTheme(theme_class)
    if id then table.insert(self:_record(owner).themes, id) end
    return id, err
end

--- Make a font file available to this process (host API 2), e.g. a theme's
-- typeface shipped inside an org pack. Lasts until the app exits.
-- @tparam string path font file (`.ttf`, `.otf`, `.ttc`)
-- @treturn boolean
-- @treturn string|nil why not (Windows: GDI private font; Linux: fontconfig, GUI host only)
-- @since host API 2
function HostAPI:registerFont(path)
    return require("core.platform").register_font(path)
end

--- Add a disabled `"<name>   v<version>"` info entry pinned to the top of the Help menu.
--
-- Called by the `core.classes.ExtensionManager` for each loaded extension so
-- versions surface prominently; extensions rarely need to call it directly.
--
-- @tparam string name display name
-- @tparam string version version string
-- @tparam[opt] table owner owning extension
-- @treturn userdata|nil the created menu item, or `nil` when there is no Help menu
function HostAPI:addVersionInfo(name, version, owner) return Menus.addVersionInfo(self, name, version, owner) end

--- Create a host-owned IUP timer.
--
-- The timer is destroyed automatically when the owner is unloaded. A callback that
-- raises is isolated: the timer is disarmed and the error is reported once through
-- the status bar, instead of re-firing and flooding the app with IUP error dialogs.
--
-- @tparam table opts timer options
-- @tparam[opt=100] number opts.time interval in milliseconds
-- @tparam[opt] func opts.action callback invoked on each tick
-- @tparam[opt=false] boolean opts.run start the timer immediately
-- @tparam[opt] table owner owning extension
-- @treturn userdata the timer handle, so `RUN` can be toggled with `iup.SetAttribute`
-- @usage local t = ctx:addTimer({ time = 500, action = poll, run = true }, M)
function HostAPI:addTimer(opts, owner)
    local iup = self.iup
    local timer = iup.timer{
        TIME = tostring(opts.time or 100),
        RUN  = opts.run and "YES" or "NO",
    }
    local action = opts.action
    local host = self
    function timer:action_cb()
        if action then
            -- A throwing timer callback would otherwise re-fire on every tick and
            -- spawn an unbounded flood of IUP "Lua Error" dialogs. Isolate the
            -- failure, disarm the timer, and report it once via the status channel.
            local ok, err = xpcall(action, debug.traceback)
            if not ok then
                iup.SetAttribute(timer, "RUN", "NO")
                if host._status_fn then
                    pcall(host._status_fn, "Timer error: " .. tostring(err))
                end
            end
        end
        return iup.DEFAULT
    end
    table.insert(self:_record(owner).timers, timer)
    return timer
end

--- Register a settings section in the centralized Settings view.
--
-- The section appears under a category divider named `category` and is removed with
-- the owning extension.
--
-- @tparam string category category divider the section is filed under
-- @tparam table opts either `{ entries = { { label, description, widget }, ... } }`
--   or `{ widget = <prebuilt widget> }`
-- @tparam[opt] table owner owning extension
-- @treturn table|nil the section record, or `nil` when the host has no settings view
-- @usage
--    ctx:addSettings("Hello", {
--        entries = {
--            { label = "Backend URL", description = "Lunar backend", widget = url_text },
--        },
--    }, M)
function HostAPI:addSettings(category, opts, owner)
    if not self._settings_view then return end
    local section = self._settings_view:addSection(category, opts, self._shown)
    local rec = self:_record(owner)
    rec.settings[#rec.settings + 1] = section
    -- Theme only the newly added rows (coalesced), instead of re-walking the whole
    -- dialog, so contributing many settings sections doesn't trigger N full re-themes.
    if self._shown and self._on_tree_change and section and section.widgets then
        for _, w in ipairs(section.widgets) do
            self._on_tree_change(w)
        end
    end
    return section
end

--- Register a handler for one `lunar://plugin/<id>/<action>` route action.
--
-- The handler receives the parsed query parameters and the full route table, and
-- runs after the host has activated the extension's first tab.
--
-- @tparam string action action name (the path segment after the plugin id)
-- @tparam func fn `handler(params, route)`
-- @tparam[opt] table owner owning extension
-- @treturn func the registered handler
-- @raise when `action` is empty or `fn` is not a function
-- @usage
--    ctx:registerRouteHandler("run", function(params)
--        start_run(params.preset)
--    end, M)
function HostAPI:registerRouteHandler(action, fn, owner) return Routing.registerRouteHandler(self, action, fn, owner) end

--- Register the function that describes this extension's current address.
--
-- The host calls it when the user copies the current `lunar://` address. It must
-- return a route table, e.g. `{ action = "run", params = { preset = "amd" } }`.
--
-- @tparam func fn serializer returning a route table
-- @tparam[opt] table owner owning extension
-- @treturn func the registered serializer
-- @raise when `fn` is not a function
function HostAPI:registerRouteSerializer(fn, owner) return Routing.registerRouteSerializer(self, fn, owner) end

--- Run `fn` once the main window is shown and all widgets are mapped.
--
-- If the window is already shown, `fn` runs immediately (post-show semantics still
-- hold). Errors are caught and reported through the status bar. Pending callbacks
-- are dropped when the owner is unloaded.
--
-- @tparam func fn callback to run after the first show
-- @tparam[opt] table owner owning extension
-- @usage ctx:onReady(function() list:populate() end, M)
function HostAPI:onReady(fn, owner)
    if self._shown then
        local ok, err = pcall(fn)
        if not ok then self:setStatus("onReady error: " .. tostring(err)) end
        return
    end
    table.insert(self._ready, { fn = fn, owner = owner })
end

--- Flush the `onReady` queue. Called exactly once by `main.lua` after `IupShow`.
-- @local
function HostAPI:_markShown()
    self._shown = true
    -- Structural changes from here on happen against a mapped tree, so the group
    -- manager must start remapping the pages it moves.
    if self._tab_groups then self._tab_groups:markShown() end
    local queued = self._ready
    self._ready = {}
    for _, e in ipairs(queued) do
        local ok, err = pcall(e.fn)
        if not ok then self:setStatus("onReady error: " .. tostring(err)) end
    end
    -- Tabs are mapped now; show only the active tab owner's contributed menu items
    -- and status-bar widgets.
    self:_applyTabScopes()
    if self._on_tree_change then self._on_tree_change() end
end

--- Tear down everything an owner registered.
--
-- Removes timers, menu items, status elements, settings sections, tabs, shortcuts,
-- route registrations and still-pending `onReady` callbacks, cancels HTTP requests
-- and jobs, and ends processes started through `startJob`, `spawn` or an owned
-- `subprocess` call. Each step runs on its own, so one that fails is logged and
-- the rest still run. The
-- `core.classes.ExtensionManager` calls this on unload and reload, so extensions
-- get precise cleanup without tracking their own resources.
--
-- @tparam table owner the owning extension
-- @treturn boolean `true` once cleanup has run
-- @treturn number how many steps failed (each was logged)
function HostAPI:removeOwned(owner)
    local iup = self.iup
    local r = self._owners[owner]
    local host = self

    -- Every step runs on its own: one widget that throws while being destroyed
    -- must not leave the rest of the extension (timers, processes, tabs) behind.
    local failures = 0
    local function step(what, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            failures = failures + 1
            pcall(function() host.log:warn("removeOwned: " .. what .. " failed: " .. tostring(err)) end)
        end
    end

    -- Cancel first, before anything is detached or destroyed. An in-flight
    -- animation holds a closure over this owner's widgets and fires up to 60
    -- times a second; letting it survive one more frame means it writes
    -- attributes to handles that were destroyed a few lines below.
    if self._motion then
        step("cancel animations", function() self._motion:cancel({ owner = owner }) end)
    end

    -- Dismiss any toasts posted by this owner. Must happen after animation
    -- cancellation (so no in-flight enter/exit fires against the dying extension)
    -- and before widget teardown below.
    if self._toasts then
        step("dismiss toasts", function() self._toasts:dismissOwned(owner) end)
    end

    if r then
        -- Requests still in flight finish on the scheduler, but their callbacks
        -- would run against an unloaded extension.
        for request in pairs(r.requests or {}) do step("cancel request", request.cancel) end
        r.requests = {}

        -- Jobs: silence their callbacks, then end the tool and its children. The
        -- shared job timer finishes them on its next tick.
        for entry in pairs(r.jobs or {}) do
            entry.alive = false
            step("cancel job", function() entry.job:cancel() end)
        end
        r.jobs = {}

        -- Drop this owner's tab-scoped menu registrations and keyboard shortcuts.
        if #self._tab_scoped > 0 then
            local kept = {}
            for _, s in ipairs(self._tab_scoped) do
                if s.owner ~= owner then kept[#kept + 1] = s end
            end
            self._tab_scoped = kept
        end
        if #self._status_scoped > 0 then
            local kept = {}
            for _, s in ipairs(self._status_scoped) do
                if s.owner == owner then
                    if s.present then pcall(iup.Detach, s.container) end
                    step("destroy status element", iup.Destroy, s.container)
                else
                    kept[#kept + 1] = s
                end
            end
            self._status_scoped = kept
            -- The cached arrangement names entries that have just been destroyed,
            -- so the next _applyStatusScope must not compare against it and decide
            -- the bar is already correct.
            self._status_visible = nil
        end
        for _, entry in ipairs(r.shortcuts or {}) do
            local list = self._shortcuts[entry.key]
            if list then
                for i = #list, 1, -1 do
                    if list[i] == entry then table.remove(list, i) end
                end
                if #list == 0 then self._shortcuts[entry.key] = nil end
            end
        end

        for _, section in ipairs(r.settings or {}) do
            if self._settings_view then
                step("remove settings section", self._settings_view.removeSection, self._settings_view, section)
            end
        end
        for _, timer in ipairs(r.timers) do
            step("stop timer", iup.SetAttribute, timer, "RUN", "NO")
            step("destroy timer", iup.Destroy, timer)
        end
        -- Processes go after the timers: nothing of this owner's can poll a handle
        -- once it is closed.
        for proc in pairs(r.processes or {}) do
            step("close process", function() proc:close() end)
        end
        r.processes = {}
        if self.subprocess then
            local raw = self.subprocess.raw
            for proc in pairs(r.subprocesses or {}) do
                self._subprocess_owner[proc] = nil
                step("terminate subprocess", raw.terminate, proc)
                step("destroy subprocess", raw.destroy, proc)
            end
        end
        r.subprocesses = {}
        for _, theme_id in ipairs(r.themes or {}) do
            if self._theme_mgr then step("unregister theme", self._theme_mgr.unregisterTheme, self._theme_mgr, theme_id) end
        end
        for _, item in ipairs(r.items) do
            pcall(iup.Detach, item)   -- may already be detached if its tab was inactive
            step("destroy menu item", iup.Destroy, item)
        end
        -- The Help version-block anchor may have pointed at one of the destroyed
        -- items; recompute it on the next addVersionInfo (e.g. after reload).
        self._help_version_after = nil
        for _, tab in ipairs(r.tabs) do
            step("remove tab", function()
                local tab_id = iup.GetAttribute(tab, "HOSTTABOWNERID")
                if tab_id then self._owner_by_tab[tab_id] = nil end
                -- Told BEFORE the detach: the group manager decides whether the group
                -- this tab was in should survive losing it, which it can only work out
                -- while the tab is still attached.
                if self._tab_groups then pcall(function() self._tab_groups:forget(tab) end) end
                iup.Detach(tab)
                iup.Destroy(tab)
            end)
        end
        self._owners[owner] = nil
    end

    local manifest = self._manifest_by_owner[owner]
    if manifest and self._owner_by_extension_id[manifest.id] == owner then
        self._owner_by_extension_id[manifest.id] = nil
    end
    self._manifest_by_owner[owner] = nil
    self._root_group_by_owner[owner] = nil
    self._route_handlers[owner] = nil
    self._route_serializers[owner] = nil

    if #self._ready > 0 then
        local kept = {}
        for _, e in ipairs(self._ready) do
            if e.owner ~= owner then table.insert(kept, e) end
        end
        self._ready = kept
    end

    step("fix file separator", self._fixupFileSeparator, self)
    step("apply status scope", self._applyStatusScope, self)
    if self.tabs then step("refresh tabs", iup.Refresh, self.tabs) end
    return true, failures
end
function HostAPI:_activeOwner() return Layout._activeOwner(self) end
function HostAPI:_activeTab() return Layout._activeTab(self) end

function HostAPI:_tabIndex(widget) return Layout._tabIndex(self, widget) end

function HostAPI:_activateTabWidget(widget) return Layout._activateTabWidget(self, widget) end
function HostAPI:_routeError(code, message) return Routing._routeError(self, code, message) end

--- Parse and dispatch a `lunar://` URI.
--
-- Host routes (`lunar://host/<id>`) activate a host tab; plugin routes
-- (`lunar://plugin/<id>[/<action>]`) activate the extension's first tab and then
-- invoke the handler registered with `HostAPI:registerRouteHandler`.
--
-- @tparam string uri a `lunar://` address
-- @treturn boolean|nil `true` on success, `nil` on failure
-- @treturn table on success the route (or the handler's return value); on failure an
--   error record `{ code, message }` with `code` one of `"invalid_route"`,
--   `"unknown_host_target"`, `"unknown_host_action"`, `"host_target_unavailable"`,
--   `"unknown_plugin"`, `"unknown_plugin_action"`, `"route_handler_error"`
-- @see core.lib.RouteUri
function HostAPI:dispatchRoute(uri) return Routing.dispatchRoute(self, uri) end

--- Serialize the currently active tab as a `lunar://` URI.
--
-- For an extension tab the registered route serializer supplies the action and
-- parameters; for a host tab the registered host id is used.
--
-- @treturn string|nil the address, or `nil` when the active tab cannot be addressed
function HostAPI:currentRoute() return Routing.currentRoute(self) end

function HostAPI:_walkTree(ih, fn) return Layout._walkTree(self, ih, fn) end

function HostAPI:_tagTreeOwner(ih, tab_id) return Layout._tagTreeOwner(self, ih, tab_id) end

function HostAPI:_installKeyDispatch(ih) return Keys._installKeyDispatch(self, ih) end

--- Install the dialog-level key dispatcher on a widget subtree.
--
-- Extensions that create their own dialogs can call this so host shortcuts keep
-- working inside them.
--
-- @tparam userdata root the widget (usually a dialog) to install the dispatcher on
function HostAPI:installKeyDispatch(root) return Keys.installKeyDispatch(self, root) end
function HostAPI:_insertScopedItem(s) return Menus._insertScopedItem(self, s) end
function HostAPI:_applyMenuScope() return Menus._applyMenuScope(self) end
function HostAPI:_applyStatusScope() return Layout._applyStatusScope(self) end
function HostAPI:_applyTabScopes() return Layout._applyTabScopes(self) end

--- Describe the currently active tab as a route table.
-- @treturn table|nil `{ kind = "host"|"plugin", target = <id>, params = {...} }`,
--   or `nil` when the active tab cannot be addressed
function HostAPI:currentAddress() return Routing.currentAddress(self) end

--- Serialized form of `HostAPI:currentAddress`.
-- @treturn string|nil a `lunar://` URI, or `nil` when the active tab cannot be addressed
function HostAPI:currentAddressURI() return Routing.currentAddressURI(self) end

--- Dispatch an address supplied as either a `lunar://` URI or an already-parsed route.
--
-- This is what the address dialog uses. Compared with `HostAPI:dispatchRoute` it
-- accepts route tables and reports user-facing error messages.
--
-- @tparam string|table uri_or_route a `lunar://` URI or a route table
-- @treturn boolean|nil `true` on success, `nil` on failure
-- @treturn table on success the route or handler result; on failure an error record
--   `{ code, message }` with `code` one of `"malformed_route"`, `"unknown_route"`,
--   `"route_unavailable"`, `"dispatch_failed"`
function HostAPI:dispatchAddress(uri_or_route) return Routing.dispatchAddress(self, uri_or_route) end
function HostAPI:_fixupFileSeparator() return Menus._fixupFileSeparator(self) end

-- =======================================================================
-- KEYBOARD SHORTCUTS (dialog-level)
-- =======================================================================

--- Adopt the main dialog and install the dialog-level key dispatcher.
--
-- Called by the host once the dialog exists (it is created after the `HostAPI`).
--
-- @tparam userdata dialog the main dialog handle
function HostAPI:setDialog(dialog)
    self.dialog = dialog
    if not dialog then return end
    self:_installKeyDispatch(dialog)
end
function HostAPI:_dispatchKey(c) return Keys._dispatchKey(self, c) end

--- Register a dialog-level keyboard shortcut.
--
-- The shortcut fires only while the owner is in scope (see the scoping rules in
-- `HostAPI:_dispatchKey`). Multiple owners may register the same key; all
-- registrations are removed by `HostAPI:removeOwned`.
--
-- @tparam number key an IUP key code, e.g. `iup.K_cA`
-- @tparam func fn invoked when the key is pressed while in scope
-- @tparam[opt] table owner owning extension
-- @treturn table|nil the shortcut record, or `nil` when `key` or `fn` is missing
-- @usage ctx:registerShortcut(iup.K_cR, function() rescan() end, M)
function HostAPI:registerShortcut(key, fn, owner) return Keys.registerShortcut(self, key, fn, owner) end

return HostAPI
