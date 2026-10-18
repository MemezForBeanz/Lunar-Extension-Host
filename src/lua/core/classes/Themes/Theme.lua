--- Base class for all Lunar theme implementations.
--
-- **Theme contract:** every concrete theme subclass must:
--
--  1. Call `Theme.initialize(self, spec)` with `spec.id`, `spec.label`, and
--     `spec.palette` (a table of `"R G B"` color strings).
--  2. Override `rules()` to return a table mapping IUP widget class names (and
--     optional role names) to style tables. The `ThemeManager` consumes these to
--     apply per-widget attribute sets during a theme switch.
--
-- **Discovery:** `ThemeManager` auto-discovers all subclasses at startup by
-- scanning `package.preload` for modules matching `"^core%.classes%.Themes%."`.
-- Dropping a new `.lua` file under `src/lua/core/classes/Themes/` is sufficient —
-- no change to `ThemeManager` is required.
--
-- **Palette keys** consumed by reusable widgets (all `"R G B"` strings):
-- `bg`, `surface`, `surface2`, `text`, `textMuted`, `accent`, `accentText`,
-- `border`, `borderStrong`, `error`, `success`, `warning`, `warningText`,
-- `info`, `font`, `listBg`, `listText`, `listSelText`.
-- Gradient-capable themes also provide `gradEnabled`, `gradTop`, `gradBottom`,
-- and `radius`.
--
-- @classmod core.classes.Themes.Theme

local class = require("middleclass")

local Theme = class("Theme")

--- Initialize a theme with a spec table.
-- @tparam table spec Must contain `id` (string), `label` (string), and
--   optionally `palette` (table of `"R G B"` strings).
-- @usage Theme.initialize(self, { id = "my_theme", label = "My Theme", palette = p })
function Theme:initialize(spec)
    self._id      = spec.id
    self._label   = spec.label
    self._palette = spec.palette or {}
    self._dark    = spec.dark   -- optional; see isDark
end

--- Return the theme's stable identifier string (e.g. `"classic_dark"`).
-- Used as the settings key and `ThemeManager` lookup key.
-- @treturn string The theme id.
function Theme:id()
    return self._id
end

--- Return the human-readable theme label shown in the Theme menu and dropdown.
-- @treturn string The display label (e.g. `"Classic Dark"`).
function Theme:label()
    return self._label
end

--- Return the theme's color palette table.
-- Keys are semantic color names; values are `"R G B"` strings.
-- @treturn table The palette table.
function Theme:palette()
    return self._palette
end

--- Is this a dark theme? Used by "Match system theme" to pick between the
-- user's light and dark themes. A theme may say so in its spec (`dark = true`);
-- otherwise it is decided from the palette's background (`bg`) brightness, so
-- extension themes need do nothing.
-- @treturn boolean
function Theme:isDark()
    if self._dark ~= nil then return self._dark == true end
    local bg = self._palette.bg or self._palette.background
    local r, g, b = tostring(bg or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    if not r then return false end
    return (0.2126 * tonumber(r) + 0.7152 * tonumber(g) + 0.0722 * tonumber(b)) < 128
end

--- Return `true` if this theme is the Classic (no-override) theme.
-- `ThemeManager` uses this to decide whether to clear the native global theme and
-- restore original widget attributes rather than applying new ones.
-- @treturn bool Always `false` in the base class; override in Classic subclass.
function Theme:isClassic()
    return false
end

--- Return a table of widget class → style table (e.g. `button` → `{fg="...", ...}`).
-- Override in subclasses. The base implementation returns an empty table.
-- `ThemeManager` calls `theme:rules()` once per theme switch and applies the
-- resulting attribute sets to matching widgets in the live tree.
-- @treturn table Widget class/role → style mapping (empty in the base class).
function Theme:rules()
    return {}
end

--- Return per-role motion overrides for this theme.
--
-- Colour is only half of a design language; movement is the other half, and a
-- theme that changes one without the other is only half a theme. This is the
-- motion equivalent of `rules()`: where `rules()` maps widget classes to
-- attributes, this maps **motion roles** -- named moments like `tab_transition`
-- or `settings_expand` -- to durations, curves and styles.
--
-- The base implementation returns an empty table, which means every role keeps
-- the Carbon-correct default from `core.lib.MotionTokens.ROLES`. That is the
-- right answer for most themes: Carbon's motion is already tuned, and a theme
-- should override a role only when its identity genuinely calls for different
-- movement.
--
-- Overrides are merged per role and per field, so a theme states only what it
-- changes:
--
--     function MyTheme:motion()
--         return {
--             -- Everything else stays Carbon default.
--             tab_transition = { style = "expressive", travel = 0.2 },
--         }
--     end
--
-- Recognised fields are `duration` (ms), `curve` (`"standard"`, `"entrance"`,
-- `"exit"`, or raw `{x1,y1,x2,y2}` bezier points), `style` (`"productive"` or
-- `"expressive"`) and `delay` (ms), plus any role-specific extras documented on
-- `MotionTokens.ROLES`.
--
-- `ThemeManager` hands the result to `core.classes.MotionDirector` on every
-- apply, so switching themes changes how the app moves as well as how it looks.
--
-- @treturn table Role name → motion spec (empty in the base class).
function Theme:motion()
    return {}
end

return Theme
