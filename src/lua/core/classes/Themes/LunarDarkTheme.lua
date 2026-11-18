--- Lunar: graphite, pearl and silver glass. Hue is reserved for state.
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local rgb   = lunar.rgb

local LunarDarkTheme = Theme:subclass("LunarDarkTheme")

function LunarDarkTheme:initialize()
    local p = {
        bg              = rgb("#0B0D10"),
        layer01         = rgb("#14171B"),
        layer02         = rgb("#1B1F24"),
        layer03         = rgb("#252A31"),
        layerHover01    = rgb("#2A2F37"),
        layerSelected01 = rgb("#353C46"),
        borderSubtle01  = rgb("#2B3038"),
        borderStrong01  = rgb("#454C57"),
        fieldBorder     = rgb("#7A828D"),
        text            = rgb("#F2F4F7"),
        textMuted       = rgb("#AEB5BF"),
        textFaint       = rgb("#7C848F"),
        accent          = rgb("#E6EAF0"),
        accentText      = rgb("#13171C"),
        accentHover     = rgb("#FFFFFF"),
        accentPressed   = rgb("#C9D0DA"),
        accentBright    = rgb("#FFFFFF"),
        accentSoft      = rgb("#2E343D"),
        success         = rgb("#7FD49B"),
        warning         = rgb("#F0C86E"),
        error           = rgb("#FF98A3"),
        info            = rgb("#8EC5F5"),
        well            = rgb("#101317"),
        font = "Segoe UI, 10",
        glass = true,
        glassDark = true,
        glassBloom = 0.07, glassBloomWidth = 0.60, glassBloomHeight = 1.4,
        glassChromeAlpha = 0.78, glassFloatingAlpha = 0.88,
        glassTopRim = "255 255 255 36", glassRim = "255 255 255 15",
        radius = 6, radiusFrame = 8,
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
