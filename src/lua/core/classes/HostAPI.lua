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
-- @field subprocess the native `subprocess` module
-- @field tabs the main tab strip handle
-- @field ext_menu the Extensions menu handle
-- @field file_menu the File menu handle
-- @field help_menu the Help menu handle
-- @field dialog the main dialog handle (set by `HostAPI:setDialog`)
-- @field log the host's own `core.lib.log` logger
-- @field ui reusable widget classes: `ContextMenu`, `ReorderableList`, `CheckList`,
--   `SettingsView`
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
local L = require("core.lib.CarbonLayout")
local applog = require("core.lib.log")
-- Handle identity. IUP handles must never be compared with `==` -- the Lua
-- binding allocates a fresh userdata on every push, so two handles for the same
-- widget compare unequal. See core.lib.handle.
local handle = require("core.lib.handle")
local tree = require("core.lib.tree")
local RouteUri = require("core.lib.RouteUri")

-- Reusable UI toolkit exposed to extensions as ctx.ui (and also require-able as
-- core.ui.*). These cover the common heavy-lifting widgets so extensions don't each
-- reimplement them: popup menus, drag-reorderable multi-select lists, and checkbox
-- browsers.
local UI_TOOLKIT = {
    ContextMenu     = require("core.ui.ContextMenu"),
    ReorderableList = require("core.ui.ReorderableList"),
    CheckList       = require("core.ui.CheckList"),
    SettingsView    = require("core.ui.SettingsView"),
}

local HostAPI = class("HostAPI")

-- Sentinel owner for registrations made without an explicit owner.
local DEFAULT_OWNER = {}

--- Construct the host context. Called once by the host; extensions never call this.
-- @local
-- @tparam table opts host-supplied handles (iup, app, settings, subprocess, tabs,
--   menus, status callbacks, settings view)
function HostAPI:initialize(opts)
    self.iup        = opts.iup
    self.app        = opts.app
    self.settings   = opts.settings
    self.subprocess = opts.subprocess
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
              requests = {} }
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
function HostAPI:registerHostTab(id, widget)
    if type(id) ~= "string" or id == "" or not widget then
        return
    end
    self._host_tabs[id] = widget
    -- Host tabs are appended directly rather than through addTab, so they get
    -- their layout key here. Without one, core.classes.TabGroups cannot record
    -- where the user filed the Settings tab and it would jump back to the end of
    -- the strip on every launch.
    --
    -- The "_IUP" prefix makes this a LOCAL attribute. Without it IUP treats an
    -- unregistered attribute as inheritable and every widget inside the page
    -- reports the same key -- see the constants block in core.classes.TabGroups.
    pcall(self.iup.SetAttribute, widget, "_IUPLUNAR_TABKEY", "host/" .. id)
end

--- Adopt the tab-group manager. Host-internal; called once by `main.lua`.
-- @local
-- @tparam TabGroups groups the `core.classes.TabGroups` instance
function HostAPI:setTabGroups(groups)
    self._tab_groups = groups
end

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
function HostAPI:runAsync(fn, cb)
    local async = self:async()
    local scheduled = async.run(fn, cb)
    if scheduled then
        self:_ensureAsyncPump()
    end
    return scheduled
end

--- The shared `core.lib.async` module (copas bridge, `.http` transport, probeTcp).
-- @treturn table the async module
function HostAPI:async()
    if not self._async then
        self._async = require("core.lib.async")
    end
    return self._async
end

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
function HostAPI:http(request, callback, owner)
    local request_handle = { cancelled = false }
    function request_handle.cancel() request_handle.cancelled = true end
    local requests = self:_record(owner).requests
    requests[request_handle] = true

    local host = self
    local function finish(res, err)
        requests[request_handle] = nil
        if request_handle.cancelled or type(callback) ~= "function" then return end
        local ok, cb_err = xpcall(function() callback(res, err) end, debug.traceback)
        if not ok and host._status_fn then
            pcall(host._status_fn, "HTTP callback error: " .. tostring(cb_err))
        end
    end
    self:runAsync(function()
        return require("core.lib.http").request(request)
    end, function(ok, res, err)
        if not ok then return finish(nil, tostring(res)) end
        finish(res, err)
    end)
    return request_handle
end

-- =======================================================================
-- SECRETS
-- =======================================================================

-- Where an extension's secret lives in the OS store. Namespaced by manifest id,
-- so one extension can't read another's.
function HostAPI:_secretTarget(owner, name)
    local manifest = self._manifest_by_owner[owner]
    if not (manifest and type(manifest.id) == "string") then
        return nil, "secrets need a registered extension"
    end
    if type(name) ~= "string" or not name:match("^[%w][%w._-]*$") then
        return nil, "secret names are letters, digits, '.', '_' and '-'"
    end
    return "Lunar Extension Host/" .. manifest.id .. "/" .. name
end

function HostAPI:_secretStore()
    return self._secret_store or require("core.platform")
end

--- Read a secret (an API token, say) from the OS store: Windows Credential
-- Manager, or the desktop keyring on Linux. Never put secrets in settings.
-- @tparam table owner the extension
-- @tparam string name e.g. `"api-token"`
-- @treturn[1] string the value
-- @treturn[2] nil
-- @treturn[2] string `"not found"`, or why the store failed
-- @usage local token = ctx:getSecret(M, "api-token")
function HostAPI:getSecret(owner, name)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    return self:_secretStore().secret_get(target)
end

--- Store (or replace) a secret in the OS store.
-- @tparam table owner the extension
-- @tparam string name
-- @tparam string value
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why it couldn't be stored
function HostAPI:setSecret(owner, name, value)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    if type(value) ~= "string" or value == "" then return nil, "a secret must be a non-empty string" end
    return self:_secretStore().secret_set(target, value)
end

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
function HostAPI:networkLogin(server, user, password, remember, check_path)
    if type(server) ~= "string" or type(user) ~= "string" or type(password) ~= "string"
        or server == "" or user == "" then
        return nil, "server, user name and password are required"
    end
    return self:_secretStore().network_login(server, user, password, remember ~= false, check_path)
end

--- Forget a file-server sign-in made with `networkLogin`.
function HostAPI:networkLogout(server)
    return self:_secretStore().network_logout(server)
end

--- Delete a secret. Deleting one that doesn't exist succeeds.
-- @tparam table owner the extension
-- @tparam string name
function HostAPI:deleteSecret(owner, name)
    local target, err = self:_secretTarget(owner, name)
    if not target then return nil, err end
    return self:_secretStore().secret_delete(target)
end

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

-- Start (or restart) the single shared pump timer. It stops itself as soon as
-- every task has drained, so an idle app pays nothing.
function HostAPI:_ensureAsyncPump()
    local iup = self.iup
    local async = self:async()
    if not async.available then return end
    if not self._async_timer then
        local timer = iup.timer({ TIME = 15, RUN = "NO" })
        local host = self
        function timer:action_cb()
            -- Re-entrancy guard. A task may open a modal (iup.Alarm/Message),
            -- which runs a NESTED message loop -- so this timer can fire again
            -- while we are still inside copas.step. copas is not re-entrant, and
            -- stepping it from within itself corrupts its task list.
            if host._async_in_pump then return iup.DEFAULT end
            host._async_in_pump = true
            local ok, more = pcall(async.pump)
            host._async_in_pump = false
            if not ok or not more then
                pcall(iup.SetAttribute, timer, "RUN", "NO")
                host._async_pumping = false
            end
            return iup.DEFAULT
        end
        self._async_timer = timer
    end
    if not self._async_pumping then
        self._async_pumping = true
        pcall(iup.SetAttribute, self._async_timer, "RUN", "YES")
    end
end

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

local function to_int(value, default)
    local n = tonumber(value)
    if not n then return default end
    return math.floor(n + 0.5)
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
function HostAPI:workArea()
    local iup = self.iup
    -- Prefer the shell-accurate figure, which also accounts for an AUTO-HIDE
    -- taskbar (SPI_GETWORKAREA does not -- see core.lib.desktop).
    local ok_desktop, desktop = pcall(require, "core.lib.desktop")
    if ok_desktop and desktop then
        local w, h = desktop.usableArea()
        if w and h and w > 0 and h > 0 then
            return w, h
        end
    end
    for _, name in ipairs({ "SCREENSIZE", "FULLSIZE" }) do
        local ok, value = pcall(iup.GetGlobal, name)
        if ok and type(value) == "string" then
            local w, h = value:match("^(%d+)%s*x%s*(%d+)")
            w, h = tonumber(w), tonumber(h)
            if w and h and w > 0 and h > 0 then
                return w, h
            end
        end
    end
    return 1920, 1080
end

function HostAPI:_getScreenWidth()
    local w = self:workArea()
    return w
end

--- The primary monitor's width in pixels (falls back to 1920 if IUP can't say).
-- @treturn number screen width in pixels
function HostAPI:screenWidth()
    return self:_getScreenWidth()
end

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
function HostAPI:scaleUi(px, opts)
    local value = tonumber(px)
    if not value then return 0 end
    opts = opts or {}
    local base = tonumber(opts.base_width) or 1920
    if base <= 0 then base = 1920 end
    local min_scale = tonumber(opts.min_scale) or 0.72
    local max_scale = tonumber(opts.max_scale) or 1.25
    local scale = self:_getScreenWidth() / base
    if scale < min_scale then scale = min_scale end
    if scale > max_scale then scale = max_scale end
    return to_int(value * scale, 0)
end

function HostAPI:_scaleSidePadding(side_padding, opts)
    local pad = tonumber(side_padding) or 0
    if pad <= 0 then return 0 end
    if opts and opts.scale_side_padding == false then
        return to_int(pad, 0)
    end
    local base_width = tonumber(opts and opts.base_screen_width) or 1920
    if base_width <= 0 then base_width = 1920 end
    local scale = self:_getScreenWidth() / base_width
    if scale < 0.5 then scale = 0.5 end
    return to_int(pad * scale, 0)
end

function HostAPI:_wrapTabForPadding(widget, opts)
    if type(opts) ~= "table" then return widget end
    local side_padding = self:_scaleSidePadding(opts.side_padding, opts)
    local max_width = to_int(opts.max_content_width, nil)
    if side_padding <= 0 and (not max_width or max_width <= 0) then
        return widget
    end

    local iup = self.iup

    -- Centering is done with MARGIN, NOT with iup.fill{} on either side.
    --
    -- The fill approach does not work here and produced the left-shifted Log Parser
    -- with a wide dead strip down the right. In an IupHbox, free space is split
    -- between ALL expanding children -- and the tab content expands too. Capping it
    -- with MAXSIZE stops it growing, but IUP's single-pass layout does not then
    -- hand the surplus back to the fills, so the leftover simply piles up after the
    -- last child. The content ends up flush left, which is the opposite of centered.
    --
    -- Computing the margin instead makes the result symmetric by construction: the
    -- same number is applied to both edges, so the content cannot drift.
    local vertical = opts.vertical_padding
    vertical = vertical and self:_scaleSidePadding(vertical, opts) or side_padding

    local horizontal = side_padding
    if max_width and max_width > 0 then
        -- Widen the gutter until the content is capped at max_width. Measured
        -- against the screen because the tab has no size yet at build time; the
        -- window opens maximized, so the two agree in the normal case.
        local screen_w = self:_getScreenWidth()
        if screen_w > max_width then
            horizontal = math.max(horizontal, math.floor((screen_w - max_width) / 2))
        end
        -- Never let the gutter eat the content: on a restored (non-maximized)
        -- window a margin sized for the full screen would squeeze the panel.
        local cap = math.floor(screen_w * 0.12)
        if horizontal > cap then horizontal = cap end
    end

    return iup.vbox{
        widget,
        MARGIN = tostring(horizontal) .. "x" .. tostring(vertical),
        GAP = L.gap(0),
        EXPAND = "YES",
    }
end

--- Wrap tab content in a scroll host so nothing can be clipped out of reach.
--
-- On a small screen the bottom of a tall tab would otherwise sit under the
-- taskbar with no way to reach it: the dialog has SHRINK="YES", and IUP simply
-- clips a child that does not fit.
--
-- IupScrollBox is exactly the right container here, and notably does NOT cost the
-- fill-the-tab behaviour every existing tab relies on. Its
-- SetChildrenCurrentSize gives the child `max(child natural size, scrollbox
-- size)`: bigger than the tab -> child keeps its natural size and scrollbars
-- appear; smaller -> the child is stretched to the scrollbox, exactly as before.
-- So EXPAND="YES" panels still fill the tab and only overflow starts scrolling.
--
-- OPT-IN ONLY (`opts.scroll == true`), and it should stay that way.
--
-- DO NOT enable this by default to solve tab-height problems -- that was tried and
-- reverted twice. It does fix the height (a mapped scrollbox reports a natural
-- size of 0, so the page stops inflating the window), but it is a NATIVE container,
-- and every flat control resolves its background by walking to the nearest native
-- parent and reading that parent's STORED BGCOLOR
-- (iupBaseNativeParentGetBgColorAttrib; if it finds none it falls back to
-- IupGetGlobal("DLGBGCOLOR"), i.e. white). Inserting one re-parents the entire tab
-- and paints solid white blocks behind every label. `addTab` caps the page's
-- natural height with MAXSIZE instead, which needs no extra widget.
--
-- A scrollbox is a NATIVE container. Every flat control resolves its own
-- background by walking up to the nearest native parent
-- (`iupBaseNativeParentGetBgColorAttrib` in iup_flatlabel.c / iup_flatbutton.c /
-- iup_flatseparator.c, and `bg_str` in the forked rounded iup_gauge.c). Plain
-- vbox/hbox are VOID containers with no native window, so that walk normally
-- reaches the dialog. Dropping a scrollbox into every tab silently re-parents the
-- whole app: each flat label, button, separator and gauge starts blending against
-- the scrollbox's color instead of the dialog's. Applied globally that produced a
-- visible rectangle behind every piece of flat text and broke the gauge's
-- anti-aliased rounded corners (they are blended against that same background).
--
-- So a tab only gets a scroll host when it actually needs one, and whoever opts in
-- owns checking that its flat controls still sit on the right color.
--
-- The container itself is well-behaved otherwise: IupScrollBox's
-- SetChildrenCurrentSize gives the child `max(child natural size, scrollbox
-- size)`, so EXPAND="YES" panels still fill the tab and only genuine overflow
-- scrolls.
--
-- flatscrollbox (not the native scrollbox) keeps the owner-drawn themed bars used
-- everywhere else; THEMEROLE="tabscroll" paints it in the dialog background with
-- no border so the host itself is invisible.
function HostAPI:_wrapTabForScroll(widget)
    local iup = self.iup
    local ok, box = pcall(iup.flatscrollbox, {
        widget,
        EXPAND = "YES",
        THEMEROLE = "tabscroll",
        BORDER = "NO",
        BORDERWIDTH = "0",
    })
    if not ok or not box then
        -- Never let a missing/renamed control cost the user their tab.
        return widget
    end
    return box
end

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
function HostAPI:addTab(title, widget, owner, opts)
    local iup = self.iup
    local tab_widget = self:_wrapTabForPadding(widget, opts)
    -- Scroll host goes OUTSIDE the padding/centering wrapper, so the wrapper's
    -- centering fills still measure against the real tab width rather than the
    -- (unbounded) scrolled virtual area. OPT-IN -- see _wrapTabForScroll for why
    -- this must not be applied to every tab.
    if opts and opts.scroll == true then
        tab_widget = self:_wrapTabForScroll(tab_widget)
    end

    -- CAP THE PAGE'S NATURAL HEIGHT. This is what keeps the status bar on screen.
    --
    -- A dialog is sized from its content (iDialogComputeNaturalSizeMethod), and an
    -- IUP box NEVER shrinks a child below its natural height -- iVboxCalcEmptyHeight
    -- computes the leftover as (currentheight - total_natural_size) and then does
    -- `if (empty_height < 0) empty_height = 0`. So a page taller than the window
    -- does not compress: it keeps its full height and everything after it (the
    -- status bar) is positioned off the bottom of the client area. SHRINK="YES"
    -- only lets the BOX be small; it does not compress children.
    --
    -- MAXSIZE is the lever, because iupBaseComputeNaturalSize finishes with
    -- `iupLayoutApplyMinMaxSize(ih, &naturalwidth, &naturalheight)` -- it crops the
    -- NATURAL size, not just the current one. Capping the page at the height a tab
    -- actually gets means its natural size can never exceed the space available,
    -- so the deficit never appears and the status bar keeps its room.
    --
    -- Deliberately NOT done with a scroll host. A scrollbox achieves the same
    -- decoupling (its natural size is 0) but is a NATIVE container, and inserting
    -- one changes what every flat control inside resolves as its background
    -- (iupBaseNativeParentGetBgColorAttrib walks to the nearest native parent), which
    -- painted white blocks behind the labels. This adds no widgets at all.
    --
    -- Height only: horizontal overflow is not the problem and capping width would
    -- fight max_content_width.
    do
        local _, work_h = self:workArea()
        -- Chrome above/below the tab page: title bar + menu, the tab strip itself,
        -- the accent strip and the status bar. Measured from the running app
        -- (work 1200 -> client 1066 -> tab area ~1022).
        local CHROME_H = 130
        local cap = math.max(320, (tonumber(work_h) or 1080) - CHROME_H)
        pcall(iup.SetAttribute, tab_widget, "MAXSIZE", "65535x" .. cap)
    end

    iup.SetAttribute(tab_widget, "TABTITLE", title)
    -- Tag the tab with a unique id so the active owner can be resolved from the
    -- focused control anywhere inside the tab tree. This is more robust than asking
    -- the tab strip for its active handle, because focus may live on a descendant
    -- widget instead of the page root.
    self._tab_seq = self._tab_seq + 1
    local tab_id = "hosttab" .. self._tab_seq
    self._owner_by_tab[tab_id] = owner or DEFAULT_OWNER
    self:_tagTreeOwner(tab_widget, tab_id)
    self:_installKeyDispatch(tab_widget)

    -- Layout identity for core.classes.TabGroups. This has to be STABLE across
    -- runs -- it is the key the saved group layout refers to -- so it is derived
    -- from the manifest id and the tab's ordinal within its extension, not from
    -- _tab_seq (which depends on plugin load order) or the title (which the
    -- extension may change).
    --
    -- Both attributes are "_IUP"-prefixed so IUP keeps them LOCAL to this page.
    -- Unregistered attributes are inheritable by default, and a key visible on
    -- every widget inside the page makes the tab tree unreadable -- see the
    -- constants block in core.classes.TabGroups.
    local manifest = self._manifest_by_owner[owner]
    local rec = self:_record(owner)
    local base = (manifest and manifest.id) or "host"
    iup.SetAttribute(tab_widget, "_IUPLUNAR_TABKEY", base .. "/" .. tostring(#rec.tabs + 1))

    -- Optional default group, from addTab opts or the manifest. Only consulted
    -- the first time this tab is seen: once the user has arranged it themselves
    -- the saved layout wins. "Parent/Child" nests. An org pack's extensions
    -- always land inside the pack's tool group ("Acme Tools/<hint>").
    local hint = (opts and opts.group) or (manifest and manifest.group)
    if type(hint) ~= "string" or hint == "" then hint = nil end
    local root_group = self._root_group_by_owner[owner]
    if root_group then hint = hint and (root_group .. "/" .. hint) or root_group end
    if hint then
        iup.SetAttribute(tab_widget, "_IUPLUNAR_GROUPHINT", hint)
    end

    iup.Append(self.tabs, tab_widget)
    if self._shown then
        iup.Map(tab_widget)
        iup.Refresh(self.tabs)
    end
    table.insert(self:_record(owner).tabs, tab_widget)
    if self._shown then self:_applyTabScopes() end
    if self._shown and self._on_tree_change then self._on_tree_change(tab_widget) end
    return widget
end

local function status_padding(value)
    if type(value) == "number" then
        local n = math.max(0, math.floor(value + 0.5))
        return tostring(n) .. "x" .. tostring(n)
    end
    if type(value) == "string" and value ~= "" then
        return value
    end
    return "0x0"
end

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
function HostAPI:addStatusElement(widget, opts, owner)
    if not self._status_box then return end
    if not widget then
        error("addStatusElement requires a widget", 2)
    end
    opts = opts or {}
    if type(opts) ~= "table" then
        error("addStatusElement opts must be a table", 2)
    end

    self._status_seq = self._status_seq + 1
    local position = tonumber(opts.position) or self._status_seq
    local container = self.iup.hbox({
        widget,
        MARGIN = status_padding(opts.padding),
        GAP = L.gap(0),
        ALIGNMENT = "ACENTER",
    })
    local entry = {
        owner = owner or DEFAULT_OWNER,
        widget = widget,
        container = container,
        persistent = opts.persistent == true,
        position = position,
        sequence = self._status_seq,
        present = false,
    }

    if opts.tooltip ~= nil then
        self.iup.SetAttribute(widget, "TIP", tostring(opts.tooltip))
    end
    if opts.on_click ~= nil then
        if type(opts.on_click) ~= "function" then
            error("addStatusElement on_click must be a function", 2)
        end
        local host = self
        self.iup.SetAttribute(widget, "CURSOR", opts.cursor or "HAND")
        function widget:button_cb(button, pressed, x, y)
            if button == host.iup.BUTTON1 and pressed == 0 then
                local ok, err = xpcall(function()
                    opts.on_click(widget, button, pressed, x, y, entry)
                end, debug.traceback)
                if not ok then
                    host:setStatus("Status element callback error: " .. tostring(err))
                end
            end
            return host.iup.DEFAULT
        end
    end

    self._status_scoped[#self._status_scoped + 1] = entry
    table.insert(self:_record(owner).statuswidgets, entry)
    self:_applyStatusScope()
    if self._shown and self._on_tree_change then self._on_tree_change(container) end
    return widget
end

--- Add a tab-scoped status-bar widget.
--
-- Backward-compatible wrapper around `HostAPI:addStatusElement`: extension-owned
-- widgets remain tab-scoped by default.
--
-- @tparam userdata widget the widget to place in the status bar
-- @tparam[opt] table owner owning extension
-- @treturn userdata the supplied `widget`
function HostAPI:addStatusWidget(widget, owner)
    return self:addStatusElement(widget, nil, owner)
end

-- Lazily create the separator that sits directly above File's "Exit" item. It is
-- only added once an extension contributes a File entry, so a plugin-less app shows
-- just "Exit" with no leading separator.
function HostAPI:_ensureFileSeparator()
    if self._file_sep then return self._file_sep end
    local iup = self.iup
    if not (self.file_menu and self._file_exit) then return nil end
    local sep = iup.separator{}
    iup.Insert(self.file_menu, self._file_exit, sep)
    iup.Map(sep)
    self._file_sep = sep
    return sep
end

-- Lazily create the separator that sits directly above Help's "About" item.
function HostAPI:_ensureHelpSeparator()
    if self._help_sep then return self._help_sep end
    local iup = self.iup
    if not (self.help_menu and self._help_about) then return nil end
    local sep = iup.separator{}
    iup.Insert(self.help_menu, self._help_about, sep)
    iup.Map(sep)
    self._help_sep = sep
    return sep
end

-- Destroy the lazy File/Help separators (host-level, shared). Called on reload after
-- all extension-owned items are torn down, so they are rebuilt cleanly on reload.
function HostAPI:_resetMenuSeparators()
    local iup = self.iup
    if self._file_sep then iup.Detach(self._file_sep); iup.Destroy(self._file_sep); self._file_sep = nil end
    if self._help_sep then iup.Detach(self._help_sep); iup.Destroy(self._help_sep); self._help_sep = nil end
end

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
function HostAPI:addMenuItem(title, callback, target, owner)
    local iup = self.iup
    local item = iup.item{ TITLE = title }
    function item:action()
        if callback then callback() end
        return iup.DEFAULT
    end

    if target == "file" and self.file_menu then
        local anchor = self:_ensureFileSeparator() or self._file_exit
        iup.Insert(self.file_menu, anchor, item)
    elseif target == "help" and self.help_menu then
        local anchor = self:_ensureHelpSeparator() or self._help_about
        iup.Insert(self.help_menu, anchor, item)
    else
        iup.Append(self.ext_menu, item)
    end

    iup.Map(item)
    table.insert(self:_record(owner).items, item)

    -- Track the item so it is shown only while the owning extension's tab is active.
    -- (Owners with no tabs are treated as always-visible — see _applyMenuScope.)
    self._tab_scoped[#self._tab_scoped + 1] = {
        owner   = owner or DEFAULT_OWNER,
        item    = item,
        target  = target or "extensions",
        present = true,
    }
    if self._shown then self:_applyMenuScope() end

    return item
end

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
-- @treturn string|nil why not (Linux support arrives with the GTK work)
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
function HostAPI:addVersionInfo(name, version, owner)
    local iup = self.iup
    if not self.help_menu then return end
    local title = tostring(name or "Extension") .. "    v" .. tostring(version or "?")
    local item = iup.item{ TITLE = title, ACTIVE = "NO" }
    -- The version block sits above the first non-version Help item. Capture that
    -- anchor once; every version inserts before it, keeping versions at the top in
    -- insertion order regardless of when other Help items were added.
    if not self._help_version_after then
        local ok, first = pcall(iup.GetNextChild, self.help_menu)
        self._help_version_after = (ok and first) or (self:_ensureHelpSeparator() or self._help_about)
    end
    iup.Insert(self.help_menu, self._help_version_after, item)
    iup.Map(item)
    table.insert(self:_record(owner).items, item)
    return item
end

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
function HostAPI:registerRouteHandler(action, fn, owner)
    if type(action) ~= "string" or action == "" then
        error("registerRouteHandler action is required", 2)
    end
    if type(fn) ~= "function" then
        error("registerRouteHandler fn must be a function", 2)
    end
    owner = owner or DEFAULT_OWNER
    local handlers = self._route_handlers[owner]
    if not handlers then
        handlers = {}
        self._route_handlers[owner] = handlers
    end
    handlers[action] = fn
    return fn
end

--- Register the function that describes this extension's current address.
--
-- The host calls it when the user copies the current `lunar://` address. It must
-- return a route table, e.g. `{ action = "run", params = { preset = "amd" } }`.
--
-- @tparam func fn serializer returning a route table
-- @tparam[opt] table owner owning extension
-- @treturn func the registered serializer
-- @raise when `fn` is not a function
function HostAPI:registerRouteSerializer(fn, owner)
    if type(fn) ~= "function" then
        error("registerRouteSerializer fn must be a function", 2)
    end
    owner = owner or DEFAULT_OWNER
    self._route_serializers[owner] = fn
    return fn
end

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
-- route registrations, and still-pending `onReady` callbacks. The
-- `core.classes.ExtensionManager` calls this on unload and reload, so extensions
-- get precise cleanup without tracking their own resources.
--
-- @tparam table owner the owning extension
-- @treturn boolean `true` once cleanup has run
function HostAPI:removeOwned(owner)
    local iup = self.iup
    local r = self._owners[owner]

    -- Cancel first, before anything is detached or destroyed. An in-flight
    -- animation holds a closure over this owner's widgets and fires up to 60
    -- times a second; letting it survive one more frame means it writes
    -- attributes to handles that were destroyed a few lines below.
    if self._motion then
        pcall(function() self._motion:cancel({ owner = owner }) end)
    end

    -- Dismiss any toasts posted by this owner. Must happen after animation
    -- cancellation (so no in-flight enter/exit fires against the dying extension)
    -- and before widget teardown below.
    if self._toasts then
        pcall(function() self._toasts:dismissOwned(owner) end)
    end

    if r then
        -- Requests still in flight finish on the scheduler, but their callbacks
        -- would run against an unloaded extension.
        for request in pairs(r.requests or {}) do request.cancel() end
        r.requests = {}

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
                    pcall(iup.Destroy, s.container)
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
            if self._settings_view then self._settings_view:removeSection(section) end
        end
        for _, timer in ipairs(r.timers) do
            iup.SetAttribute(timer, "RUN", "NO")
            iup.Destroy(timer)
        end
        for _, theme_id in ipairs(r.themes or {}) do
            if self._theme_mgr then pcall(self._theme_mgr.unregisterTheme, self._theme_mgr, theme_id) end
        end
        for _, item in ipairs(r.items) do
            pcall(iup.Detach, item)   -- may already be detached if its tab was inactive
            iup.Destroy(item)
        end
        -- The Help version-block anchor may have pointed at one of the destroyed
        -- items; recompute it on the next addVersionInfo (e.g. after reload).
        self._help_version_after = nil
        for _, tab in ipairs(r.tabs) do
            local tab_id = iup.GetAttribute(tab, "HOSTTABOWNERID")
            if tab_id then self._owner_by_tab[tab_id] = nil end
            -- Told BEFORE the detach: the group manager decides whether the group
            -- this tab was in should survive losing it, which it can only work out
            -- while the tab is still attached.
            if self._tab_groups then pcall(function() self._tab_groups:forget(tab) end) end
            iup.Detach(tab)
            iup.Destroy(tab)
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

    self:_fixupFileSeparator()
    self:_applyStatusScope()
    if self.tabs then iup.Refresh(self.tabs) end
end

-- =======================================================================
-- TAB-SCOPED MENU ITEMS
-- Extension-contributed File/Help/Extensions items are shown only while one of
-- the owning extension's tabs is the active tab. Win32 menu items can't be hidden
-- via the VISIBLE attribute, so visibility is implemented by detaching/re-inserting.
-- =======================================================================

-- The owner whose tab is currently active, or nil (e.g. the host Settings tab, which
-- is appended directly and carries no owner tag).
function HostAPI:_activeOwner()
    local iup = self.iup
    if not self.tabs then return nil end
    local active = self:_activeTab()
    if active then
        local tab_id = iup.GetAttribute(active, "HOSTTABOWNERID")
        if tab_id then
            return self._owner_by_tab[tab_id]
        end
    end
    -- Fallback for transient states (e.g. during dialog/show ordering).
    local fok, f = pcall(iup.GetFocus)
    if not fok or not f then return nil end
    local tab_id = iup.GetAttribute(f, "HOSTTABOWNERID")
    if not tab_id then return nil end
    return self._owner_by_tab[tab_id]
end

-- The active LEAF page.
--
-- With tab groups a top-level page may be another tab strip rather than an
-- extension's content (see core.classes.TabGroups), so the strip's VALUE is
-- followed down until it lands on a real page. Menu scoping, status-bar scoping,
-- shortcut scoping and route serialization all resolve through here, so getting
-- the descent right in this one place makes every one of them group-aware.
function HostAPI:_activeTab()
    if not self.tabs then return nil end
    if self._tab_groups then
        local leaf = self._tab_groups:activeLeaf()
        if leaf then return leaf end
    end
    local ok, active = pcall(self.iup.GetAttributeHandle, self.tabs, "VALUE")
    if ok and active then return active end
    return nil
end

function HostAPI:_tabIndex(widget)
    if not (self.tabs and widget) then return nil end
    local i = 0
    while true do
        local ok, child = pcall(self.iup.GetChild, self.tabs, i)
        if not ok or not child then return nil end
        if handle.same(self.iup, child, widget) then return i end
        i = i + 1
    end
end

function HostAPI:_activateTabWidget(widget)
    -- A tab may live several groups deep, in which case activating it means
    -- activating each group above it first. TabGroups:reveal walks that chain;
    -- the flat path below still covers the pre-group case and the group manager
    -- being absent (CLI/dev harness).
    if self._tab_groups and self._tab_groups:reveal(widget) then
        self:_applyTabScopes()
        return true
    end
    local index = self:_tabIndex(widget)
    if index == nil then return nil end
    pcall(self.iup.SetAttribute, self.tabs, "VALUEPOS", tostring(index))
    self:_applyTabScopes()
    return true
end

--- Build a route error record.
-- @local
function HostAPI:_routeError(code, message)
    return { code = code, message = message }
end

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
function HostAPI:dispatchRoute(uri)
    local route, parse_err = RouteUri.parse(uri)
    if not route then
        return nil, self:_routeError("invalid_route", parse_err)
    end

    if route.kind == "host" then
        local widget = self._host_tabs[route.target]
        if not widget then
            return nil, self:_routeError("unknown_host_target", "unknown host target: " .. route.target)
        end
        if route.action then
            return nil, self:_routeError("unknown_host_action", "host target does not support action: " .. route.action)
        end
        if not self:_activateTabWidget(widget) then
            return nil, self:_routeError("host_target_unavailable", "host target is not available: " .. route.target)
        end
        return true, route
    end

    local owner = self._owner_by_extension_id[route.target]
    if not owner then
        return nil, self:_routeError("unknown_plugin", "plugin is not loaded: " .. route.target)
    end
    local rec = self._owners[owner]
    if rec and rec.tabs[1] then self:_activateTabWidget(rec.tabs[1]) end

    local action = route.action
    if not action then return true, route end
    local handler = self._route_handlers[owner] and self._route_handlers[owner][action]
    if not handler then
        return nil, self:_routeError("unknown_plugin_action",
            string.format("plugin '%s' does not support action '%s'", route.target, action))
    end
    local ok, result = xpcall(function()
        return handler(route.params, route)
    end, debug.traceback)
    if not ok then
        return nil, self:_routeError("route_handler_error", tostring(result))
    end
    return true, result
end

--- Serialize the currently active tab as a `lunar://` URI.
--
-- For an extension tab the registered route serializer supplies the action and
-- parameters; for a host tab the registered host id is used.
--
-- @treturn string|nil the address, or `nil` when the active tab cannot be addressed
function HostAPI:currentRoute()
    local owner = self:_activeOwner()
    if owner then
        local manifest = self._manifest_by_owner[owner]
        if manifest then
            local action, params
            local serializer = self._route_serializers[owner]
            if serializer then
                local ok, state = pcall(serializer)
                if not ok then
                    self:setStatus("Route serialization error: " .. tostring(state))
                    return nil
                end
                if type(state) == "table" then
                    action, params = state.action, state.params
                end
            end
            return RouteUri.serialize({
                kind = "plugin",
                target = manifest.id,
                action = action,
                params = params,
            })
        end
    end

    local active = self:_activeTab()
    for id, widget in pairs(self._host_tabs) do
        if handle.same(self.iup, widget, active) then
            return RouteUri.serialize({ kind = "host", target = id })
        end
    end
    return nil
end

function HostAPI:_walkTree(ih, fn)
    if not ih then return end
    fn(ih)
    local iup = self.iup
    local i = 0
    while true do
        local ok, child = pcall(iup.GetChild, ih, i)
        if not ok or not child then
            break
        end
        self:_walkTree(child, fn)
        i = i + 1
    end
end

function HostAPI:_tagTreeOwner(ih, tab_id)
    if not ih then return end
    local iup = self.iup
    pcall(iup.SetAttribute, ih, "HOSTTABOWNERID", tab_id)
    local i = 0
    while true do
        local ok, child = pcall(iup.GetChild, ih, i)
        if not ok or not child then
            break
        end
        self:_tagTreeOwner(child, tab_id)
        i = i + 1
    end
end

function HostAPI:_installKeyDispatch(ih)
    if not ih then return end
    pcall(function()
        local host = self
        ih.k_any = function(_, c)
            return host:_dispatchKey(c)
        end
    end)
end

--- Install the dialog-level key dispatcher on a widget subtree.
--
-- Extensions that create their own dialogs can call this so host shortcuts keep
-- working inside them.
--
-- @tparam userdata root the widget (usually a dialog) to install the dispatcher on
function HostAPI:installKeyDispatch(root)
    self:_walkTree(root, function(ih)
        self:_installKeyDispatch(ih)
    end)
end

-- Re-insert a previously-detached scoped item at its correct menu position.
function HostAPI:_insertScopedItem(s)
    local iup = self.iup
    if s.target == "file" and self.file_menu then
        local anchor = self:_ensureFileSeparator() or self._file_exit
        iup.Insert(self.file_menu, anchor, s.item)
    elseif s.target == "help" and self.help_menu then
        local anchor = self:_ensureHelpSeparator() or self._help_about
        iup.Insert(self.help_menu, anchor, s.item)
    else
        iup.Append(self.ext_menu, s.item)
    end
    iup.Map(s.item)
end

-- Show the active owner's contributed menu items; hide everyone else's. Items whose
-- owner contributes no tabs stay visible (they have no tab to scope them to).
function HostAPI:_applyMenuScope()
    local iup = self.iup
    local active_owner = self:_activeOwner()
    for _, s in ipairs(self._tab_scoped) do
        local rec = self._owners[s.owner]
        local owner_has_tabs = rec and #rec.tabs > 0
        local want
        if owner_has_tabs then
            want = (s.owner == active_owner)
        else
            want = true
        end
        if want and not s.present then
            self:_insertScopedItem(s)
            s.present = true
        elseif (not want) and s.present then
            iup.Detach(s.item)
            s.present = false
        end
    end
    self:_fixupFileSeparator()
end

-- Rebuild the visible status area in deterministic position order. IUP lays hbox
-- children out left-to-right, so descending positions put position 1 at the
-- right edge, next to the org logo.
--
-- ### Why the early return matters
--
-- This runs on EVERY tab change, and a tab change very often does not change what
-- the status bar should hold -- switching between two tabs of the same extension
-- never does, and neither do the three re-scopes a single drag fans out (one from
-- TABCHANGE_CB as the drop reveals the tab, one from TabGroups' on_change, one
-- from TabOrder's on_switch).
--
-- Rebuilding is not a cheap no-op. `IupDetach` unmaps, which DESTROYS the element's
-- native window, and the re-map builds a new one, followed by a full-dialog
-- `IupRefresh`: done on every switch, that flickers the status bar behind every
-- tab transition.
--
-- So the target arrangement is computed first and compared with what is already
-- on screen. Identical is the common case and costs nothing.
function HostAPI:_applyStatusScope()
    if not self._status_box then return end
    local iup = self.iup
    local active_owner = self:_activeOwner()

    local visible = {}
    for _, s in ipairs(self._status_scoped) do
        if s.persistent or s.owner == active_owner then
            visible[#visible + 1] = s
        end
    end
    table.sort(visible, function(a, b)
        if a.position ~= b.position then
            return a.position > b.position
        end
        return a.sequence > b.sequence
    end)

    -- Self-invalidating by construction: a registration added or removed changes
    -- this list, so there is no separate epoch to keep in step with it.
    local shown = self._status_visible
    if shown and #shown == #visible then
        local same = true
        for i = 1, #visible do
            if shown[i] ~= visible[i] then
                same = false
                break
            end
        end
        if same then return end
    end

    local wanted = {}
    for _, s in ipairs(visible) do wanted[s] = true end

    for _, s in ipairs(self._status_scoped) do
        if s.present and not wanted[s] then
            pcall(iup.Detach, s.container)
            s.present = false
        end
    end

    -- Appending each in turn leaves them in exactly this order. Elements already
    -- in the bar are reordered by `core.lib.tree` without being unmapped, so the
    -- ones whose visibility did not change keep the windows they already had --
    -- only the elements genuinely arriving or leaving cost anything.
    for _, s in ipairs(visible) do
        local kept = tree.place(iup, self._status_box, s.container, nil)
        if self._shown and not kept then pcall(iup.Map, s.container) end
        s.present = true
    end

    self._status_visible = visible
    pcall(iup.Refresh, self._status_box)
end

-- Re-scope every tab-owned contribution (menu items AND status-bar widgets) to the
-- currently active tab. This is the single entry point to call on any tab switch:
-- menu and status scoping must always move together, and splitting them is exactly
-- how the status indicator got stranded on other tabs when TabOrder's programmatic
-- switch bypassed TABCHANGE_CB (which fires only on native, non-reordered clicks).
function HostAPI:_applyTabScopes()
    self:_applyMenuScope()
    self:_applyStatusScope()
end

--- Describe the currently active tab as a route table.
-- @treturn table|nil `{ kind = "host"|"plugin", target = <id>, params = {...} }`,
--   or `nil` when the active tab cannot be addressed
function HostAPI:currentAddress()
    local active = self:_activeTab()
    for id, widget in pairs(self._host_tabs) do
        if handle.same(self.iup, widget, active) then
            return { kind = "host", target = id, params = {} }
        end
    end

    local owner = self:_activeOwner()
    if owner then
        local serializer = self._route_serializers[owner]
        if serializer then
            local ok, route = pcall(serializer)
            if ok and type(route) == "table" then
                return route
            end
        end
        local manifest = self._manifest_by_owner[owner]
        if manifest and manifest.id then
            return { kind = "plugin", target = manifest.id, params = {} }
        end
    end
    return nil
end

--- Serialized form of `HostAPI:currentAddress`.
-- @treturn string|nil a `lunar://` URI, or `nil` when the active tab cannot be addressed
function HostAPI:currentAddressURI()
    local route = self:currentAddress()
    if not route then
        return nil
    end
    local uri = RouteUri.serialize(route)
    return uri
end

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
function HostAPI:dispatchAddress(uri_or_route)
    local route = uri_or_route
    if type(uri_or_route) == "string" then
        local parsed, err = RouteUri.parse(uri_or_route)
        if not parsed then
            return nil, self:_routeError("malformed_route", "Malformed Lunar address: " .. tostring(err))
        end
        route = parsed
    end
    if type(route) ~= "table" then
        return nil, self:_routeError("malformed_route", "Route dispatch requires a parsed route table or lunar:// URI")
    end

    if route.kind == "host" then
        local widget = self._host_tabs[route.target]
        if not widget then
            return nil, self:_routeError("unknown_route", "Unknown host route target: " .. tostring(route.target))
        end
        if not self:_activateTabWidget(widget) then
            return nil, self:_routeError("route_unavailable", "Host route target is not available: " .. tostring(route.target))
        end
        return true, route
    end

    if route.kind ~= "plugin" then
        return nil, self:_routeError("malformed_route", "Unknown route kind: " .. tostring(route.kind))
    end

    local owner = self._owner_by_extension_id[route.target]
    if not owner then
        return nil, self:_routeError("unknown_route", "Unknown plugin route target: " .. tostring(route.target))
    end

    local rec = self._owners[owner]
    if rec and rec.tabs and rec.tabs[1] then
        self:_activateTabWidget(rec.tabs[1])
    end

    if route.action and route.action ~= "" then
        local handlers = self._route_handlers[owner]
        local handler = handlers and handlers[route.action]
        if not handler then
            return nil, self:_routeError(
                "unknown_route",
                string.format("Plugin '%s' does not provide route '%s'", tostring(route.target), tostring(route.action))
            )
        end
        local ok, result = pcall(handler, route.params or {}, route)
        if not ok then
            return nil, self:_routeError("dispatch_failed", "Route dispatch failed: " .. tostring(result))
        end
        return true, result
    end

    return true, route
end

-- Keep the File menu's leading separator only while at least one File item is shown,
-- so an inactive tab leaves the File menu as just "Exit" (no dangling separator).
function HostAPI:_fixupFileSeparator()
    local iup = self.iup
    local any = false
    for _, s in ipairs(self._tab_scoped) do
        if s.target == "file" and s.present then any = true; break end
    end
    if any then
        self:_ensureFileSeparator()
    elseif self._file_sep then
        iup.Detach(self._file_sep)
        iup.Destroy(self._file_sep)
        self._file_sep = nil
    end
end

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

--- Route a key code to registered shortcut handlers that are currently in scope.
--
-- An owner that contributes tabs gets its shortcuts only while one of its tabs is
-- active; an owner with no tabs is always in scope. This mirrors the tab-scoping of
-- menu items, so an extension's shortcuts work only on its own tabs and fall
-- through to normal editing elsewhere.
--
-- @local
function HostAPI:_dispatchKey(c)
    local iup  = self.iup
    local list = self._shortcuts[c]
    if not list then return iup.CONTINUE end
    local active_owner = self:_activeOwner()
    local consumed = false
    for i = 1, #list do
        local e = list[i]
        local rec = self._owners[e.owner]
        local owner_has_tabs = rec and #rec.tabs > 0
        local in_scope = (not owner_has_tabs) or (e.owner == active_owner)
        if in_scope then
            pcall(e.fn)
            consumed = true
        end
    end
    return consumed and iup.IGNORE or iup.CONTINUE
end

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
function HostAPI:registerShortcut(key, fn, owner)
    if not key or not fn then return end
    local list = self._shortcuts[key]
    if not list then list = {}; self._shortcuts[key] = list end
    local entry = { key = key, fn = fn, owner = owner or DEFAULT_OWNER }
    list[#list + 1] = entry
    table.insert(self:_record(owner).shortcuts, entry)
    return entry
end

return HostAPI
