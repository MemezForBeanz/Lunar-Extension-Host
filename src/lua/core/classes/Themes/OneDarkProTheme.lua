--- One Dark Pro theme — Fluent 2 graphics language with One Dark Pro colors.
--
-- The color palette is the well-known "One Dark Pro" scheme; structural styling
-- (default/primary button split, neutral borders, accent-tinted selection, layered
-- elevation) comes from the shared `fluent_rules` builder. The typeface is
-- Segoe UI Variable — the Fluent 2 system font (installed with Windows 11).
--
-- **UI gradients:** this theme opts in via the palette's `gradEnabled` /
-- `gradTop` / `gradBottom` tokens, which the forked IUP renders natively through
-- `GRADIENTCOLOR` / `GRADIENTDIRECTION` on the flat controls (see
-- `iup-fork/README.md`). The gradient is a signature blue → purple sweep.
--
-- @classmod core.classes.Themes.OneDarkProTheme
local Theme  = require("core.classes.Themes.Theme")
local fluent = require("core.classes.Themes.fluent_rules")
local rgb    = fluent.rgb

local OneDarkProTheme = Theme:subclass("OneDarkProTheme")

function OneDarkProTheme:initialize()
    local p = {
        bg           = rgb("#282c34"),  -- One Dark Pro editor background
        surface      = rgb("#2c313a"),  -- panels / lists (slightly raised)
        surface2     = rgb("#3a3f4b"),  -- hover / selection layer
        text         = rgb("#abb2bf"),  -- primary foreground
        textMuted    = rgb("#7f848e"),  -- secondary foreground
        accent       = rgb("#61afef"),  -- One Dark Pro blue (interactive)
        accentHover  = rgb("#4d9fe0"),  -- deeper blue for hover/pressed
        accentText   = rgb("#1e2227"),  -- near-black text on the light-blue accent
        border       = rgb("#3e4451"),  -- subtle border
        borderStrong = rgb("#5c6370"),  -- stronger border / default button outline
        error        = rgb("#e06c75"),  -- One Dark Pro red
        success      = rgb("#98c379"),  -- One Dark Pro green
        warning      = rgb("#e5c07b"),  -- One Dark Pro yellow
        warningText  = rgb("#282c34"),  -- dark text on the yellow warning fill
        info         = rgb("#56b6c2"),  -- One Dark Pro cyan
        font         = "Segoe UI Variable, 10",

        -- Gradient tokens (paint-time overlay only; see GradientCanvas).
        gradEnabled  = true,
        gradTop      = rgb("#61afef"),  -- blue
        gradBottom   = rgb("#c678dd"),  -- purple

        -- Rounded-corner radius (px) for canvas-drawn controls (GradientButton).
        -- Carbon-based themes leave this unset so they stay intentionally sharp;
        -- the Fluent 2 / One Dark Pro look uses softly rounded corners.
        radius       = 6,
    }
    p.listBg      = p.surface
    p.listText    = p.text
    p.listSelText = p.accent

    Theme.initialize(self, {
        id      = "one_dark_pro",
        label   = "One Dark Pro",
        palette = p,
    })
end

function OneDarkProTheme:rules()
    return fluent.build(self:palette())
end

return OneDarkProTheme
