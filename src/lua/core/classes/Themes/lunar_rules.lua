-- lunar_rules.lua
-- Shared, token-driven rules() builder for Lunar's own design language (Lunar
-- Dark / Lunar Light): Carbon's structure and role discipline, Obsidian's dim
-- lines and soft depth, VS Code's selective rounding. Like carbon_rules and
-- fluent_rules this is a plain module -- NOT a Theme subclass -- so
-- ThemeManager's auto-discovery skips it.
--
-- The language, in four rules:
--
--   1. DIM LINES. Structural borders are one step above the surface they sit
--      on (`borderSubtle01`) -- visible, never loud. Vivid color is reserved
--      for interactive emphasis: the primary action's fill, a semantic
--      button's outline, selection.
--   2. GENEROUS, LIT ROUNDING. Interactive controls get a 6px radius and
--      container surfaces (frames, lists, panes) 10px, and the corners of a
--      container catch a little light (`sheen`, fork patch 0005). CORNERRADIUS
--      exists only on the fork-patched flat classes, so rules never emit a
--      radius a class cannot honour (ThemeManager also guards this).
--   3. SOFT GRADIENTS, SPARINGLY. The shell header and the accent strip carry
--      the only gradients. Buttons are flat fills: the fork keeps
--      GRADIENTCOLOR fixed while HLCOLOR fills on hover, so a gradient button
--      muddies its own hover state.
--   4. STATES ARE STEPS. Rest, hover and pressed are three distinct steps of
--      the same ramp (hover one step lighter, pressed one step darker), via
--      the `pressed`/`pressedtext` rule keys ThemeManager maps to PSCOLOR.
--
-- Button hierarchy (every button in the app is one of these):
--   primary_btn   the page's main verb: solid accent fill, at most one per page
--   actionbutton  standard action: raised surface + dim border
--   ghost_btn     inline row action: borderless, reveals itself on hover
--   danger_btn / warning_btn / info_btn
--                 semantic outline at rest, semantic fill on hover
--
-- Expected palette tokens (all "R G B" strings unless noted): the carbon_rules
-- token set (bg, layer01, layer02, layerHover01, layerSelected01,
-- borderSubtle01, borderStrong01, text, textMuted, accent, accentText,
-- error/success/warning/warningText/info, font) plus `accentHover`,
-- `accentPressed`, `gradTop`, `gradBottom`, and the numbers `radius` (controls)
-- and `radiusFrame` (frames).

local fluent = require("core.classes.Themes.fluent_rules")
local shade = fluent.shade

local M = {}

M.rgb = fluent.rgb

-- Carbon's productive type scale, same rationale as carbon_rules.sized: one
-- family, several sizes/weights, never a second typeface.
local function sized(font, points, bold)
    local family = tostring(font or "Segoe UI"):match("^%s*([^,]+)") or "Segoe UI"
    return string.format("%s, %s%d", family, bold and "Bold " or "", points)
end
M.sized = sized

--- Build the full widget rule table from a Lunar palette.
-- Covers every role carbon_rules.build emits (so no widget is left unstyled on
-- a theme switch) plus the roles introduced with this language: `ghost_btn`,
-- `statusbar`, `statusbar_text`, `error_label`, `success_label`,
-- `warning_label`, `info_label`, `mono`, `mono_hint`.
-- @tparam table p Palette table; see the module header for the token list.
-- @treturn table Widget class/role -> style mapping.
function M.build(p)
    local hover    = p.layerHover01    or p.surface2
    local selected = p.layerSelected01 or p.surface2
    local elevated = p.layer02         or p.surface2
    local layer1   = p.layer01         or p.surface
    local border   = p.borderSubtle01  or p.border
    local borderS  = p.borderStrong01  or p.borderStrong or border

    local R  = p.radius or 6        -- interactive controls
    local RF = p.radiusFrame or 10  -- container surfaces
    -- The lit corners: a step past the strong border, so they read as light on
    -- the edge and not as a brighter outline.
    local sheen = p.sheen or shade(borderS, 0.22)
    -- Where content sits: a step recessed from the page, so a list or a field reads by
    -- its fill and the outline can stay faint.
    local well = p.well or p.bg
    local chosen = p.accentSoft or selected
    -- The flat scrollbar: a quiet rounded thumb on no track, no arrows. The
    -- accent is for what the user can act on, so it is kept for the pressed
    -- thumb instead of every scrollbar at rest.
    local function scroll(rule)
        rule.scrollsize  = 8
        rule.scrollinset = rule.radius and math.floor(rule.radius / 2) + 1 or 2
        rule.scrollfg    = borderS
        rule.scrollhi    = p.textMuted
        rule.scrollpress = p.accent
        return rule
    end

    -- Buttons at VS Code / Obsidian scale, not Carbon's 40px target: a ~15px
    -- body line plus 5px above and below lands on a ~27px control, and 12px
    -- sides keep the label snug instead of floating in a slab. The label is
    -- the body font -- text and control are proportionate again, which is the
    -- real fix for "undersized text on oversized buttons".
    local BTN_FONT = p.font
    local BTN_PAD  = "12x4"
    local accent_hover   = p.accentHover   or shade(p.accent, 0.12)
    local accent_pressed = p.accentPressed or shade(p.accent, -0.14)

    -- A semantic button is a standard button at rest; only its text carries the
    -- meaning, and the colour fills in on hover. Coloured outlines at rest made every
    -- toolbar a row of competing signals.
    local function semantic(color, text_on)
        return {
            bg = elevated, fg = color, font = BTN_FONT,
            border = border, borderwidth = 1, showborder = true,
            padding = BTN_PAD, radius = R,
            hover = color, hovertext = text_on,
            pressed = shade(color, -0.15), pressedtext = text_on,
        }
    end

    local rules = {
        -- Type scale (identical to carbon_rules: heading-04 / heading-03 /
        -- body-compact-01 / label-01).
        pagetitle     = { fg = p.text,      font = sized(p.font, 18, true), padding = "0x0" },
        pagesubtitle  = { fg = p.textMuted, font = sized(p.font, 11), padding = "0x0" },
        sectiontitle  = { fg = p.text,      font = sized(p.font, 12, true), padding = "0x0" },
        hint          = { fg = p.textMuted, font = sized(p.font, 10), padding = "0x0" },

        -- Semantic text roles: state colored by meaning, never by literal.
        error_label   = { fg = p.error,   font = p.font },
        success_label = { fg = p.success, font = p.font },
        warning_label = { fg = p.warning, font = p.font },
        info_label    = { fg = p.info,    font = p.font },
        mono          = { fg = p.text,      font = "Consolas, 10" },
        mono_hint     = { fg = p.textMuted, font = "Consolas, 9" },

        -- Shell. The one soft gradient surface: the app's floor shades gently
        -- darker toward the content, Obsidian-style depth without a drawn line.
        shellheader   = { bg = p.bg, fg = p.text, border = border, borderwidth = 1,
                          gradcolor = p.gradShell or shade(p.bg, -0.05) },
        shellbrand    = { bg = p.bg, fg = p.text, font = sized(p.font, 10, true), padding = "0x0" },
        shellproduct  = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 10), padding = "0x0" },
        shellmeta     = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 9), padding = "0x0" },
        -- The 4px band under the header: the signature sweep, violet into
        -- slate, horizontal because the band is only a few pixels tall.
        accentstrip   = { bg = p.gradTop or p.accent, gradcolor = p.gradBottom or p.bg,
                          graddir = "HORIZONTAL" },

        -- The bottom status bar, finally a themed surface instead of a
        -- hardcoded gray: the shell's floor color with muted text.
        statusbar      = { bg = p.bg, fg = p.textMuted, border = border },
        statusbar_text = { bg = p.bg, fg = p.text, font = sized(p.font, 10) },

        -- Toasts: elevated surface, semantic bar on the left edge.
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
            hover = hover, hovertext = p.text, pressed = selected },

        -- Containers and structure: dim 1px lines on the app background.
        dialog        = { bg = p.bg,     fg = p.text, font = p.font, border = border },
        canvas        = { bg = p.bg,     fg = p.text, border = border },
        vbox          = { bg = p.bg,     fg = p.text, font = p.font },
        hbox          = { bg = p.bg,     fg = p.text, font = p.font },
        zbox          = { bg = p.bg,     fg = p.text, font = p.font },
        cbox          = { bg = p.bg,     fg = p.text, font = p.font },
        gridbox       = { bg = p.bg,     fg = p.text, font = p.font },
        split         = { bg = p.bg,     fg = p.text, border = border, sash = p.accent, barsize = 7 },
        frame         = { bg = p.bg,     fg = p.text, font = p.font, border = border },
        flatframe     = { bg = layer1,   fg = p.text, font = p.font, border = border, radius = RF,
                          sheen = sheen, titlealign = "ALEFT", titlepad = "12x4" },
        flatseparator = { bg = p.bg, border = border },
        tabs          = { bg = p.bg,     fg = p.text, font = p.font, border = border },
        -- The tab strip: a well one step DARKER than the app floor, so the
        -- selected tab -- filled with the page surface and rounded on top --
        -- reads as a raised card the way Obsidian's active tab does. The
        -- square dotted focus rectangle is suppressed: it redraws the card as
        -- a sharp box and tabs are reachable by click and shortcut anyway.
        flattabs      = {
            bg = layer1, fg = p.text, font = p.font,
            tabsbg = p.gradShellWell or shade(p.bg, -0.35), tabsfg = p.textMuted,
            border = border, borderwidth = 1,
            hover = hover, selbg = selected,
            radius = R, focusfeedback = false, showlines = false,
            tabspadding = "12x6",
        },
        -- The bar inside a group: the tool level, so it sits on the page itself and only
        -- the chosen label changes, where the app-level bar above it is a dark well.
        flattabs_sub = {
            bg = layer1, fg = p.text, font = p.font, activeline = p.accent,
            tabsbg = layer1, tabsfg = p.textMuted,
            border = border, borderwidth = 1,
            hover = hover, selbg = selected,
            radius = R, focusfeedback = false, showlines = false,
            tabspadding = "12x6",
        },
        scrollbox     = { bg = layer1, fg = p.text, border = border },
        flatscrollbox = scroll({ bg = layer1, fg = p.text, border = border, borderwidth = 1, scrollbg = layer1 }),
        tabscroll     = scroll({ bg = layer1, fg = p.text, border = layer1, borderwidth = 0, scrollbg = layer1 }),
        label         = { fg = p.text, font = p.font },
        settingslabel       = { fg = p.text,      font = p.font },
        settingslabel_muted = { fg = p.textMuted, font = p.font },
        settingspanel = { bg = layer1, border = layer1, borderwidth = 0, radius = 0 },
        settingsheader = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0, radius = R,
            hover = hover, hovertext = p.text, pressed = selected,
        },
        settingsrow = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0, radius = R,
            hover = hover, hovertext = p.accent, pressed = selected,
        },
        separator     = { bg = p.bg, border = border },

        -- Buttons (see the hierarchy in the module header).
        button        = { fg = p.text, font = p.font },
        flatbutton    = { bg = layer1, fg = p.text, font = p.font, radius = R },
        primary_btn   = {
            bg = p.accent, fg = p.accentText, font = BTN_FONT,
            border = p.accent, borderwidth = 1, showborder = true,
            padding = BTN_PAD, radius = R,
            hover = accent_hover,   hovertext = p.accentText,
            pressed = accent_pressed, pressedtext = p.accentText,
        },
        actionbutton  = {
            bg = elevated, fg = p.text, font = BTN_FONT,
            border = border, borderwidth = 1, showborder = true,
            padding = BTN_PAD, radius = R,
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        ghost_btn     = {
            bg = layer1, fg = p.textMuted, font = p.font,
            border = layer1, borderwidth = 0,
            padding = "8x3", radius = R,
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        -- Hyperlink button (VS Code's link, Obsidian's clickable text): accent
        -- text, never a fill or border; hover brightens, press deepens.
        link_btn      = {
            bg = layer1, fg = p.accent, font = p.font,
            border = layer1, borderwidth = 0, padding = "2x1",
            hover = layer1, hovertext = accent_hover,
            pressed = layer1, pressedtext = accent_pressed,
        },
        -- Icon button: a square, quiet target for glyph-only actions ("...",
        -- close, chevrons) -- invisible at rest, a soft rounded fill on hover.
        icon_btn      = {
            bg = layer1, fg = p.textMuted, font = p.font,
            border = layer1, borderwidth = 0, padding = "4x4", radius = R,
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        danger_btn    = semantic(p.error, p.accentText),
        warning_btn   = {
            bg = elevated, fg = p.text, font = BTN_FONT,
            border = border, borderwidth = 1, showborder = true,
            padding = BTN_PAD, radius = R,
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        info_btn      = {
            bg = elevated, fg = p.text, font = BTN_FONT,
            border = border, borderwidth = 1, showborder = true,
            padding = BTN_PAD, radius = R,
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        dropbutton    = {
            bg = elevated, fg = p.text, font = p.font,
            border = border, borderwidth = 1, showborder = true, radius = R,
            padding = "10x4",
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        dropdown_list = {
            bg = elevated, fg = p.text, font = p.font,
            border = border, borderwidth = 1, radius = R,
            scrollbg = elevated, scrollfg = borderS,
            selbg = chosen, seltext = p.text, selalpha = "0",
        },

        -- Lists and data panes: square by design (rule 2).
        list_bordered = scroll({
            bg = well, fg = p.text, font = p.font, border = border, borderwidth = 1, radius = RF,
            scrollbg = well, sheen = sheen, itemradius = R,
            selbg = chosen, seltext = p.text, selalpha = "0",
        }),
        list_plain    = scroll({
            bg = layer1, fg = p.text, font = p.font, border = layer1, borderwidth = 0,
            scrollbg = layer1, itemradius = R,
            selbg = chosen, seltext = p.text, selalpha = "0",
        }),
        outputlog     = {
            bg = well, fg = p.text, border = well,
            scrollbg = well, scrollfg = borderS,
        },
        outputlog_scroll = scroll({
            bg = well, fg = p.text, border = well, borderwidth = 0,
            scrollbg = well,
        }),
        list_bordered_scroll = scroll({
            bg = well, fg = p.text, border = well, borderwidth = 0,
            scrollbg = well,
        }),
        toggle        = { fg = p.text, font = p.font },
        flattoggle    = { bg = layer1, fg = p.text, font = p.font, radius = R,
            checkbg = elevated, checkfg = borderS, checkhl = p.textMuted, checkon = p.accent },
        flattoggle_noborder = { bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0, radius = R,
            checkbg = elevated, checkfg = borderS, checkhl = p.textMuted, checkon = p.accent },

        -- Fields: a dim box on the raised surface; the strong border marks the
        -- input edge the way VS Code's inputs read against their panels. The
        -- flatframe wrappers extensions put around text fields take `text` as
        -- their THEMEROLE, so the radius here rounds the wrapper (flatframe
        -- honours it) while the native field inside ignores it.
        text      = { bg = well, fg = p.text, font = p.font, border = border, radius = R },
        multiline = { bg = well, fg = p.text, font = p.font, border = border, padding = "0x6" },
        list      = { bg = layer1, fg = p.text, font = p.font, border = borderS, padding = "0x6" },
        flatlist      = scroll({
            bg = well, fg = p.text, font = p.font,
            border = border, borderwidth = 1, radius = RF, sheen = sheen,
            scrollbg = well, itemradius = R,
            selbg = chosen, seltext = p.text, selalpha = "0",
        }),
        -- A field edge in focus. core.ui.FlatField swaps its frame to this role.
        text_cue = { bg = well, fg = p.textMuted, font = p.font },
        text_focus = { bg = well, fg = p.text, font = p.font, border = p.accent, radius = R },
        -- The bottom bar's command bar: reads as a recessed field, not a button.
        commandbar = {
            bg = well, fg = p.text, font = sized(p.font, 10),
            border = border, borderwidth = 1, showborder = true, radius = R,
            padding = "12x6",
            hover = hover, hovertext = p.text,
            pressed = selected, pressedtext = p.text,
        },
        palette_text = { bg = elevated, fg = p.text, font = sized(p.font, 12) },
        palette_hint = { bg = elevated, fg = p.textMuted, font = sized(p.font, 10) },
        snap_preview = { bg = p.accent, fg = p.accent, border = p.accent },
        palette_frame = { bg = elevated, fg = p.text, font = p.font, border = borderS,
                          radius = RF, sheen = sheen },
        palette_list = scroll({
            bg = elevated, fg = p.text, font = p.font, border = elevated, borderwidth = 0,
            radius = R, scrollbg = elevated, itemradius = R,
            selbg = chosen, seltext = p.text, selalpha = "0",
        }),
        progressbar   = { bg = layer1, fg = p.accent, border = border },
        -- An idle gauge is invisible: the track matches the page, so only real progress shows.
        gauge         = { bg = layer1, fg = p.accent, border = layer1, notext = true },
    }
    -- Roles replace class rules: preserve the entire bordered-list definition.
    rules.list_mono = {}
    for key, value in pairs(rules.list_bordered) do rules.list_mono[key] = value end
    rules.list_mono.font = "Consolas, 9"
    for _, role in ipairs({ "flatbutton", "primary_btn", "actionbutton", "ghost_btn",
                            "danger_btn", "warning_btn", "info_btn", "link_btn", "icon_btn" }) do
        rules[role].inactivebg = elevated
        rules[role].inactivefg = p.textMuted
    end
    return rules
end

return M
