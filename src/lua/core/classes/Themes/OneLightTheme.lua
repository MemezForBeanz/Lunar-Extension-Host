--- One Light theme: the daylight half of the "One" palette, paired with One Dark Pro.
--
-- Colours start from the well-known One Light scheme. Its accent and semantic hues are
-- deepened where the originals miss 4.5:1 on these surfaces; structure comes from the
-- same `fluent_rules` builder as One Dark Pro.
--
-- @classmod core.classes.Themes.OneLightTheme
local Theme  = require("core.classes.Themes.Theme")
local fluent = require("core.classes.Themes.fluent_rules")
local rgb    = fluent.rgb

local OneLightTheme = Theme:subclass("OneLightTheme")

function OneLightTheme:initialize()
    local p = {
        bg           = rgb("#fafafa"),
        surface      = rgb("#f0f0f1"),
        surface2     = rgb("#e5e5e6"),
        text         = rgb("#383a42"),
        textMuted    = rgb("#5f626c"),
        accent       = rgb("#2f66dd"),  -- One Light blue, deepened for white text
        accentHover  = rgb("#2556c4"),
        accentText   = rgb("#ffffff"),
        border       = rgb("#d4d4d6"),
        borderStrong = rgb("#a0a1a7"),
        error        = rgb("#ca1243"),
        success      = rgb("#3f7f3e"),
        warning      = rgb("#8a5e00"),
        warningText  = rgb("#ffffff"),
        info         = rgb("#0b7196"),
        font         = "Segoe UI, 10",

        gradEnabled  = true,
        gradTop      = rgb("#2f66dd"),
        gradBottom   = rgb("#a626a4"),

        radius       = 6,
    }
    p.listBg      = p.surface
    p.listText    = p.text
    p.listSelText = p.accent

    Theme.initialize(self, {
        id      = "one_light",
        family  = "one",
        family_label = "One",
        label   = "One Light",
        palette = p,
        dark    = false,
    })
end

function OneLightTheme:rules()
    return fluent.build(self:palette())
end

return OneLightTheme
