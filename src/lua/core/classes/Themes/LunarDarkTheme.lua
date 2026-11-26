-- Lunar: graphite, pearl and silver glass. Hue is reserved for state.
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local space = require("core.classes.Themes.lunar_space")
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
        -- The reactive space scene (core.ui.Background, lunar_space.lua), shared with the light
        -- mode so a switch animates it; the frame round the sheet is the scene under a
        -- light tint (one connected chrome), the sheet a veil of glass over it.
        background = space.background(),
        glassFrameTint = rgb("#070A12"), glassFrameAlpha = 0.40,
        glassVeilTint = rgb("#171B21"), glassVeilAlpha = 0.74,
        glassChromeTint = rgb("#151B24"), glassChromeAlpha = 0.32,
        glassFloatingTint = rgb("#1E2630"), glassFloatingAlpha = 0.24, glassLip = 8,
        glassTextWell = rgb("#242C36"),
        -- Interactive fills on the wells: hover, and selected / pressed (the brightest).
        glassWellHover = rgb("#2C3440"), glassWellSelected = rgb("#353D49"),
        -- The 2 px bevel: an upper-left highlight fading 45% -> 8%, a lower inner shade 14%.
        glassRimHi = "255 255 255 115", glassRimLo = "255 255 255 20", glassRimInner = "0 0 0 36",
        -- The scene's worst pixel under labels (lunar_space.SAMPLES), for the audit.
        glassSampleWorst = space.SAMPLES.dark.frame,
        glassShadowAlpha = 0.32,
        -- The sheet's inset (core.ui.WorkspaceFrame) from the rail, title and status strips,
        -- wide and narrow.
        glassSheetWide = { top = 6, side = 10 }, glassSheetNarrow = { top = 4, bottom = 4, side = 8 },
        glassTransport = { wide = 18, narrow = 12, below = 8 },
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
