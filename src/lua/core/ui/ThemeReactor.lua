--- Shared theme-reactivity registry for paint-time widgets.
-- A single `ThemeManager` `onApply` subscription repaints every registered
-- widget instance on a theme switch, and exposes the active theme palette for
-- paint-time color resolution.
--
-- Extracted from the retired canvas-based GradientKit. Currently used by
-- `core.ui.VectorIcon` to recolor role-bound SVG icons on each theme switch.
--
-- **Instance contract**: a registered object `inst` may define
-- `inst:_onThemeApply()`, which is called once per theme switch after the active
-- palette has been refreshed.  Read `M.palette()` inside it.  The registry is
-- **weak-keyed**: destroyed or garbage-collected instances drop out automatically
-- with no explicit deregistration needed.
--
-- **Binding** is idempotent: `M.bindThemeManager(tm)` installs exactly one
-- `onApply` hook even when called from several modules or multiple times with the
-- same manager.
--
-- @module core.ui.ThemeReactor

local M = {}

-- The palette from the last applied theme (a plain table of "R G B" tokens). Read this
-- at paint time; never cache it across a theme switch.
local active_palette = {}
local instances = setmetatable({}, { __mode = "k" })
local theme_mgr
local bound = false

--- Return the palette from the last applied theme.
-- A plain table of `"R G B"` string tokens, keyed by palette key name.
-- Read this at paint time; never cache it across a theme switch.
-- @treturn table Active palette table (empty before the first theme is applied).
function M.palette()
    return active_palette
end

--- Read a color token from a palette with a fallback (parity with the retired GradientKit).
-- @tparam[opt] table pal Palette table; defaults to the active palette when `nil`.
-- @tparam string key Palette key name.
-- @param fallback Value returned when the key is absent or empty.
-- @return The palette value, or `fallback`.
function M.pal_get(pal, key, fallback)
    pal = pal or active_palette
    local v = pal and pal[key]
    if v == nil or v == "" then return fallback end
    return v
end

--- Return the currently bound `ThemeManager` instance.
-- @treturn table|nil The `ThemeManager`, or `nil` if none has been bound.
function M.themeManager()
    return theme_mgr
end

--- Register a live widget instance in the weak-keyed registry.
-- The instance's `_onThemeApply()` method (if defined) will be called on each
-- future theme switch.  Destroyed instances drop out of the registry automatically.
-- @param inst Object to register.  `nil` is accepted and silently ignored.
-- @return `inst` (pass-through for convenience).
function M.register(inst)
    if inst ~= nil then instances[inst] = true end
    return inst
end

local function repaint_all()
    for inst in pairs(instances) do
        if inst._onThemeApply then
            pcall(function() inst:_onThemeApply() end)
        end
    end
end

--- Install the single `onApply` hook on `tm` (idempotent).
-- Captures the active palette and repaints every registered instance on each
-- theme switch.  Safe to call from multiple modules or multiple times.
-- @tparam table tm `ThemeManager` instance.
function M.bindThemeManager(tm)
    if bound and theme_mgr == tm then return end
    theme_mgr = tm
    if tm and tm.onApply then
        tm:onApply(function(theme)
            active_palette = (theme and theme.palette and theme:palette()) or {}
            repaint_all()
        end)
        bound = true
    end
end

return M
