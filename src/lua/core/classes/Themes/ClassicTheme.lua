--- Classic (Carbon Gray 10) light theme.
--
-- Now based on the IBM Carbon Design System "Gray 10" light palette.
-- Previously the native-Windows look; replaced by Carbon Gray 10 tokens.
-- Keeps the id/label `"classic"` so existing saved settings and the
-- `ThemeManager` fallback continue to work. Delegates widget rule
-- mapping to the shared `carbon_rules` builder.
--
-- The palette is the complete Gray 10 layer system. Hover, selection, and
-- elevation tokens are kept separate so `carbon_rules` can map each widget
-- state to the right color — something that was impossible when all three
-- shared one `surface2` entry.
--
-- @classmod core.classes.Themes.ClassicTheme
local Theme  = require("core.classes.Themes.Theme")
local carbon = require("core.classes.Themes.carbon_rules")
local rgb    = carbon.rgb

local ClassicTheme = Theme:subclass("ClassicTheme")

function ClassicTheme:initialize()
    local p = {
        -- Backgrounds — the canvas behind all layered surfaces
        bg                 = rgb("#f4f4f4"),  -- $background
        bgHover            = rgb("#e8e8e8"),  -- $background-hover
        bgActive           = rgb("#c6c6c6"),  -- $background-active
        bgSelected         = rgb("#e0e0e0"),  -- $background-selected

        -- Layer stack
        layer01            = rgb("#ffffff"),  -- $layer-01 / $field-01
        layer02            = rgb("#f4f4f4"),  -- $layer-02 / $field-02
        layer03            = rgb("#ffffff"),  -- $layer-03

        -- Hover tokens — the slight darkening on pointer entry
        layerHover01       = rgb("#e8e8e8"),  -- $layer-hover-01
        layerSelected01    = rgb("#e0e0e0"),  -- $layer-selected-01 (slightly darker)
        layerAccent01      = rgb("#e0e0e0"),  -- $layer-accent-01

        -- Border hierarchy
        borderSubtle01     = rgb("#e0e0e0"),  -- $border-subtle-01
        borderSubtle02     = rgb("#e0e0e0"),  -- $border-subtle-02
        borderStrong01     = rgb("#8d8d8d"),  -- $border-strong-01

        -- Text hierarchy
        text               = rgb("#161616"),  -- $text-primary
        textMuted          = rgb("#525252"),  -- $text-secondary
        textPlaceholder    = rgb("#a8a8a8"),  -- $text-placeholder
        textHelper         = rgb("#6f6f6f"),  -- $text-helper
        textOnColor        = rgb("#ffffff"),  -- $text-on-color

        -- Interactive
        accent             = rgb("#0f62fe"),  -- $interactive / $focus
        linkPrimary        = rgb("#0f62fe"),  -- $link-primary
        accentText         = rgb("#ffffff"),  -- $text-on-color

        -- Buttons
        buttonPrimary      = rgb("#0f62fe"),  -- $button-primary
        buttonPrimaryHover = rgb("#0353e9"),  -- $button-primary-hover
        buttonPrimaryActive= rgb("#002d9c"),  -- $button-primary-active

        -- Semantic support colors
        error              = rgb("#da1e28"),  -- $support-error
        success            = rgb("#24a148"),  -- $support-success
        warning            = rgb("#f1c21b"),  -- $support-warning
        warningText        = rgb("#161616"),  -- black text on yellow warning chip
        info               = rgb("#0043ce"),  -- $support-info

        font               = "IBM Plex Sans, 10",
    }

    -- Legacy aliases — keep every consumer of the old flat key set working
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.accent

    Theme.initialize(self, {
        id      = "classic",
        label   = "Classic",
        palette = p,
    })
end

function ClassicTheme:rules()
    return carbon.build(self:palette())
end

return ClassicTheme
