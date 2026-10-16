--- Active-theme palette registry.
--
-- `ThemeManager` publishes the active palette here (or `nil` for the Classic /
-- no-override theme); the host's reusable widgets (`CheckList`,
-- `ReorderableList`) read semantic colors from it so the rows they create and
-- repaint dynamically are themed without any per-extension code.
--
-- Palette keys (all `"R G B"` strings): `bg`, `surface`, `text`, `textMuted`,
-- `accent`, `error`, and the list-oriented aliases `listBg`, `listText`,
-- `listSelText`.
--
-- @module core.classes.Theme
local M = { _active = nil }

--- Publish the active palette or `nil` to revert to Classic (no override).
-- Called by `ThemeManager` after every theme switch. Widgets that call
-- `M.color()` will immediately read the new palette on their next repaint.
-- @tparam table|nil palette Table of `"R G B"` color strings, or `nil` for Classic.
-- @usage Theme.set(myTheme:palette())
function M.set(palette)
    M._active = palette
end

--- Return the currently active palette, or `nil` when Classic is active.
-- @treturn table|nil The active palette table, or `nil`.
-- @usage local p = Theme.get(); if p then print(p.bg) end
function M.get()
    return M._active
end

--- Return the active palette's color for `key`, or `fallback` when no theme is
-- active (Classic) or the key is unset.
-- Fallback values are the widgets' original literals, so Classic renders exactly
-- as it did before any theme was applied.
-- @tparam string key Palette color key (e.g. `"bg"`, `"accent"`, `"listSelText"`).
-- @param fallback Value to return when no palette is active or the key is absent.
-- @treturn string The `"R G B"` color string, or `fallback`.
-- @usage local color = Theme.color("accent", "0 95 254")
function M.color(key, fallback)
    local p = M._active
    if p and p[key] then return p[key] end
    return fallback
end

return M
