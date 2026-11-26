-- Lunar: graphite, pearl and silver glass. Hue is reserved for state.
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local space = require("core.classes.Themes.lunar_space")
local rgb   = lunar.rgb

local LunarLightTheme = Theme:subclass("LunarLightTheme")

function LunarLightTheme:initialize()
    local p = {
        bg              = rgb("#BAC5D1"),
        layer01         = rgb("#F4F7FB"),
        layer02         = rgb("#F8F9FA"),
        layer03         = rgb("#F4F7FB"),
        layerHover01    = rgb("#E7ECF2"),
        layerSelected01 = rgb("#D4DCE6"),
        borderSubtle01  = rgb("#D3D8DE"),
        borderStrong01  = rgb("#AEB6C0"),
        fieldBorder     = rgb("#626C79"),
        text            = rgb("#15181D"),
        textMuted       = rgb("#454E5B"),
        textFaint       = rgb("#7A828C"),
        accent          = rgb("#202733"),
        accentText      = rgb("#F8FAFC"),
        accentHover     = rgb("#475263"),
        accentPressed   = rgb("#171D27"),
        accentBright    = rgb("#20252C"),
        accentSoft      = rgb("#D4DCE6"),
        success         = rgb("#176C3A"),
        warning         = rgb("#805400"),
        error           = rgb("#B3263A"),
        info            = rgb("#155F91"),
        well            = rgb("#EDF0F4"),
        font = "Segoe UI, 10",
        glass = true,
        glassDark = false,
        -- The same space scene as the dark mode, by day (lunar_space.lua).
        background = space.background(),
        glassFrameTint = rgb("#F4F7FB"), glassFrameAlpha = 0.36,
        glassVeilTint = rgb("#F8F9FA"), glassVeilAlpha = 0.68, glassVeilClear = true,
        glassChromeTint = rgb("#F4F7FB"), glassChromeAlpha = 0.36,
        glassFloatingTint = rgb("#F4F7FB"), glassFloatingAlpha = 0.22, glassLip = 8,
        glassTextWell = rgb("#EEF1F5"),
        glassWellHover = rgb("#E2E8EF"), glassWellSelected = rgb("#D1D9E3"),
        -- The 2 px bevel: an upper-left highlight fading 60% -> 10%, a lower inner shade 9%.
        glassRimHi = "255 255 255 153", glassRimLo = "255 255 255 26", glassRimInner = "0 0 0 23",
        -- The scene's worst pixel under labels (lunar_space.SAMPLES), for the audit.
        glassSampleWorst = space.SAMPLES.light.frame,
        glassShadowAlpha = 0.17,
        glassSheetWide = { top = 6, side = 10 }, glassSheetNarrow = { top = 4, bottom = 4, side = 8 },
        glassTransport = { wide = 18, narrow = 12, below = 8 },
        -- Primary action: an opaque graphite gradient.
        primaryTop = rgb("#404959"), primaryBottom = rgb("#1E2530"), primaryText = rgb("#F8FAFC"),
        primaryHover = rgb("#475263"), primaryPressed = rgb("#171D27"),
        radius = 8, radiusFrame = 8, radiusSheet = 14, radiusFloating = 16,
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
