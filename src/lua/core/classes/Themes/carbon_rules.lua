-- carbon_rules.lua
-- Shared, token-driven rules() builder for the IBM Carbon Design System themes
-- (White, Gray 10, Gray 90, Gray 100). This is intentionally a plain module -- NOT a
-- Theme subclass -- so ThemeManager's auto-discovery (which only instantiates
-- Theme subclasses under core.classes.Themes.*) skips it.
--
-- Every Carbon theme differs only in its color tokens; the mapping of those tokens
-- onto widget roles is identical and lives here. This mirrors the exact role-key set
-- used by the app so no widget is left unstyled, while
-- following Carbon's own language: subtle gray borders, a single blue (or brand)
-- interactive accent for selection/links, layered surfaces, and semantic support colors.
--
-- The three surface states are distinct:
--
--   * `p.layerHover01`    -- $layer-hover-01: pointer-enter feedback, slightly lighter
--   * `p.layerSelected01` -- $layer-selected-01: persistent selection, visibly darker
--   * `p.layer02`         -- $layer-02: elevation step, the raised surface itself
--
-- Making hover, selection, and elevation the same color is what made the old themes
-- feel flat and muddled: a hovered-but-not-selected item looked selected, and a
-- second-level surface looked like a selection. Each state now resolves to its own
-- token, and `p.surface2` is kept as a backward-compat alias for `layerHover01` so
-- no external consumer breaks.
--
-- Expected palette tokens (all "R G B" strings unless noted):
--   bg              $background
--   layer01         $layer-01 / $field-01
--   layer02         $layer-02 / $field-02
--   layerHover01    $layer-hover-01       (pointer-enter feedback on layer-01)
--   layerSelected01 $layer-selected-01    (persistent selection on layer-01)
--   borderSubtle01  $border-subtle-01
--   borderStrong01  $border-strong-01
--   text            $text-primary
--   textMuted       $text-secondary
--   textOnColor     $text-on-color
--   accent          $interactive
--   accentText      same as textOnColor (text rendered on accent fill)
--   error/success/warning/warningText/info  ($support-*)
--   font            IUP font string  (e.g. "IBM Plex Sans, 10")
--
-- Legacy aliases (set by each theme's initialize()):
--   surface      = layer01          surface2     = layerHover01
--   border       = borderSubtle01   borderStrong = borderStrong01
--   listBg       = layer01          listText     = text
--   listSelText  = accent

local L = require("core.lib.CarbonLayout")

local M = {}

--- Convert a "#rrggbb" (or "rrggbb") hex string to IUP's "R G B" decimal form.
-- @tparam string hex Six-digit hex color, with or without the leading `#`.
-- @treturn string `"R G B"` decimal string.
function M.rgb(hex)
    hex = hex:gsub("#", "")
    return string.format("%d %d %d",
        tonumber(hex:sub(1, 2), 16),
        tonumber(hex:sub(3, 4), 16),
        tonumber(hex:sub(5, 6), 16))
end

-- Re-size a theme's IUP font string, keeping its family.
--
-- Carbon's type scale is a set of sizes and weights applied to one typeface, so a
-- heading must be the theme's own family at a larger size -- not a second font
-- named somewhere else. Parsing the family out of the palette's font string is
-- what lets a theme's headings come out in its own typeface without the palette
-- having to carry a separate entry per heading level.
--
-- Point sizes follow Carbon's productive type scale at 96 DPI (pt = px * 0.75):
--
--   label-01 / helper-text-01  12px → 9pt
--   body-01 / body-compact-01  14px → 10.5pt → 11pt
--     IUP font sizes are integers, so 10.5pt must round to either 10 or 11.
--     Carbon's guidance treats "too small" as the worse failure mode (legibility
--     before pixel-precision), so 11pt is chosen over 10pt.
--   heading-compact-01         14px semibold → 11pt Bold
--   heading-03                 20px → 15pt
--   heading-04                 28px → 21pt
local function sized(font, points, bold)
    local family = tostring(font or "Segoe UI"):match("^%s*([^,]+)") or "Segoe UI"
    return string.format("%s, %s%d", family, bold and "Bold " or "", points)
end

--- Build the full widget rule table from a Carbon palette.
--
-- Consumes the expanded token set introduced in Work Item 1 while maintaining
-- full backward compatibility with callers that built palettes using only the
-- legacy six-key set (`bg`, `surface`, `surface2`, `border`, …).
--
-- @tparam table p Palette table. See module header for the full token list.
-- @treturn table Widget class/role → style mapping.
function M.build(p)
    -- Carbon's `$field-01` button height, expressed as padding because that is
    -- the only lever IUP gives a theme over a flat control's size. 12px above and
    -- below a ~15px line of body text lands on Carbon's 40px control; 16px either
    -- side is `$spacing-05`, the same step the page margins use, so a button's
    -- label lines up with the content column beside it.
    --
    -- 40 rather than the 48 of `$field-02`: the host's dialogs are built to fixed
    -- heights and a 48px button overflows the smaller ones. `CarbonLayout.CARBON`
    -- carries both, so a surface that wants the full-size target can ask for it.
    local BTN_PAD = string.format("%dx%d", L.SPACING[5], 12)

    -- Carbon's `$field-01` text-input height (40px). IUP's text/multiline/list
    -- controls have no explicit height attribute that the theme layer can set, but
    -- PADDING is respected: vertical padding of $spacing-04 (12px) around a
    -- ~15px body line approximates the 40px target without pinning a raster size
    -- that would break multi-line fields.
    --
    -- `L.CARBON.input_height` is the canonical value; the padding is derived
    -- from it so this stays in step if the constant ever changes.
    local FIELD_PAD = string.format("0x%d", math.floor((L.CARBON.input_height - 16) / 2))
    -- Resolve each semantic use to the right token. Falling back to the legacy
    -- aliases means a palette that was built before the token expansion still
    -- produces correct (if slightly less differentiated) output.
    local hover    = p.layerHover01    or p.surface2
    local selected = p.layerSelected01 or p.surface2
    local elevated = p.layer02         or p.surface2
    local layer1   = p.layer01        or p.surface

    return {
        -- Type scale. Owner-drawn flatlabels, so these follow the theme rather
        -- than baking a literal color the way the extensions' own headings used
        -- to -- which is why a dark-blue page title survived onto a dark theme.
        --
        -- heading-04 (21pt) for the page title; heading-03 (15pt) for section
        -- headings; body-compact-01 (11pt) for subtitles; label-01 (9pt) for
        -- helper text. All semibold weights are expressed as Bold in IUP.
        pagetitle     = { fg = p.text,      font = sized(p.font, 21, true) },
        pagesubtitle  = { fg = p.textMuted, font = sized(p.font, 11) },
        sectiontitle  = { fg = p.text,      font = sized(p.font, 15, true) },
        hint          = { fg = p.textMuted, font = sized(p.font, 9) },

        -- UI shell header. Carbon's shell sits on $background -- the darkest
        -- surface in the theme -- while the content below it sits on $layer-01, so
        -- the band reads as the floor the application stands on rather than as
        -- another panel. That inversion is the point: everywhere else in Carbon a
        -- raised element is lighter, and the shell is the one thing that is not
        -- raised at all.
        --
        -- The product name is split across two labels so the brand can be
        -- semibold and the product name regular, which is Carbon's own shell
        -- treatment. One typeface, two weights -- never two families.
        shellheader   = { bg = p.bg, fg = p.text, border = p.borderSubtle01 or p.border, borderwidth = 1 },
        -- Zero padding on the two name labels so the only space between them is
        -- the box's own GAP. IupFlatLabel pads itself by default, which on a
        -- two-part product name reads as a stray double space rather than as one
        -- name in two weights.
        shellbrand    = { bg = p.bg, fg = p.text, font = sized(p.font, 11, true), padding = "0x0" },
        shellproduct  = { bg = p.bg, fg = p.text, font = sized(p.font, 11), padding = "0x0" },
        -- Version, right-aligned. $text-secondary: present for when it is wanted,
        -- never competing with the product name for the eye.
        shellmeta     = { bg = p.bg, fg = p.textMuted, font = sized(p.font, 9), padding = "0x0" },
        -- The strip above the tabs: Carbon draws none, so it takes the shell's floor.
        accentstrip   = { bg = p.bg },

        -- Notifications (core.ui.Toast): Carbon's low-contrast toast, a raised
        -- surface with a bar in the kind's support colour down the left edge. The
        -- toast sets its own fonts.
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
        split         = { bg = p.bg,     fg = p.text, border = p.border },
        frame         = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        flatframe     = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        flatseparator = { bg = p.bg, border = p.border },
        tabs          = { bg = p.bg,     fg = p.text, font = p.font, border = p.border },
        -- hover/selbg drive the tab strip's trailing "extra" buttons (the host's
        -- "+ new tab group"). Without them IupFlatTabs falls back to its own
        -- IUP_FLAT_HIGHCOLOR/PRESSCOLOR, which are blue regardless of theme.
        -- hover is $layer-hover-01 and selbg is $layer-selected-01: Carbon
        -- distinguishes "the pointer is over this" from "this is the one that is
        -- chosen", and collapsing them is what made every hover in the old palette
        -- look like a selection.
        --
        -- Carbon's *contained tabs*. The selected tab sits on $layer-01 -- the same
        -- surface as the page below it, so the two read as one continuous
        -- container -- while the strip itself is $background. That contrast is
        -- what marks the selection; the published 3px $border-interactive bar is
        -- not reachable, because IupFlatTabs exposes no accent-bar attribute and
        -- patching the vendored fork to add one is far more than this is worth.
        --
        -- Unselected labels drop to $text-secondary so the selected tab wins on
        -- both fill and text weight rather than relying on either alone.
        flattabs      = {
            bg = layer1, fg = p.text, font = p.font,
            tabsbg = p.bg, tabsfg = p.textMuted,
            border = p.border, borderwidth = 1,
            hover = hover, selbg = selected,
        },
        scrollbox     = { bg = layer1, fg = p.text, border = p.border },
        flatscrollbox = { bg = layer1, fg = p.text, border = p.border, borderwidth = 1 },
        -- Invisible scroll host that HostAPI:addTab wraps every tab in, so content
        -- taller than the window scrolls instead of being clipped off the bottom.
        -- It must disappear visually: dialog background, no border.
        tabscroll     = { bg = p.bg, fg = p.text, border = p.bg, borderwidth = 0 },
        label         = { fg = p.text,    font = p.font },
        settingslabel       = { fg = p.text,      font = p.font },
        settingslabel_muted = { fg = p.textMuted, font = p.font },
        settingspanel = { bg = layer1 },
        -- Collapsible section header in the Settings tab. Carbon's accordion
        -- header is a full-width button that reads as a heading at rest and only
        -- reveals itself as interactive on hover, so it carries no border and no
        -- fill of its own -- it sits on the panel surface until the pointer
        -- arrives, then takes $layer-hover-01 (not $layer-selected-01, because
        -- the header is not persistently selected, it is momentarily lit up).
        settingsheader = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0,
            hover = hover, hovertext = p.text,
        },
        -- The label of a settings row that has a description to reveal. Same
        -- borderless-until-hovered contract as the section header, in body rather
        -- than heading color, so an expandable row is indistinguishable from a
        -- plain one at rest and obviously clickable under the pointer.
        settingsrow = {
            bg = layer1, fg = p.text, font = p.font,
            border = layer1, borderwidth = 0,
            hover = hover, hovertext = p.accent,
        },
        separator     = { bg = p.bg, border = p.border },
        button        = { fg = p.text, font = p.font },
        flatbutton    = { bg = layer1, fg = p.text, font = p.font },
        -- Action buttons follow Carbon's tertiary/ghost button: transparent fill with
        -- a blue accent outline + label; hovering fills the button with the accent and
        -- inverts the label to text-on-color.
        actionbutton  = {
            bg = p.bg, fg = p.text, font = p.font,
            border = p.accent, borderwidth = 1, showborder = true, padding = BTN_PAD,
            hover = p.accent, hovertext = p.accentText,
        },
        -- Semantic buttons (primary, warning, danger, info): Carbon-tertiary baseline (accent outline), then
        -- the relevant $support-* color fills on hover.
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
        -- Dropbutton sits on an elevated surface ($layer-02), uses $layer-hover-01
        -- for pointer-enter since hovering should feel lighter than the pressed state.
        dropbutton    = {
            bg = elevated, fg = p.text, font = p.font,
            border = p.border, borderwidth = 1, showborder = true,
            hover = hover, hovertext = p.text,
        },
        -- Dropdown list opens into an elevated container; selected row takes
        -- $layer-selected-01 so the chosen item reads as persistently active.
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
        -- Carbon draws text inputs on $field-01 with a single strong bottom edge
        -- ($border-strong-01), not the four-sided subtle box that a native Win32
        -- edit would use. A true bottom-only border is not expressible through
        -- IUP's BORDERCOLOR/BORDERWIDTH (which apply to all four sides uniformly)
        -- and cannot be reached from the theme layer without wrapping every text
        -- widget in a flatframe that supplies the underline -- a widget-construction
        -- change this module deliberately avoids. The minimum honest improvement is
        -- therefore to use $border-strong-01 so fields read as fields at all; on
        -- Gray 100 the subtle border ($border-subtle-01, #393939) is nearly
        -- invisible against $layer-01 (#262626) and makes fields look like vague
        -- dark rectangles rather than input targets.
        --
        -- PADDING adds the vertical room Carbon's 40px ($field-01 / input_height)
        -- targets require; the horizontal pad is zero so the IUP layout's own
        -- MARGIN drives horizontal inset, not the control itself.
        text      = { bg = layer1, fg = p.text, font = p.font,
                      border = p.borderStrong01 or p.borderStrong or p.border,
                      padding = FIELD_PAD },
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
        progressbar   = { bg = layer1, fg = p.accent, border = p.border },
        gauge         = { bg = layer1, fg = p.accent, border = p.border },
    }
end

return M
