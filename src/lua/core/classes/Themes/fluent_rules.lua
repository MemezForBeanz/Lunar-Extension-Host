-- fluent_rules.lua
-- Shared, token-driven rules() builder for the Microsoft Fluent 2 -styled themes
-- (currently One Dark Pro). Like carbon_rules, this is a plain module -- NOT a Theme
-- subclass -- so ThemeManager's auto-discovery skips it.
--
-- Fluent 2's structural language differs from Carbon in a few deliberate ways that are
-- encoded here:
--   * Buttons follow Fluent's default/primary split: generic action buttons are
--     "Secondary/Default" (neutral surface fill + subtle border, lighter surface on
--     hover), while the primary log-parser button is a solid accent "Primary" button
--     (accent fill, text-on-accent, deeper accent on hover).
--   * Selection uses an accent-tinted layer with accent text (Fluent list selection).
--   * Neutral, low-contrast borders with a stronger border token for emphasis.
--
-- GRADIENTS: gradients are now rendered NATIVELY by the forked IUP flat controls
-- (iup_draw.c honors GRADIENTCOLOR/GRADIENTDIRECTION/CORNERRADIUS). A rule opts a
-- control into a gradient fill by carrying `gradcolor` (the second, "to" color; the
-- rule's `bg` is the first, "from" color) and optionally `graddir`
-- ("VERTICAL"|"HORIZONTAL", default VERTICAL). ThemeManager:_attrsFromRule turns these
-- into the native GRADIENTCOLOR/GRADIENTDIRECTION attributes. When the palette does not
-- opt into gradients (gradEnabled ~= true) the gradcolor fields collapse to nil and the
-- controls render as solid fills -- so the SAME rules table drives both the Fluent/One
-- Dark Pro gradient look and the flat Carbon-style themes. This replaces the retired
-- canvas-based Gradient* widgets entirely.
--
-- Expected palette tokens (all "R G B" strings unless noted):
--   bg, surface, surface2, text, textMuted, accent, accentHover, accentText,
--   border, borderStrong, error/success/warning/info, warningText, font,
--   gradEnabled (bool), gradTop, gradBottom, radius (number).

local M = {}

function M.rgb(hex)
    hex = hex:gsub("#", "")
    return string.format("%d %d %d",
        tonumber(hex:sub(1, 2), 16),
        tonumber(hex:sub(3, 4), 16),
        tonumber(hex:sub(5, 6), 16))
end

-- Lighten (f > 0, toward white) or darken (f < 0) an "R G B" string by fraction f.
-- Mirrors the retired core.ui.Gradient.shade so the native button gradients keep the
-- same subtle tone the canvas buttons used.
local function shade(rgbstr, f)
    local rr, gg, bb = tostring(rgbstr):match("(%d+)%s+(%d+)%s+(%d+)")
    if not rr then return rgbstr end
    local function adj(v)
        v = tonumber(v)
        if f >= 0 then v = v + (255 - v) * f else v = v * (1 + f) end
        v = math.floor(v + 0.5)
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        return v
    end
    return string.format("%d %d %d", adj(rr), adj(gg), adj(bb))
end
M.shade = shade

-- Re-size a theme's IUP font string, keeping its family. See the equivalent in
-- carbon_rules.lua for why headings derive from the palette font rather than
-- naming a second typeface.
local function sized(font, points, bold)
    local family = tostring(font or "Segoe UI"):match("^%s*([^,]+)") or "Segoe UI"
    return string.format("%s, %s%d", family, bold and "Bold " or "", points)
end

function M.build(p)
    local accentHover = p.accentHover or p.accent
    -- Native gradient endpoints. `gradOn` is set only by gradient themes (One Dark Pro).
    -- Default/secondary buttons get a subtle vertical darkening toward their lower edge
    -- (top = surface, bottom = slightly darker) so they read as softly raised without
    -- losing the neutral surface identity; the Primary button gets the full signature
    -- blue -> purple accent sweep (top = gradTop, bottom = gradBottom).
    local gradOn      = (p.gradEnabled == true) and p.gradTop and p.gradBottom
    local defGrad     = gradOn and shade(p.surface, -0.10) or nil     -- secondary/default bottom
    local priTop      = gradOn and p.gradTop or p.accent              -- primary top / bg
    local priGrad     = gradOn and p.gradBottom or nil               -- primary bottom
    local priBorder   = gradOn and p.gradBottom or p.accent
    -- Native IUP flat scrollbars can only render SOLID colors (no per-pixel gradient),
    -- but they DO expose separate normal/hover/pressed thumb colors. When the theme opts
    -- into gradients, drive those three states from the gradient endpoints so the thumb
    -- reads as part of the same blue->purple family (normal = gradient start, hover =
    -- gradient end, pressed = deeper accent) instead of a single flat accent swatch.
    local sfg = (p.gradEnabled and p.gradTop) or p.accent
    local shi = (p.gradEnabled and p.gradBottom) or p.accent
    local spr = (p.gradEnabled and (p.accentHover or p.gradBottom)) or accentHover
    return {
        -- Shell header: the band naming the product, brand semibold beside the
        -- product name (see carbon_rules for the reasoning).
        shellheader   = { bg = p.bg, fg = p.text, border = p.border, borderwidth = 1 },
        shellbrand    = { bg = p.bg, fg = p.text, font = sized(p.font, 11, true), padding = "0x0" },
        shellproduct  = { bg = p.bg, fg = p.text, font = sized(p.font, 11), padding = "0x0" },
        shellmeta     = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 9), padding = "0x0" },

        -- Notifications (core.ui.Toast): a raised surface with a bar in the kind's
        -- status colour. The toast sets its own fonts.
        toast_bg_info     = { bg = p.surface, fg = p.text },
        toast_bg_success  = { bg = p.surface, fg = p.text },
        toast_bg_warning  = { bg = p.surface, fg = p.text },
        toast_bg_error    = { bg = p.surface, fg = p.text },
        toast_bar_info    = { bg = p.info },
        toast_bar_success = { bg = p.success },
        toast_bar_warning = { bg = p.warning },
        toast_bar_error   = { bg = p.error },
        toast_title       = { bg = p.surface, fg = p.text },
        toast_body        = { bg = p.surface, fg = p.textMuted },
        toast_close       = { bg = p.surface, fg = p.textMuted, border = p.surface, borderwidth = 0,
            hover = p.surface2, hovertext = p.text },

        dialog        = { bg = p.bg,      fg = p.text, font = p.font, border = p.border },
        canvas        = { bg = p.bg,      fg = p.text, border = p.border },
        vbox          = { bg = p.bg,      fg = p.text, font = p.font },
        hbox          = { bg = p.bg,      fg = p.text, font = p.font },
        zbox          = { bg = p.bg,      fg = p.text, font = p.font },
        cbox          = { bg = p.bg,      fg = p.text, font = p.font },
        gridbox       = { bg = p.bg,      fg = p.text, font = p.font },
        split         = { bg = p.bg,      fg = p.text, border = p.border },
        frame         = { bg = p.bg,      fg = p.text, font = p.font, border = p.border },
        flatframe     = { bg = p.bg,      fg = p.text, font = p.font, border = p.border, radius = p.radius },
        flatseparator = { bg = p.bg, border = p.border },
        tabs          = { bg = p.bg,      fg = p.text, font = p.font, border = p.border },
        -- hover/selbg drive the tab strip's trailing "extra" buttons (the host's
        -- "+ new tab group"). Without them IupFlatTabs falls back to its own
        -- IUP_FLAT_HIGHCOLOR/PRESSCOLOR, which are blue regardless of theme.
        flattabs      = {
            bg = p.surface, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1,
            hover = p.surface2, selbg = p.borderStrong or p.border,
        },
        scrollbox     = { bg = p.surface, fg = p.text, border = p.border },
        flatscrollbox = { bg = p.surface, fg = p.text, border = p.border, borderwidth = 1,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr },
        -- Invisible scroll host that HostAPI:addTab wraps every tab in, so content
        -- taller than the window scrolls instead of being clipped off the bottom.
        -- It must disappear visually: dialog background, no border.
        tabscroll     = { bg = p.bg, fg = p.text, border = p.bg, borderwidth = 0,
            scrollbg = p.bg, scrollfg = sfg, scrollhi = shi, scrollpress = spr },
        label         = { fg = p.text,    font = p.font },
        -- Type scale (see carbon_rules.lua).
        pagetitle           = { fg = p.text,      font = sized(p.font, 16, true) },
        pagesubtitle        = { fg = p.textMuted, font = sized(p.font, 10) },
        sectiontitle        = { fg = p.text,      font = sized(p.font, 11, true) },
        hint                = { fg = p.textMuted, font = sized(p.font, 9) },
        settingslabel       = { fg = p.text,      font = p.font },
        settingslabel_muted = { fg = p.textMuted, font = p.font },
        settingspanel = { bg = p.surface },
        -- Collapsible section header in the Settings tab: a borderless full-width
        -- button that reads as a heading until hovered.
        settingsheader = {
            bg = p.surface, fg = p.text, font = p.font,
            border = p.surface, borderwidth = 0,
            hover = p.surface2, hovertext = p.text,
        },
        -- The label of a settings row that has a description to reveal.
        settingsrow = {
            bg = p.surface, fg = p.text, font = p.font,
            border = p.surface, borderwidth = 0,
            hover = p.surface2, hovertext = p.accent,
        },
        separator     = { bg = p.bg, border = p.border },
        button        = { fg = p.text, font = p.font },
        flatbutton    = { bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font },
        -- Fluent "Default/Secondary" button: neutral surface fill, subtle border,
        -- lighter surface on hover (no color inversion). Native gradient: subtle
        -- vertical darkening toward the lower edge under gradient themes.
        actionbutton  = {
            bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font,
            border = p.borderStrong, borderwidth = 1, showborder = true,
            hover = p.surface2, hovertext = p.text,
        },
        -- Fluent "Primary" button: signature accent gradient sweep (blue -> purple),
        -- text-on-accent, deeper accent on hover.
        primary_btn = {
            bg = priTop, gradcolor = priGrad, radius = p.radius, fg = p.accentText, font = p.font,
            border = priBorder, borderwidth = 1, showborder = true,
            hover = accentHover, hovertext = p.accentText,
        },
        warning_btn = {
            bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font,
            border = p.borderStrong, borderwidth = 1, showborder = true,
            hover = p.warning, hovertext = p.warningText,
        },
        danger_btn = {
            bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font,
            border = p.borderStrong, borderwidth = 1, showborder = true,
            hover = p.error, hovertext = p.accentText,
        },
        info_btn = {
            bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font,
            border = p.borderStrong, borderwidth = 1, showborder = true,
            hover = p.info, hovertext = p.accentText,
        },
        dropbutton    = {
            bg = p.surface, gradcolor = defGrad, radius = p.radius, fg = p.text, font = p.font,
            border = p.borderStrong, borderwidth = 1, showborder = true,
            hover = p.surface2, hovertext = p.text,
        },
        -- Thin gradient accent strip in the chrome (native flatlabel with a horizontal
        -- sweep). Collapses to a solid bg on non-gradient themes.
        accentstrip   = {
            bg = (gradOn and p.gradTop) or p.bg,
            gradcolor = (gradOn and p.gradBottom) or nil,
            graddir = "HORIZONTAL",
            radius = p.radius,
        },
        dropdown_list = {
            bg = p.surface, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr,
            selbg = p.surface2, seltext = p.accent, selalpha = "255",
        },
        list_bordered = {
            bg = p.surface, fg = p.text, font = p.font, border = p.border, borderwidth = 1,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr,
            selbg = p.surface, seltext = p.accent, selalpha = "0",
        },
        list_plain    = {
            bg = p.surface, fg = p.text, font = p.font, border = p.surface, borderwidth = 0,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr,
            selbg = p.surface, seltext = p.accent, selalpha = "0",
        },
        outputlog     = {
            bg = p.surface, fg = p.text, border = p.border,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr,
        },
        outputlog_scroll = {
            bg = p.surface, fg = p.text, border = p.border, borderwidth = 1,
            scrollbg = p.surface, scrollfg = sfg, scrollhi = shi, scrollpress = spr,
        },
        toggle        = { fg = p.text, font = p.font },
        flattoggle    = { bg = p.surface, fg = p.accent, font = p.font, radius = p.radius },
        flattoggle_noborder = { bg = p.surface, fg = p.accent, font = p.font, border = p.surface, borderwidth = 0, radius = p.radius },
        text          = { bg = p.surface, fg = p.text, font = p.font, border = p.border },
        multiline     = { bg = p.surface, fg = p.text, font = p.font, border = p.border },
        list          = { bg = p.surface, fg = p.text, font = p.font, border = p.border },
        flatlist      = {
            bg = p.surface, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1,
            selbg = p.accent, seltext = p.accentText, selalpha = "255",
        },
        progressbar   = { bg = p.surface, fg = p.accent, border = p.border },
        gauge         = { bg = p.surface, fg = p.accent, border = p.border },
    }
end

return M
