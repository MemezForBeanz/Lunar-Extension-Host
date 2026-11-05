--- Lunar Light — the host's own design language, light variant.
--
-- The daylight counterpart of `LunarDarkTheme` ("Match system theme" pairs
-- them): the same structure and violet accent on paper-white layers, with
-- semantic colors deepened for contrast on light surfaces. Role mapping lives
-- in the shared `core.classes.Themes.lunar_rules` builder.
--
-- @classmod core.classes.Themes.LunarLightTheme
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local rgb   = lunar.rgb

local LunarLightTheme = Theme:subclass("LunarLightTheme")

function LunarLightTheme:initialize()
    local p = {
        bg              = rgb("#f2f2f7"),
        layer01         = rgb("#f6f6f9"),
        layer02         = rgb("#ffffff"),
        layerHover01    = rgb("#ececf3"),
        layerSelected01 = rgb("#e2e2ee"),
        borderSubtle01  = rgb("#d0d0da"),
        borderStrong01  = rgb("#b8b8c8"),
        text            = rgb("#27272f"),
        textMuted       = rgb("#666a73"),
        accent          = rgb("#6a5ae0"),  -- violet, deepened for light surfaces
        accentText      = rgb("#ffffff"),
        error           = rgb("#b3243d"),
        success         = rgb("#3a7d44"),
        warning         = rgb("#946200"),
        warningText     = rgb("#ffffff"),
        info            = rgb("#0b6a78"),
        font            = "Segoe UI, 10",
        fieldBorder     = rgb("#8a8f9c"),  -- field edges: 3:1 on the page
        well            = rgb("#ffffff"),   -- recessed: lists, fields, output
        accentSoft      = rgb("#d6d0f8"),   -- a chosen row
        gradShellWell   = rgb("#e9e9f1"),   -- tab strip: a whisper off the page, never a grey band

        gradTop         = rgb("#6a5ae0"),
        gradBottom      = rgb("#8d9ac9"),

        radius          = 6,
        radiusFrame     = 8,
    }
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.accent

    Theme.initialize(self, {
        id      = "lunar_light",
        label   = "Lunar Light",
        palette = p,
        dark    = false,
    })
end

function LunarLightTheme:rules()
    return lunar.build(self:palette())
end

return LunarLightTheme
