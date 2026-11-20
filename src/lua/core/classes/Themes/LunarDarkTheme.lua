-- Lunar: graphite, pearl and silver glass. Hue is reserved for state.
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local rgb   = lunar.rgb

local LunarDarkTheme = Theme:subclass("LunarDarkTheme")

function LunarDarkTheme:initialize()
    local p = {
        bg              = rgb("#080A0F"),
        layer01         = rgb("#151B24"),
        layer02         = rgb("#171B21"),
        layer03         = rgb("#1E2630"),
        layerHover01    = rgb("#242C37"),
        layerSelected01 = rgb("#343C48"),
        borderSubtle01  = rgb("#2B3038"),
        borderStrong01  = rgb("#454C57"),
        fieldBorder     = rgb("#97A3B2"),
        text            = rgb("#F2F4F7"),
        textMuted       = rgb("#B7C1CE"),
        textFaint       = rgb("#7C848F"),
        accent          = rgb("#ECEFF4"),
        accentText      = rgb("#151A20"),
        accentHover     = rgb("#FFFFFF"),
        accentPressed   = rgb("#AAB8C8"),
        accentBright    = rgb("#FFFFFF"),
        accentSoft      = rgb("#343C48"),
        success         = rgb("#7FD49B"),
        warning         = rgb("#F0C86E"),
        error           = rgb("#FF98A3"),
        info            = rgb("#8EC5F5"),
        well            = rgb("#101419"),
        font = "Segoe UI, 10",
        glass = true,
        glassDark = true,
        -- Liquid Glass (core.ui.Glass): the baked crescent-and-stars backdrop, chrome and
        -- floating tints over its softened copy, and the curved rim.
        glassBackdrop = "lunar-dark",
        glassChromeTint = rgb("#151B24"), glassChromeAlpha = 0.58,
        glassFloatingTint = rgb("#1E2630"), glassFloatingAlpha = 0.76,
        glassTextWell = rgb("#242C36"),
        glassRimHi = "255 255 255 122", glassRimLo = "255 255 255 26", glassRimInner = "0 0 0 64",
        -- The worst pixel of the softened backdrop (see gen_glass_assets.py), for the audit.
        glassSampleWorst = "85 93 104",
        glassShadowAlpha = 0.32, glassReveal = 8,
        -- Primary action: an opaque pearl gradient.
        primaryTop = rgb("#FCFDFF"), primaryBottom = rgb("#C1CBD7"), primaryText = rgb("#151A20"),
        primaryHover = rgb("#FFFFFF"), primaryPressed = rgb("#AAB8C8"),
        radius = 8, radiusFrame = 8, radiusSheet = 14, radiusFloating = 16,
    }
    p.warningText = p.accentText
    p.gradTop, p.gradBottom = p.layer01, p.layer01
    -- Legacy aliases, so widgets reading the six-key palette keep working.
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.text

    Theme.initialize(self, {
        id      = "lunar_dark",
        family  = "lunar",
        family_label = "Lunar",
        label   = "Lunar Dark",
        palette = p,
        dark    = true,
    })
end

function LunarDarkTheme:rules()
    return lunar.build(self:palette())
end

return LunarDarkTheme
