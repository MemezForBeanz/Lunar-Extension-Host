--- Classic Dark (Carbon Gray 100) dark theme.
--
-- Based on the IBM Carbon Design System "Gray 100" dark palette — Carbon's
-- flagship dark look. Keeps the id/label `"classic_dark"` so existing saved
-- settings continue to work. Delegates widget rule mapping to the shared
-- `carbon_rules` builder.
--
-- The palette is the complete Gray 100 layer system. Hover, selection, and
-- elevation are three *distinct* token groups in Carbon — #333333, #393939, and
-- #525252 respectively — and must stay distinct for the app to read as Carbon.
-- `carbon_rules` uses these tokens directly; the older single `surface2` key is
-- kept as an alias for widget definitions that still use it.
--
-- @classmod core.classes.Themes.ClassicDarkTheme
local Theme  = require("core.classes.Themes.Theme")
local carbon = require("core.classes.Themes.carbon_rules")
local rgb    = carbon.rgb

local ClassicDarkTheme = Theme:subclass("ClassicDarkTheme")

function ClassicDarkTheme:initialize()
    local p = {
        -- Backgrounds — the canvas behind all layered surfaces
        bg                 = rgb("#161616"),  -- $background
        bgHover            = rgb("#353535"),  -- $background-hover
        bgActive           = rgb("#525252"),  -- $background-active
        bgSelected         = rgb("#393939"),  -- $background-selected

        -- Layer stack — up to three elevations, each with its own hover token
        layer01            = rgb("#262626"),  -- $layer-01 / $field-01
        layer02            = rgb("#393939"),  -- $layer-02 / $field-02
        layer03            = rgb("#525252"),  -- $layer-03

        -- Hover tokens are *intentionally* lighter than the resting layer beneath
        -- them; using the next layer's resting color for hover would make the
        -- hovered item look like it had jumped an elevation rather than lit up.
        layerHover01       = rgb("#333333"),  -- $layer-hover-01
        layerHover02       = rgb("#474747"),  -- $layer-hover-02

        -- Selection tokens share some values with layers in Gray 100, but they
        -- are separate tokens: if Carbon ever adjusts the scale the distinction
        -- is already in place here.
        layerSelected01    = rgb("#393939"),  -- $layer-selected-01
        layerSelected02    = rgb("#525252"),  -- $layer-selected-02
        layerAccent01      = rgb("#393939"),  -- $layer-accent-01

        -- Border hierarchy: subtle separates siblings; strong separates sections
        borderSubtle01     = rgb("#393939"),  -- $border-subtle-01
        borderSubtle02     = rgb("#525252"),  -- $border-subtle-02
        borderStrong01     = rgb("#6f6f6f"),  -- $border-strong-01
        borderInverse      = rgb("#f4f4f4"),  -- $border-inverse

        -- Text hierarchy
        text               = rgb("#f4f4f4"),  -- $text-primary
        textMuted          = rgb("#c6c6c6"),  -- $text-secondary
        textPlaceholder    = rgb("#6f6f6f"),  -- $text-placeholder
        textHelper         = rgb("#8d8d8d"),  -- $text-helper
        textOnColor        = rgb("#ffffff"),  -- $text-on-color
        textDisabled       = rgb("#6f6f6f"),  -- $text-disabled

        -- Interactive: the single blue used for links, focus rings, and selection
        accent             = rgb("#4589ff"),  -- $interactive
        linkPrimary        = rgb("#78a9ff"),  -- $link-primary
        focus              = rgb("#ffffff"),  -- $focus (white ring on dark)
        accentText         = rgb("#ffffff"),  -- $text-on-color

        -- Buttons
        buttonPrimary      = rgb("#0f62fe"),  -- $button-primary
        buttonPrimaryHover = rgb("#0353e9"),  -- $button-primary-hover
        buttonPrimaryActive= rgb("#002d9c"),  -- $button-primary-active
        buttonSecondary    = rgb("#6f6f6f"),  -- $button-secondary
        buttonDanger       = rgb("#da1e28"),  -- $button-danger

        -- Semantic support colors
        error              = rgb("#fa4d56"),  -- $support-error
        success            = rgb("#42be65"),  -- $support-success
        warning            = rgb("#f1c21b"),  -- $support-warning
        warningText        = rgb("#161616"),  -- black text on yellow warning chip
        info               = rgb("#4589ff"),  -- $support-info

        font               = "IBM Plex Sans, 10",
    }

    -- Legacy aliases — all code that reads p.surface, p.surface2, p.border,
    -- p.borderStrong lands on the canonical token, not a copy, so a palette
    -- dump still produces consistent values.
    p.surface      = p.layer01
    p.surface2     = p.layerHover01
    p.border       = p.borderSubtle01
    p.borderStrong = p.borderStrong01
    p.listBg       = p.layer01
    p.listText     = p.text
    p.listSelText  = p.accent

    Theme.initialize(self, {
        id      = "classic_dark",
        label   = "Classic Dark",
        palette = p,
    })
end

function ClassicDarkTheme:rules()
    return carbon.build(self:palette())
end

return ClassicDarkTheme
