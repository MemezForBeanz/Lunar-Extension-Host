-- Lunar: graphite, pearl and silver glass. Hue is reserved for state.
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local rgb   = lunar.rgb

local LunarLightTheme = Theme:subclass("LunarLightTheme")

function LunarLightTheme:initialize()
    local p = {
        bg              = rgb("#E6E9ED"),
        layer01         = rgb("#F1F3F5"),
        layer02         = rgb("#FFFFFF"),
        layer03         = rgb("#EDF0F3"),
        layerHover01    = rgb("#E3E7EC"),
        layerSelected01 = rgb("#D7DDE5"),
        borderSubtle01  = rgb("#D3D8DE"),
        borderStrong01  = rgb("#AEB6C0"),
        fieldBorder     = rgb("#747C87"),
        text            = rgb("#15181D"),
        textMuted       = rgb("#4E5661"),
        textFaint       = rgb("#7A828C"),
        accent          = rgb("#20252C"),
        accentText      = rgb("#FFFFFF"),
        accentHover     = rgb("#343B45"),
        accentPressed   = rgb("#0F1216"),
        accentBright    = rgb("#20252C"),
        accentSoft      = rgb("#DDE2E9"),
        success         = rgb("#176C3A"),
        warning         = rgb("#805400"),
        error           = rgb("#B3263A"),
        info            = rgb("#155F91"),
        well            = rgb("#F6F7F9"),
        font = "Segoe UI, 10",
        glass = true,
        glassDark = false,
        glassBloom = 0.18, glassBloomWidth = 0.60, glassBloomHeight = 1.4,
        glassChromeAlpha = 0.82, glassFloatingAlpha = 0.90,
        glassTopRim = "255 255 255 204", glassRim = "0 0 0 20",
        radius = 6, radiusFrame = 8,
    }
    p.warningText = p.accentText
    p.gradTop, p.gradBottom = p.layer01, p.layer01
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.text

    Theme.initialize(self, {
        id      = "lunar_light",
        family  = "lunar",
        family_label = "Lunar",
        label   = "Lunar Light",
        palette = p,
        dark    = false,
    })
end

function LunarLightTheme:rules()
    return lunar.build(self:palette())
end

return LunarLightTheme
