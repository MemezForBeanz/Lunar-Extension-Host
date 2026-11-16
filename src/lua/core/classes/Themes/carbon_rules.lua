-- Carbon v11 component anatomy, states, sizing and typography:
-- https://carbondesignsystem.com/components/button/style/
-- https://carbondesignsystem.com/components/text-input/style/
-- https://carbondesignsystem.com/components/dropdown/style/
-- https://carbondesignsystem.com/components/data-table/style/
-- https://carbondesignsystem.com/components/tabs/style/
-- https://carbondesignsystem.com/elements/typography/type-sets/
-- https://carbondesignsystem.com/elements/spacing/overview/
-- Values are mapped to existing host roles; native IUP ignores ImGui-only flags.

local L = require("core.lib.CarbonLayout")

local M = {}

function M.rgb(hex)
    hex = hex:gsub("#", "")
    return string.format("%d %d %d",
        tonumber(hex:sub(1, 2), 16),
        tonumber(hex:sub(3, 4), 16),
        tonumber(hex:sub(5, 6), 16))
end

local function sized(font, points, bold)
    local family = tostring(font or "Segoe UI"):match("^%s*([^,]+)") or "Segoe UI"
    return string.format("%s, %s%d", family, bold and "Bold " or "", points)
end

function M.build(p)
    local BTN_PAD = "12x5"

    local FIELD_PAD = string.format("0x%d", math.floor((L.CARBON.input_height - 16) / 2))
    local hover    = p.layerHover01    or p.surface2
    local selected = p.layerSelected01 or p.surface2
    local elevated = p.layer02         or p.surface2
    local layer1   = p.layer01        or p.surface

    local rules = {
        pagetitle     = { fg = p.text,      font = sized(p.font, 21, true) },
        pagesubtitle  = { fg = p.textMuted, font = sized(p.font, 11) },
        sectiontitle  = { fg = p.text,      font = sized(p.font, 15, true) },
        hint          = { fg = p.textMuted, font = sized(p.font, 9) },

        error_label   = { fg = p.error,   font = p.font },
        success_label = { fg = p.success, font = p.font },
        warning_label = { fg = p.warning, font = p.font },
        info_label    = { fg = p.info,    font = p.font },
        mono          = { fg = p.text,      font = "Consolas, 10" },
        mono_hint     = { fg = p.textMuted, font = "Consolas, 9" },

        statusbar      = { bg = p.bg, fg = p.textMuted, border = p.borderSubtle01 or p.border },
        statusbar_text = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 9) },

        ghost_btn = {
            bg = layer1, fg = p.textMuted, font = p.font,
            border = layer1, borderwidth = 0, padding = "8x3",
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },

        link_btn = {
            bg = layer1, fg = p.accent, font = p.font,
            border = layer1, borderwidth = 0, padding = "2x1",
            hover = layer1, hovertext = p.accent,
            pressed = layer1, pressedtext = p.textMuted,
        },

        icon_btn = {
            bg = layer1, fg = p.textMuted, font = p.font,
            border = layer1, borderwidth = 0, padding = "4x4",
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },

        shellheader   = { bg = p.bg, fg = p.text, border = p.borderSubtle01 or p.border, borderwidth = 1 },
        shellbrand    = { bg = p.bg, fg = p.text, font = sized(p.font, 11, true), padding = "0x0" },
        shellproduct  = { bg = p.bg, fg = p.text, font = sized(p.font, 11), padding = "0x0" },
        shellmeta     = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 9), padding = "0x0" },
        accentstrip   = { bg = p.bg },

        toast_bg_info     = { bg = elevated, fg = p.text },
        toast_bg_success  = { bg = elevated, fg = p.text },
        toast_bg_warning  = { bg = elevated, fg = p.text },
        toast_bg_error    = { bg = elevated, fg = p.text },
        toast_bar_info    = { bg = p.info },
        toast_bar_success = { bg = p.success },
        toast_bar_warning = { bg = p.warning },
        toast_bar_error   = { bg = p.error },
        toast_title       = { bg = elevated, fg = p.text },
        toast_body        = { bg = elevated, fg = p.textMuted },
        toast_close       = { bg = elevated, fg = p.textMuted, border = elevated, borderwidth = 0,
            hover = hover, hovertext = p.text },

        dialog        = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        canvas        = { bg = p.bg,     fg = p.text, border = p.border },
        vbox          = { bg = p.bg,     fg = p.text, font = p.font },
        hbox          = { bg = p.bg,     fg = p.text, font = p.font },
        zbox          = { bg = p.bg,     fg = p.text, font = p.font },
        cbox          = { bg = p.bg,     fg = p.text, font = p.font },
        gridbox       = { bg = p.bg,     fg = p.text, font = p.font },
        split         = { bg = p.bg,     fg = p.text, border = p.border, sash = p.accent or p.border },
        frame         = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        flatframe     = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        flatseparator = { bg = p.bg, border = p.border },
        tabs          = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        flattabs      = {
            bg = layer1, fg = p.text, font = p.font,
            tabsbg = p.bg, tabsfg = p.textMuted,
            border = p.border, borderwidth = 1,
            hover = hover, selbg = selected,
        },
        scrollbox     = { bg = layer1, fg = p.text, border = p.border },
        flatscrollbox = { bg = layer1, fg = p.text, border = p.border, borderwidth = 1 },
        tabscroll     = { bg = p.bg, fg = p.text, border = p.bg, borderwidth = 0 },
        label         = { fg = p.text,    font = p.font },
        settingslabel       = { fg = p.text,      font = p.font },
        settingslabel_muted = { fg = p.textMuted, font = p.font },
        settings_crumb = { fg = p.text, font = p.font, padding = "0x0" },
        settings_nav_group = { fg = p.textMuted, font = p.font, padding = "12x8" },
        codeview_corner = { bg = layer1, fg = p.textMuted, border = layer1, borderwidth = 0 },
        palette_rows = { bg = layer1, fg = p.text, secondary = p.textMuted, font = p.font,
            border = layer1, borderwidth = 0, scrollbg = layer1,
            selbg = selected, seltext = p.text, selalpha = "0" },
        settingspanel = { bg = layer1, border = p.border },
        settingsheader = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0,
            hover = hover, hovertext = p.text,
        },
        settingsrow = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0,
            hover = hover, hovertext = p.accent,
        },
        separator     = { bg = p.bg, border = p.border },
        button        = { fg = p.text, font = p.font },
        flatbutton    = { bg = layer1, fg = p.text, font = p.font },
        actionbutton  = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.accent, hovertext = p.accentText,
        },
        primary_btn = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.accent, hovertext = p.accentText,
        },
        warning_btn = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.warning, hovertext = p.warningText,
        },
        danger_btn = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.error, hovertext = p.accentText,
        },
        info_btn = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.info, hovertext = p.accentText,
        },
        dropbutton    = {
            bg = elevated, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1, showborder = true,
            hover = hover, hovertext = p.text,
        },
        dropdown_list = {
            bg = elevated, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1,
            scrollbg = elevated, scrollfg = p.accent,
            selbg = selected, seltext = p.accent, selalpha = "255",
        },
        list_bordered = {
            bg = layer1, fg = p.text, font = p.font, border = p.border, borderwidth = 1,
            scrollbg = layer1, scrollfg = p.accent,
            selbg = layer1, seltext = p.accent, selalpha = "0",
        },
        list_plain    = {
            bg = layer1, fg = p.text, font = p.font, border = layer1, borderwidth = 0,
            scrollbg = layer1, scrollfg = p.accent,
            selbg = layer1, seltext = p.accent, selalpha = "0",
        },
        outputlog     = {
            font = "Consolas, 9",
            bg = layer1, fg = p.text, border = p.border,
            scrollbg = layer1, scrollfg = p.accent,
        },
        outputlog_scroll = {
            bg = layer1, fg = p.text, border = p.border, borderwidth = 1,
            scrollbg = layer1, scrollfg = p.accent,
        },
        toggle        = { fg = p.text, font = p.font },
        flattoggle    = { bg = layer1, fg = p.accent, font = p.font },
        flattoggle_noborder = { bg = layer1, fg = p.accent, font = p.font, border = layer1, borderwidth = 0 },
        text      = { bg = layer1, fg = p.text, font = p.font,
                      border = p.borderStrong01 or p.borderStrong or p.border },
        multiline = { bg = layer1, fg = p.text, font = p.font,
                      border = p.borderStrong01 or p.borderStrong or p.border,
                      padding = FIELD_PAD },
        list      = { bg = layer1, fg = p.text, font = p.font,
                      border = p.borderStrong01 or p.borderStrong or p.border,
                      padding = FIELD_PAD },
        flatlist      = {
            bg = layer1, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1,
            selbg = p.accent, seltext = p.accentText, selalpha = "255",
        },
        flatrows = { bg = layer1, fg = p.text, secondary = p.textMuted, font = p.font,
            border = p.border, itemradius = 4, itemmarker = p.accent,
            selbg = p.accent, seltext = p.accentText, hover = p.layerHover01, scrollsize = 8, scrollinset = 2, scrollfg = p.border, scrollhi = p.textMuted, scrollpress = p.accent },
        flatgrid = { bg = layer1, fg = p.text, secondary = p.textMuted, font = p.font,
            itemradius = 0, itemmarker = p.accent, hover = p.border, placeholder = p.layerHover01, scrollsize = 8, scrollinset = 2, scrollfg = p.border, scrollhi = p.textMuted, scrollpress = p.accent },
        flatseek = { bg = layer1, track = p.border, buffer = p.textMuted, played = p.accent, mark = p.textMuted },
        flatsegmented = { bg = layer1, fg = p.text, font = p.font,
            border = p.border, selbg = p.accent, seltext = p.accentText },
        progressbar   = { bg = layer1, fg = p.accent, border = p.border },
        gauge         = { bg = layer1, fg = p.accent, border = p.border },
    }
    rules.list_mono = {}
    for key, value in pairs(rules.list_bordered) do rules.list_mono[key] = value end
    rules.list_mono.font = "Consolas, 9"
    for _, role in ipairs({ "flatbutton", "primary_btn", "actionbutton", "ghost_btn",
                            "danger_btn", "warning_btn", "info_btn", "link_btn", "icon_btn" }) do
        rules[role].inactivebg = p.layer01 or p.surface or p.bg
        rules[role].inactivefg = p.textMuted
    end
    require("core.classes.Themes.fluent_rules").addShellRoles(rules, p)
    require("core.classes.Themes.fluent_rules").addPlainRoles(rules, p.bg)
    rules.flattabs_sub = rules.flattabs
    -- U3 page-template roles: opaque work surfaces, shared by every tool.
    local page_bg = p.layer02 or p.surface or p.bg
    for _, role in ipairs({ "page_surface", "page_header", "page_toolbar", "page_column", "page_inspector", "page_dock" }) do
        rules[role] = { bg = page_bg, fg = p.text, font = p.font, borderwidth = 0 }
    end
    -- End U3 page-template roles.
    rules = require("core.classes.Themes.shell_rules")(rules, p, {
        well = layer1, hover = hover, selected = selected, border = p.borderSubtle01 or p.border,
        font = p.font, small_font = sized(p.font, 9),
    })
    -- IUP point sizes: body rounds 14px to 11pt (15px at 96 DPI).
    rules.pagetitle.font = sized(p.font, 15)
    rules.sectiontitle.font = sized(p.font, 11, true)
    rules.pagesubtitle.font = sized(p.font, 11)
    rules.hint.font = sized(p.font, 9)
    for _, role in ipairs({ "mono", "mono_hint", "outputlog", "list_mono" }) do
        rules[role].font = "IBM Plex Mono, 10"
    end
    local function button(bg, fg, hi, press, edge, height)
        return { bg = bg, fg = fg, font = p.font, hover = hi, pressed = press,
            hovertext = fg, pressedtext = fg, border = edge or bg,
            borderwidth = edge and 1 or 0, showborder = edge ~= nil,
            radius = 0, padding = L.margin(5, 3), controlheight = height or L.px(8),
            inactivebg = p.buttonDisabled or selected, inactivefg = p.textOnColorDisabled or p.textMuted,
            focuscolor = p.focus, focusinset = p.focusInset }
    end
    rules.primary_btn = button(p.buttonPrimary or p.accent, p.textOnColor or p.accentText,
        p.buttonPrimaryHover or p.accent, p.buttonPrimaryActive or p.accent)
    rules.secondary_btn = button(p.buttonSecondary or elevated, p.textOnColor or p.accentText,
        p.buttonSecondaryHover or hover, p.buttonSecondaryActive or selected)
    -- Supporting actions are ghost; only the page primary carries a solid fill.
    rules.actionbutton = button(layer1, p.linkPrimary or p.accent, hover, selected)
    rules.actionbutton.inactivebg = layer1
    rules.actionbutton.inactivefg = p.textDisabled or p.textMuted
    rules.tertiary_btn = button(p.bg, p.buttonTertiary or p.accent, p.buttonTertiaryHover or hover,
        p.buttonTertiaryActive or selected, p.buttonTertiary or p.accent)
    rules.tertiary_btn.hovertext = p.textInverse or p.accentText
    rules.tertiary_btn.pressedtext = p.textInverse or p.accentText
    rules.ghost_btn = button(layer1, p.linkPrimary or p.accent, hover, selected)
    rules.flatbutton = rules.ghost_btn
    rules.button = rules.ghost_btn
    rules.danger_btn = button(p.buttonDangerPrimary or p.error, p.textOnColor or p.accentText,
        p.buttonDangerHover or p.error, p.buttonDangerActive or p.error)
    for _, role in ipairs({ "primary_btn", "actionbutton", "tertiary_btn", "danger_btn" }) do
        rules[role].alignment = "ALEFT:ACENTER"
        rules[role].imageposition = "RIGHT"
        rules[role].spacing = L.px(5)
        rules[role].textRightPadding = L.px(5)
    end
    rules.warning_btn = rules.tertiary_btn
    rules.info_btn = rules.tertiary_btn
    local field = p.field01 or layer1
    for _, role in ipairs({ "text", "multiline", "list", "dropbutton", "dropbutton_quiet" }) do
        rules[role] = { bg = field, fg = p.text, font = p.font,
            hover = p.layerHover01, pressed = field, hovertext = p.text, pressedtext = p.text,
            border = p.borderStrong01 or p.border, borderwidth = 1, borderstyle = "BOTTOM",
            padding = L.margin(5, 0), controlheight = L.px(8), radius = 0,
            focuscolor = p.focus, focusinset = p.focusInset }
    end
    for _, role in ipairs({ "flatrows", "flatrows_plain", "flatlist", "list_plain", "list_bordered", "dropdown_list", "palette_rows" }) do
        local r = rules[role]
        r.selbg, r.seltext, r.selalpha = selected, p.text, "0"
        r.itemradius, r.itemmarker, r.header = 0, p.borderInteractive or p.accent, p.layerAccent01 or selected
        r.hover = hover
        r.padding = L.margin(5, 2)
    end
    for k,v in pairs(rules.list_bordered) do if k ~= "font" then rules.list_mono[k] = v end end
    for _, role in ipairs({ "toggle", "flattoggle", "flattoggle_noborder" }) do
        rules[role].checkbg = p.field01 or layer1
        rules[role].checkfg = p.iconOnColor
        rules[role].checkon = p.iconPrimary or p.text
        rules[role].pressed = selected
        rules[role].pressedtext = p.text
        rules[role].switchoff = p.toggleOff
        rules[role].switchon = p.supportSuccess
        rules[role].switchknob = p.iconOnColor
        rules[role].switchwidth, rules[role].switchheight, rules[role].switchknobsize = L.px(9), L.px(6), 18
    end
    rules.flatsegmented.bg, rules.flatsegmented.selbg = p.layerAccent01 or selected, p.layerSelectedInverse or p.text
    rules.flatsegmented.seltext = p.textInverse or p.accentText
    -- Labels containing vector icons must not inherit the surrounding field padding.
    rules.label.padding = "0x0"
    rules.settings_nav_on.borderstyle = "LEADING"
    rules.settings_nav_on.showborder = true
    rules.settings_nav_on.borderwidth = 3
    rules.settings_nav_on.border = p.borderInteractive or p.accent
    rules.flattabs.tabspadding = L.margin(5, 3)
    rules.flattabs.controlheight = L.px(8)
    rules.flattabs.activeline = p.borderInteractive or p.accent
    rules.flattabs_sub = {}
    for k,v in pairs(rules.flattabs) do rules.flattabs_sub[k] = v end
    rules.flattabs_sub.tabsbg, rules.flattabs_sub.selbg = p.bg, p.bg
    for _, r in pairs(rules) do
        r.radius = 0
        r.carbonstyle = true

    end
    rules.flatsegmented.radius = 4 -- Carbon content switcher is a rounded exception.
    return rules

end

return M
