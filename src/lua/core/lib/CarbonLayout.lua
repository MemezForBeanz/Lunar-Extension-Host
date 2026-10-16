--- IBM Carbon Design System spacing scale and layout vocabulary.
--
-- The counterpart to `core.lib.MotionTokens`: that module is the single source of
-- truth for how things move, this one for how far apart they sit. Like it, this is
-- **data plus arithmetic only** -- it never touches IUP or FFI, so the whole
-- spacing vocabulary is testable under plain busted.
--
-- ### Why tokens rather than literals
--
-- Spacing read off a designer's eye drifts. Before this module the app used
-- eighteen distinct `MARGIN` values and sixteen distinct `GAP` values, most of them
-- differing by a pixel or two from a neighbour for no reason anyone could recover.
-- Carbon's answer is a fixed scale built from multiples of two, four and eight: two
-- elements are either at the same step or at a visibly different one, and there is
-- no in-between to argue about.
--
-- Deviating from the scale should be rare enough to be worth a comment.
--
-- ### Using it
--
--     local L = require("core.lib.CarbonLayout")
--
--     iup.vbox{ ..., MARGIN = L.margin(5), GAP = L.gap(3) }   --> "16x16", "8"
--     iup.hbox{ ..., MARGIN = L.margin(5, 3) }                --> "16x8"
--
-- Steps are referred to by their Carbon token number throughout, so `L.margin(5)`
-- is `$spacing-05` and can be checked against the published scale directly.
--
-- @module core.lib.CarbonLayout

local M = {}

--- The Carbon spacing scale, in pixels, indexed by token number.
--
-- Mirrors <https://carbondesignsystem.com/elements/spacing/overview/> exactly.
-- Carbon publishes these in rem against a 16px root; this app is a native desktop
-- UI with no root font size, so the pixel column is what is stored.
--
--   * `01` 2px    * `02` 4px    * `03` 8px    * `04` 12px
--   * `05` 16px   * `06` 24px   * `07` 32px   * `08` 40px
--   * `09` 48px   * `10` 64px   * `11` 80px   * `12` 96px
--   * `13` 160px
M.SPACING = {
	[1] = 2,
	[2] = 4,
	[3] = 8,
	[4] = 12,
	[5] = 16,
	[6] = 24,
	[7] = 32,
	[8] = 40,
	[9] = 48,
	[10] = 64,
	[11] = 80,
	[12] = 96,
	[13] = 160,
}

local SPACING = M.SPACING
local MAX_STEP = 13

--- Pixels for a spacing step.
--
-- Accepts a token number (`5`), or a raw pixel count when the value is off-scale.
-- Off-scale values pass through untouched rather than snapping, because the few
-- legitimate exceptions -- matching a native control's own metrics, say -- would be
-- silently broken by rounding them onto the scale.
--
-- @tparam[opt=0] number step Carbon token number 1-13, or a pixel count above 13.
-- @treturn number Pixels.
-- @usage L.px(5)   --> 16
function M.px(step)
	step = tonumber(step) or 0
	if step <= 0 then return 0 end
	if step <= MAX_STEP and step == math.floor(step) then
		return SPACING[step]
	end
	return step
end

--- An IUP `MARGIN` string from one or two spacing steps.
--
-- IUP takes margins as `"HORIZONTALxVERTICAL"` pixels. Passing a single step gives
-- a uniform margin; passing two sets the axes independently, which is the common
-- case for a row that wants generous side padding and tight vertical rhythm.
--
-- @tparam[opt=0] number h Horizontal spacing step.
-- @tparam[opt=h] number v Vertical spacing step.
-- @treturn string `"HxV"`, ready for `MARGIN`.
-- @usage iup.vbox{ ..., MARGIN = L.margin(5) }      -- "16x16"
-- @usage iup.hbox{ ..., MARGIN = L.margin(5, 3) }   -- "16x8"
function M.margin(h, v)
	local x = M.px(h)
	local y = (v == nil) and x or M.px(v)
	return string.format("%dx%d", x, y)
end

--- An IUP `GAP` string from a spacing step.
--
-- Carbon's `Stack` component sets the distance between siblings from the same
-- scale as margins, so gaps and margins stay in the same rhythm.
--
-- @tparam[opt=0] number step Spacing step.
-- @treturn string Pixels as a string, ready for `GAP`.
-- @usage iup.vbox{ ..., GAP = L.gap(3) }   -- "8"
function M.gap(step)
	return tostring(M.px(step))
end

--- An IUP `RASTERSIZE` string, with either dimension optional.
--
-- An omitted axis is emitted as **`0`**, not as an empty string. IUP documents `0`
-- as "measure this axis naturally", which is how a control gets a fixed width
-- while still sizing its own height -- but its parser wants two integers and
-- **rejects the whole attribute** if either is missing. `"640x"` therefore does not
-- set a width of 640 and leave the height free; it sets nothing at all, silently,
-- and the widget stays free to size itself in both directions.
--
-- That cost an afternoon: a settings row column and a page header block both
-- looked like they had been given a width and neither had, so they stretched to
-- fill the window and took the layout around them with them.
--
-- @tparam[opt] number w Width in pixels (not a spacing step); `nil` means natural.
-- @tparam[opt] number h Height in pixels; `nil` means natural.
-- @treturn string `"WxH"`, with `0` for any omitted axis.
-- @usage iup.text{ ..., RASTERSIZE = L.size(L.FIELD.default) }   -- "288x0"
function M.size(w, h)
	return string.format("%dx%d",
		w and math.floor(w) or 0,
		h and math.floor(h) or 0)
end

--- An IUP `MAXSIZE` string capping one axis and leaving the other unbounded.
--
-- The companion to `size` for the cases where a widget must not grow past a limit
-- but must still be free to be smaller -- a content column on a wide monitor, a
-- header band that must never steal height from the content below it.
--
-- The unbounded axis is emitted as IUP's 65535 sentinel rather than 0, because
-- `MAXSIZE` reads 0 as "maximum of zero" and would collapse the widget entirely.
--
-- @tparam[opt] number w Maximum width in pixels; `nil` for unbounded.
-- @tparam[opt] number h Maximum height in pixels; `nil` for unbounded.
-- @treturn string `"WxH"`.
-- @usage iup.hbox{ ..., MAXSIZE = L.maxSize(nil, 120) }   -- "65535x120"
function M.maxSize(w, h)
	local UNBOUNDED = 65535
	return string.format("%dx%d",
		w and math.floor(w) or UNBOUNDED,
		h and math.floor(h) or UNBOUNDED)
end

--- Named layout roles, so intent is stated once rather than at each call site.
--
-- These are the handful of decisions that would otherwise be re-made (and re-made
-- differently) in every panel. Each is a spacing step, not a pixel count, so they
-- read against the scale.
--
--   * `page` -- outermost padding of an extension's tab content
--   * `section` -- padding inside a grouped section of related controls
--   * `section_gap` -- distance between two such sections
--   * `row` -- padding inside one labelled control row
--   * `row_gap` -- distance between rows in the same section
--   * `inline_gap` -- distance between controls sitting side by side
--   * `label_gap` -- distance between a label and the control it names
M.ROLE = {
	page        = 5,   -- 16px
	section     = 5,   -- 16px
	section_gap = 6,   -- 24px
	row         = 3,   -- 8px
	row_gap     = 2,   -- 4px
	inline_gap  = 3,   -- 8px
	label_gap   = 2,   -- 4px
}

--- Standard control widths, in pixels.
--
-- Carbon sizes form fields to their expected content rather than letting them
-- stretch: a field wider than its longest plausible value reads as an invitation
-- to type more than the field wants, and a row of full-width fields gives the eye
-- no column to follow down the form.
--
-- These are pixel counts, not spacing steps -- they are content measurements, and
-- the spacing scale does not extend usefully past 160px.
--
--   * `narrow` -- toggles, small numeric entry
--   * `short` -- a dropdown of short options
--   * `default` -- the standard single-line text field
--   * `wide` -- paths and other long single-line values
M.FIELD = {
	narrow  = 96,
	short   = 176,
	default = 288,
	wide    = 400,
}

--- Maximum content width for a page, in pixels.
--
-- Text and form content set to the full width of a maximised 4K window is
-- unreadable -- the eye loses the line it was on between the right edge and the
-- start of the next. Carbon's grid caps content rather than letting it span, and
-- the host's `addTab` already accepts a `max_content_width` for exactly this.
--
--   * `form` -- settings and other label/control content
--   * `reading` -- prose and documentation
--   * `dense` -- tables, logs and lists, which genuinely use the width
M.CONTENT_MAX = {
	form    = 880,
	reading = 640,
	dense   = 1400,
}

--- Carbon component metrics — pixel heights and widths that give components
-- their Carbon character.
--
-- The reference is <https://carbondesignsystem.com/components/> (accessed 2026).
-- Every value carries its Carbon token or component spec so the number can be
-- checked against the published table directly.
--
--   * `button_default`    48px  -- `$field-02` height; the full-size interactive
--                                  target Carbon requires for primary actions
--   * `button_sm`         40px  -- `$field-01` height; compact context (toolbars)
--   * `input_height`      40px  -- Text input height (`$field-01`); Carbon inputs
--                                  sit 40px tall with a bottom border only, not
--                                  a full box, which is what separates them from
--                                  native Win32 text fields visually
--   * `table_row`         48px  -- Default data-table row height; matches
--                                  `button_default` so an action cell never
--                                  clips its button
--   * `table_row_compact` 40px  -- Compact row; matches `button_sm`
--   * `tab_height`        40px  -- Tab item height; the 3px selected indicator
--                                  lives at the bottom of this zone
--   * `tab_indicator`      3px  -- Selected-tab underline width (Carbon: 3px
--                                  `$border-interactive`); thinner than a native
--                                  tab's full bottom border so it reads as a
--                                  dot of color, not a frame edge
--   * `sidenav_item`      48px  -- Side-nav row height; the 4px accent leading
--                                  edge is painted inside this zone
--   * `sidenav_accent`     4px  -- Leading-edge accent bar on a selected nav item
--   * `tile_padding`      16px  -- Internal tile padding (`$spacing-05`); kept on
--                                  the spacing scale so tile content aligns with
--                                  page margins set at the same step
--
-- `shell_header` (48px) is deliberately ABSENT. Carbon publishes it, but its shell
-- header carries the navigation, the actions and the account menu -- 48px is
-- working space there. This app has a native Win32 menu bar directly above its
-- band, which holds nothing but a product name, so the token would have bought a
-- third of an inch of empty grey above every screen. It is not listed rather than
-- listed-and-unused, because a constant nothing reads is worse than no constant.
M.CARBON = {
	button_default    = 48,
	button_sm         = 40,
	input_height      = 40,
	table_row         = 48,
	table_row_compact = 40,
	tab_height        = 40,
	tab_indicator     = 3,
	sidenav_item      = 48,
	sidenav_accent    = 4,
	tile_padding      = SPACING[5],  -- 16px = $spacing-05
}

-- =======================================================================
-- BUILDERS
-- =======================================================================
--
-- IUP is taken as an argument rather than required, so this module stays pure
-- data plus arithmetic and the whole file remains loadable (and testable) under
-- plain busted with no GUI toolkit present.
--
-- Every builder below produces owner-drawn widgets tagged with a THEMEROLE, never
-- widgets carrying literal colors or fonts. A page title with a hardcoded
-- `FGCOLOR` looks correct in exactly the theme it was written against and wrong in
-- every other one, which is how the shipped extensions ended up with dark-blue
-- headings on a dark background.

--- A page title: the name of the surface the user is looking at.
-- @tparam userdata iup the IUP binding
-- @tparam string text title text
-- @treturn ihandle
function M.pageTitle(iup, text)
	return iup.flatlabel{ TITLE = text or "", THEMEROLE = "pagetitle" }
end

--- A page subtitle: one line saying what the surface is for.
-- @tparam userdata iup the IUP binding
-- @tparam string text subtitle text
-- @treturn ihandle
function M.pageSubtitle(iup, text)
	return iup.flatlabel{ TITLE = text or "", THEMEROLE = "pagesubtitle" }
end

--- A section heading within a page.
-- @tparam userdata iup the IUP binding
-- @tparam string text heading text
-- @treturn ihandle
function M.sectionTitle(iup, text)
	return iup.flatlabel{ TITLE = text or "", THEMEROLE = "sectiontitle" }
end

--- Secondary helper text sitting under a control.
-- @tparam userdata iup the IUP binding
-- @tparam string text hint text
-- @treturn ihandle
function M.hint(iup, text)
	return iup.flatlabel{ TITLE = text or "", THEMEROLE = "hint" }
end

--- Title and optional subtitle, spaced as one block.
--
-- Carbon gives a page header more surrounding space than anything below it,
-- which is what makes it read as the top of a hierarchy rather than as the first
-- item in a list.
--
-- @tparam userdata iup the IUP binding
-- @tparam string title
-- @tparam[opt] string subtitle
-- @treturn ihandle A vbox.
function M.pageHeader(iup, title, subtitle)
	local kids = { M.pageTitle(iup, title) }
	if subtitle and subtitle ~= "" then
		kids[#kids + 1] = M.pageSubtitle(iup, subtitle)
	end
	kids.GAP    = M.gap(M.ROLE.label_gap)
	kids.MARGIN = M.margin(0)
	kids.EXPAND = "HORIZONTAL"
	return iup.vbox(kids)
end

--- A vertical stack with a tokenized gap -- Carbon's `Stack` component.
--
-- Delegating the spacing between siblings to their parent, rather than giving
-- each child a margin of its own, is what keeps a layout adjustable from one
-- place. `children` may carry any additional IUP attributes.
--
-- @tparam userdata iup the IUP binding
-- @tparam table children array of widgets, plus optional IUP attributes
-- @tparam[opt=ROLE.row_gap] number step spacing step between children
-- @treturn ihandle A vbox.
function M.stack(iup, children, step)
	children.GAP    = children.GAP or M.gap(step or M.ROLE.row_gap)
	children.MARGIN = children.MARGIN or M.margin(0)
	-- An expanding child overrides its own raster width in IUP's layout pass, so
	-- a caller who pinned a width means it -- defaulting EXPAND on would silently
	-- stretch the stack back across the window and make RASTERSIZE do nothing.
	if children.EXPAND == nil and children.RASTERSIZE == nil then
		children.EXPAND = "HORIZONTAL"
	end
	return iup.vbox(children)
end

--- A horizontal stack with a tokenized gap, vertically centered.
-- @tparam userdata iup the IUP binding
-- @tparam table children array of widgets, plus optional IUP attributes
-- @tparam[opt=ROLE.inline_gap] number step spacing step between children
-- @treturn ihandle An hbox.
function M.row(iup, children, step)
	children.GAP       = children.GAP or M.gap(step or M.ROLE.inline_gap)
	children.ALIGNMENT = children.ALIGNMENT or "ACENTER"
	return iup.hbox(children)
end

--- The outermost container of an extension's tab content.
--
-- Applies the page padding and the distance between top-level sections in one
-- place, so every extension's content starts at the same inset and breathes at
-- the same rate.
--
-- @tparam userdata iup the IUP binding
-- @tparam table children array of widgets, plus optional IUP attributes
-- @treturn ihandle A vbox.
function M.page(iup, children)
	children.MARGIN = children.MARGIN or M.margin(M.ROLE.page)
	children.GAP    = children.GAP or M.gap(M.ROLE.section_gap)
	return iup.vbox(children)
end

--- Snap an arbitrary pixel value to the nearest step on the scale.
--
-- For migrating existing literals: it reports what a hand-tuned value should have
-- been. Ties round up, so a value sitting exactly between two steps gets the more
-- generous one -- Carbon treats too-tight spacing as the worse failure.
--
-- @tparam number pixels Any pixel count.
-- @treturn number The nearest token number, 1-13.
-- @treturn number That token's pixel value.
-- @usage local step, px = L.nearest(10)   --> 4, 12
function M.nearest(pixels)
	pixels = tonumber(pixels) or 0
	local best, best_d = 1, math.huge
	for step = 1, MAX_STEP do
		local d = math.abs(SPACING[step] - pixels)
		-- `<=` rather than `<`: later steps are larger, so a tie hands the win to
		-- the more generous one.
		if d <= best_d then best, best_d = step, d end
	end
	return best, SPACING[best]
end

--- The pixel width of a gutter seam between chrome bands.
--
-- The visual rigidity that characterises Carbon's shell layouts comes from narrow
-- strips of the page background showing through between surface bands -- not from
-- drawn borders. A 1-2px gap reads as structure rather than decoration, and
-- because the gap is the background showing through rather than a painted line,
-- it adapts to any theme automatically.
--
-- Used in the host chrome to give the shell header, accent strip, tab strip and
-- status bar each a 2px seam of `$background` between them, which is the Carbon
-- shell treatment.
--
-- `step` is a spacing-scale step. The natural choices are:
--
--   * `1` (2px) -- the tightest seam; bands read as nearly flush while the grid
--                  is still visible when the surface and background differ by one
--                  tone. This is the default because Carbon's reference layouts
--                  almost always use it.
--   * `2` (4px) -- a slightly more open seam, appropriate when the surface and
--                  background tones are close enough that the 2px gap disappears
--                  on lower-contrast displays.
--
-- @tparam[opt=1] number step Spacing step, usually 1 (2px) or 2 (4px).
-- @treturn number Pixel width of the seam.
-- @usage L.gutter()    --> 2
-- @usage L.gutter(2)   --> 4
function M.gutter(step)
	step = (step == nil) and 1 or step
	return M.px(step)
end

return M
