--- Base class for application extensions (plugins).
--
-- Extensions may inherit from this class or use a plain table with the same API.
--
-- **Lifecycle:**
--
--  1. `ExtensionManager` injects `self._ctx` (the `HostAPI`) and `self._iup` before `register()`.
--  2. `register(ctx)` — called once; set up tabs, menus, hooks.
--  3. `shutdown()` — called on unload/reload; clean up resources.
--
-- **Convenience methods** (delegate to the `HostAPI` in `self._ctx`, recording this
-- extension as the owner so everything is torn down precisely on unload/reload):
--
--   * `self:addTab(title, widget[, opts])` — append a tab to the main tab strip
--   * `self:addMenuItem(title, callback[, target])` — add item to File/Help/Extensions
--   * `self:addTimer({time, action, run})` — create an owned timer (auto-destroyed)
--   * `self:addStatusElement(widget[, opts])` — add an owned status-bar element
--   * `self:onReady(fn)` — run `fn` after the window is shown
--   * `self:log(msg)` — post a message to the status bar
--
-- `self.dir` is the extension's own folder (set before `register` runs), for
-- files it ships with it; an org pack's extensions live outside the app folder.
--
-- `ctx` is a `HostAPI` instance. See `core.classes.HostAPI` for the full surface:
-- `ctx.iup`, `ctx.app{title,version,dir}`, `ctx.settings`, `ctx.subprocess`,
-- `ctx.tabs`, `ctx.ext_menu`, plus the methods above.
--
-- Reusable UI building blocks are available as `ctx.ui`:
--
--   * `ctx.ui.ContextMenu` — declarative right-click popup menus
--   * `ctx.ui.ReorderableList` — multi-select list with drag-to-reorder
--   * `ctx.ui.CheckList` — scrollable checkbox + selectable-label browser
--   * `ctx.ui.SettingsView` — register sections via `ctx:addSettings`
--
-- @classmod core.classes.Extension

local class = require("middleclass")

local Extension = class("Extension")

--- Create a new Extension with the given name and version.
-- Both fields are used for display (Help menu version info, status bar prefix).
-- @tparam[opt="Unnamed Extension"] string name Human-readable extension name.
-- @tparam[opt="0.0"] string version Semantic version string.
-- @usage
--   local MyExt = Extension:subclass("MyExtension")
--   function MyExt:initialize()
--     Extension.initialize(self, "My Extension", "1.0")
--   end
function Extension:initialize(name, version)
    self.name    = name    or "Unnamed Extension"
    self.version = version or "0.0"
end

--- Called when the extension is loaded. `ctx` (a `HostAPI`) provides access to the host.
-- Override in subclasses. The host calls this once after injecting `self._ctx` and
-- `self._iup`. Use the convenience methods (`addTab`, `addMenuItem`, etc.) to register
-- UI; they record ownership so everything is torn down automatically on unload.
-- @tparam HostAPI ctx The host API context.
-- @usage
--   function MyExt:register(ctx)
--     self:addTab("My Tab", iup.vbox{})
--   end
function Extension:register(ctx)
    -- default: no-op
end

--- Called when the extension is being unloaded (e.g. on reload).
-- Override in subclasses to clean up resources. Tabs, menu items, and timers
-- added through the convenience methods are removed automatically by the host;
-- only custom teardown (closing handles, cancelling network calls, etc.) belongs here.
-- @usage
--   function MyExt:shutdown()
--     if self._timer then self._timer = nil end
--   end
function Extension:shutdown()
    -- default: no-op
end

 -- Convenience methods (delegate to the HostAPI, with this extension as owner) --

--- Add a tab to the main tab strip. Returns the widget handle.
-- `opts` is forwarded to `HostAPI:addTab` (e.g. side-padding and max-width centering).
-- @tparam string title Tab title shown in the tab strip.
-- @tparam ihandle widget The IUP widget to display in the tab body.
-- @tparam[opt] table opts Optional layout options passed to `HostAPI:addTab`.
-- @treturn ihandle The widget handle (same as `widget`).
-- @usage self:addTab("Results", iup.vbox{ myList })
function Extension:addTab(title, widget, opts)
    local host = self._ctx
    if not host then return end
    return host:addTab(title, widget, self, opts)
end

--- Add an item to a top-level menu. Returns the menu item handle.
-- `target` selects the menu: `"file"`, `"help"`, or `"extensions"` (default).
-- @tparam string title Menu item title shown to the user.
-- @tparam function callback Called when the item is activated.
-- @tparam[opt="extensions"] string target Which top-level menu to append to.
-- @treturn ihandle The IUP menu item handle.
-- @usage self:addMenuItem("Export…", function() export() end, "file")
function Extension:addMenuItem(title, callback, target)
    local host = self._ctx
    if not host then return end
    return host:addMenuItem(title, callback, target, self)
end

--- Create a timer owned by this extension (auto-destroyed on unload).
-- Returns the IUP timer handle so the caller can start/stop it via `RUN`.
-- `opts` is a table with `{ time = <ms>, action = <fn>, run = <bool> }`.
-- @tparam table opts Timer options: `time` (interval in ms), `action` (callback), `run`.
-- @treturn ihandle The IUP timer handle.
-- @usage
--   self._poll = self:addTimer({ time = 2000, run = true,
--     action = function() self:poll() end })
function Extension:addTimer(opts)
    local host = self._ctx
    if not host then return end
    return host:addTimer(opts, self)
end

--- Run a function once the main window is shown and all widgets are mapped.
-- @tparam function fn Zero-argument callback to invoke when the window is ready.
-- @usage self:onReady(function() self:loadData() end)
function Extension:onReady(fn)
    local host = self._ctx
    if not host then return end
    return host:onReady(fn, self)
end

--- Animate a value over time, following the Carbon motion system.
--
-- See `HostAPI:animate` for the full `spec` field list, and `docs/motion.md` for
-- the duration tokens and easing curves to pick from.
--
-- Prefer this over `ctx:animate` for the same reason as every other wrapper here:
-- it files the animation under this extension, so unloading or reloading cancels
-- anything still in flight. Without an owner, a 60 Hz frame callback outlives the
-- widgets it writes to and keeps poking handles the host has already destroyed.
--
-- When motion is disabled, `on_frame` is called once with the final value and
-- `on_done(true)` follows, both synchronously -- so this is always safe as the only
-- way a property reaches its destination.
--
-- @tparam table spec Animation specification (see `HostAPI:animate`).
-- @treturn table|nil Handle with `cancel()`, `finish()` and `done()`.
-- @usage
--   self:animate({
--     distance = 200, curve = "entrance", from = 0, to = 200,
--     on_frame = function(v) iup.SetAttribute(panel, "RASTERSIZE", "x" .. math.floor(v)) end,
--   })
function Extension:animate(spec)
    local host = self._ctx
    if not host then return end
    return host:animate(spec, self)
end

--- Return the shared animation scheduler (`core.classes.MotionDirector`).
-- Use `Extension:animate` for ordinary animation; this is for the cases that need
-- the director itself, such as checking `enabled()` before doing expensive work
-- whose only purpose is animation.
-- @treturn MotionDirector|nil The shared director.
-- @usage if self:motion() and self:motion():enabled() then ... end
function Extension:motion()
    local host = self._ctx
    if not host then return end
    return host:motion()
end

--- Register a settings section in the centralized Settings view.
-- See `HostAPI:addSettings` for the full option set (title, fields, callbacks).
-- @tparam string category Display category for this settings section.
-- @tparam table opts Section definition passed to `HostAPI:addSettings`.
-- @usage self:addSettings("Hello", { fields = {...} })
function Extension:addSettings(category, opts)
    local host = self._ctx
    if not host then return end
    return host:addSettings(category, opts, self)
end

--- Register a dialog-level keyboard shortcut owned by this extension.
-- `key` is an IUP key code (e.g. `iup.K_cA`); `fn` should return a truthy value
-- to consume the key event. The shortcut is automatically removed on unload.
-- See `HostAPI:registerShortcut`.
-- @tparam string key IUP key code string (e.g. `"K_cA"`).
-- @tparam function fn Handler; return truthy to consume the key.
-- @usage self:addShortcut(iup.K_cR, function() self:refresh() return true end)
function Extension:addShortcut(key, fn)
    local host = self._ctx
    if not host then return end
    return host:registerShortcut(key, fn, self)
end

--- Add a widget to the status bar.
-- Elements are tab-scoped unless `opts.persistent` is `true`.
-- See `HostAPI:addStatusElement` for ordering, padding, tooltip, and click callback options.
-- @tparam ihandle widget The IUP widget to place in the status bar.
-- @tparam[opt] table opts Options: `persistent`, `order`, `padding`, `tooltip`, `onclick`.
-- @treturn ihandle The widget handle.
-- @usage self:addStatusElement(myLabel, { persistent = true })
function Extension:addStatusElement(widget, opts)
    local host = self._ctx
    if not host then return end
    return host:addStatusElement(widget, opts, self)
end

--- Backward-compatible tab-scoped status-widget helper.
-- Equivalent to `addStatusElement(widget)` with no extra options.
-- @tparam ihandle widget The IUP widget to place in the status bar.
function Extension:addStatusWidget(widget)
    return self:addStatusElement(widget)
end

--- Register a route handler for a Lunar routing action.
-- Delegates to `HostAPI:registerRouteHandler`. See the routing guide for action format.
-- @tparam string action The action name (e.g. `"open_build"`).
-- @tparam function fn Handler function called with the route payload.
function Extension:addRoute(action, fn)
    if not self._ctx then return end
    return self._ctx:registerRouteHandler(action, fn, self)
end

--- Register a route serializer for this extension.
-- Delegates to `HostAPI:registerRouteSerializer`.
-- @tparam function fn Serializer function that produces a route payload.
function Extension:setRouteSerializer(fn)
    if not self._ctx then return end
    return self._ctx:registerRouteSerializer(fn, self)
end

--- Post a Carbon toast notification owned by this extension.
--
-- The toast is dismissed automatically when this extension is unloaded,
-- exactly like animations scheduled through `Extension:animate`.
--
-- See `HostAPI:notify` for the full `spec` field list.
--
-- @tparam table spec `{ title, body, kind, timeout }` (see `HostAPI:notify`)
-- @usage self:notify({ title = "Scan complete", kind = "success" })
function Extension:notify(spec)
    local host = self._ctx
    if not host then return end
    return host:notify(spec, self)
end

--- Post a message to the host status bar, prefixed with the extension name.
-- @tparam string msg The message to display.
-- @usage self:log("Build complete.")
function Extension:log(msg)
    if self._ctx then
        self._ctx:setStatus(self.name .. ": " .. msg)
    end
end

--- Return a namespaced application logger (console + rotated log file).
-- Defaults the namespace to this extension's name. Distinct from `log()` above,
-- which posts to the status bar. Delegates to the host; falls back to
-- `core.lib.log` directly for context-less or plain-table extensions.
-- @tparam[opt] string name Logger namespace; defaults to `self.name`.
-- @treturn table Logger object with `info`, `warn`, `error` methods.
-- @usage local log = self:getLogger(); log:info("initialized")
function Extension:getLogger(name)
    if self._ctx and self._ctx.getLogger then
        return self._ctx:getLogger(name or self.name)
    end
    return require("core.lib.log").get(name or self.name)
end

return Extension
