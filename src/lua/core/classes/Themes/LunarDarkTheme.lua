--- Lunar Dark — the host's own design language, dark variant (the default).
--
-- A deep slate night with a violet interactive accent: Carbon's structure,
-- Obsidian's dim lines and soft depth, VS Code's selective rounding. The
-- mapping of tokens onto widget roles lives in the shared
-- `core.classes.Themes.lunar_rules` builder; this file is only the palette.
--
-- @classmod core.classes.Themes.LunarDarkTheme
local Theme = require("core.classes.Themes.Theme")
local lunar = require("core.classes.Themes.lunar_rules")
local rgb   = lunar.rgb

local LunarDarkTheme = Theme:subclass("LunarDarkTheme")

function LunarDarkTheme:initialize()
    local p = {
        bg              = rgb("#1b1d23"),  -- app floor: deep slate
        layer01         = rgb("#22242c"),  -- pages, lists, fields
        layer02         = rgb("#2f3340"),  -- raised: buttons, dropdowns, toasts
        layerHover01    = rgb("#313542"),  -- pointer-enter, one step lighter
        layerSelected01 = rgb("#3a3f4f"),  -- persistent selection / pressed
        borderSubtle01  = rgb("#30333e"),  -- dim structural lines
        borderStrong01  = rgb("#464b5c"),  -- field edges, emphasis
        text            = rgb("#d6d9e0"),
        textMuted       = rgb("#a7acba"),
        accent          = rgb("#6c5ce7"),
        accentBright    = rgb("#a99eff"),  -- a mark on a dark field: 7:1  -- lunar violet (interactive)
        accentText      = rgb("#ffffff"),
        error           = rgb("#ff8a93"),
        success         = rgb("#98c379"),
        warning         = rgb("#e5c07b"),
        warningText     = rgb("#1b1d23"),
        info            = rgb("#56b6c2"),
        font            = "Segoe UI, 10",
        fieldBorder     = rgb("#6d7286"),  -- field edges: 3:1 on the page
        well            = rgb("#1b1d23"),   -- recessed: lists, fields, output
        accentSoft      = rgb("#35345c"),   -- a chosen row

        -- The accent strip's sweep: violet into slate.
        gradTop         = rgb("#7c6cf2"),
        gradBottom      = rgb("#4a5578"),

        radius          = 6,   -- interactive controls
        radiusFrame     = 8,   -- container frames
    }
    -- Legacy aliases, so widgets reading the six-key palette keep working.
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.accent

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
