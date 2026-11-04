--- The host-owned, centralized Settings surface.
--
-- A single instance is created by the host and shown as the "Settings" tab.
-- Extensions do NOT build their own settings tabs -- they register sections here
-- via `HostAPI:addSettings`, and the view lays every section out identically:
--
--     [ Search: ____________________ ]
--     +-- (scrollable) --------------------------------------+
--     | v  Appearance                                        |  <- collapsible
--     | ---------------------------------------------------- |
--     |    Theme                      [ Classic Dark    v ]  |  <- fixed control column
--     |    Interface motion                            [x]   |
--     |    > Motion speed                              [x]   |  <- expandable row
--     | >  Hello Extension                                   |  <- collapsed section
--     +------------------------------------------------------+
--
-- ### Why sections collapse
--
-- Settings is the one surface whose length is decided by how many extensions
-- happen to be installed, and it grows without anyone designing for it. Past
-- three or four extensions the thing a user came for is reliably off-screen, and
-- scrolling past unrelated categories to reach it is the whole cost. Collapsing a
-- category to a single row makes the list of categories itself navigable, which
-- is what Carbon's accordion is for: progressive disclosure of a set whose size
-- is not known in advance.
--
-- Collapse state is persisted per category, so the shape a user arranges survives
-- a restart -- a setting that resets itself is worse than not having it.
--
-- ### Why rows are not full width
--
-- Rows used to be `label .. fill .. widget` across the full width of the window,
-- which put a text field on a maximised display several thousand pixels from its
-- own label. Two things go wrong: the eye cannot reliably associate a label with
-- a control that far away, and a field sized to the window implies its content
-- should be that long. Carbon sizes fields to their expected content and aligns
-- them into a column, so the controls form a vertical line the eye can follow and
-- the label-to-control distance stays constant. `CONTROL_COLUMN` is that column.
--
-- ### Section opts
--
-- Passed to `addSection` / `HostAPI:addSettings`:
--
--     opts.entries = { { label =, description = (opt), widget = (opt) }, ... }
--     opts.widget  = <a single pre-built iup widget>   -- alternative to entries
--     opts.icon    = <Carbon icon name>                -- beside the category in the list
--
-- An entry with a `description` becomes individually expandable; the description
-- is hidden until the row is opened, so a dense list stays scannable and the
-- explanation is one click away rather than permanently in the way.
--
-- @classmod core.ui.SettingsView

local class = require("middleclass")

local L = require("core.lib.CarbonLayout")
local Kit = require("core.ui.Kit")

-- Decorative only. Absent FFI or SVG bridge means no chevrons and a plain text
-- header, which still expands, collapses and reads correctly.
local ok_icon, VectorIcon = pcall(require, "core.ui.VectorIcon")
if not ok_icon then VectorIcon = nil end

local ok_reactor, ThemeReactor = pcall(require, "core.ui.ThemeReactor")
if not ok_reactor then ThemeReactor = nil end

local SettingsView = class("SettingsView")

-- Width of the column every control is laid into, in pixels. Wide enough for a
-- path-length text field plus a Browse button, which is the widest thing any
-- shipped extension puts in a row.
local CONTROL_COLUMN = 300

-- The page: a list of sections beside a column of cards, centred together. The list gives
-- way when a pane is too narrow to hold both.
local NAV_WIDTH = 200
local COLUMN_WIDTH = 900
local NAV_MIN_PAGE = NAV_WIDTH + COLUMN_WIDTH + 64

-- A description up to this long sits under its label for good, wrapped at WRAP_AT.
-- Anything longer (a table of shortcuts, say) stays behind Show details.
local INLINE_DESCRIPTION = 170
local WRAP_AT = 72

-- Chevron edge length in pixels. Carbon's own accordion uses a 16px icon against
-- body text; this matches.
local CHEVRON_PX = 16

-- Rotation applied to `chevron--down.svg` when a section is closed. Negative is
-- counter-clockwise, so the chevron points right -- "there is more this way".
local CHEVRON_CLOSED_DEG = -90

-- Quantisation step, in degrees, for the chevron's rotation during the toggle.
--
-- `VectorIcon` rasterises and caches one bitmap per distinct angle, so animating
-- the rotation continuously at 60 fps would mint a fresh bitmap nearly every
-- frame and cache all of them forever. The step bounds that set.
--
-- 5 degrees, NOT the 15 this started at. The sweep is 90 degrees
-- (`CHEVRON_CLOSED_DEG`), so a 15 degree step allowed the rotation only SEVEN
-- distinct images across the entire animation -- the chevron could not look
-- smooth at any frame rate, because there was nothing further to draw. 5 degrees
-- gives 19, which reads as continuous, and 19 cached 16x16 bitmaps reused for
-- the life of the process is a trivial cost against the flicker it removes.
local CHEVRON_STEP_DEG = 5

-- =======================================================================
-- CONSTRUCTION
-- =======================================================================

--- Create the settings surface.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding (required)
--   * `settings` -- optional `core.classes.SettingsManager`, for persisting which
--     sections are collapsed
--   * `motion` -- optional `core.classes.MotionDirector`, for the expand/collapse
--     animation; without it sections still open and close, instantly
--   * `icon_dir` -- optional directory holding the Carbon SVG icon set
--
-- Also accepts the IUP binding directly as the sole argument, which is how this
-- was originally constructed.
--
-- @tparam table|userdata opts construction options, or the IUP binding
function SettingsView:initialize(opts)
    -- The IUP binding is a table too, so "is this an opts table?" is decided by
    -- the presence of the one field an opts table must always have.
    if type(opts) == "table" and opts.iup ~= nil then
        self._iup      = opts.iup
        self._settings = opts.settings
        self._motion   = opts.motion
        self._icon_dir = opts.icon_dir
    else
        self._iup = opts
    end

    local iup = self._iup
    self._sections = {}   -- ordered list of section records
    self._query    = ""

    local sv = self
    local FlatField = require("core.ui.FlatField")
    local search_field = FlatField.new(iup, {
        cue = "Search settings...",
        icon = self._icon_dir and (self._icon_dir .. "/search.svg") or nil,
        on_change = function(text) sv:filter(text) end,
    })
    self._search = search_field.text
    local search_box = search_field.widget

    -- Inner container holds section headers and bodies (direct children, so each
    -- can be individually shown/hidden + floated during filtering).
    self._inner = iup.vbox{
        GAP     = L.gap(L.ROLE.row_gap),
        MARGIN  = "0x" .. L.px(L.ROLE.row),
        EXPAND  = "HORIZONTAL",
    }

    -- IupFlatLabel explicitly documents BGCOLOR as ignored: "It will use the
    -- background color of the native parent." self._inner is a plain vbox, a
    -- "void" layout container with no real native window, so flatlabels inside it
    -- fall through to whatever native ancestor IUP finds -- which resolves to the
    -- OS default (white), not our themed surface color. Wrapping the vbox in a
    -- themed flatframe (a real owner-drawn native window, same mechanism already
    -- proven to work for the search box above) gives flatlabel children an actual
    -- painted native parent to inherit from.
    self._panel = iup.flatframe{
        self._inner,
        TITLE     = "",
        MARGIN    = L.margin(0),
        EXPAND    = "YES",
        -- A settings row stretched across a maximised display puts the control several
        -- thousand pixels from the label that names it, so the column stops growing.
        MAXSIZE   = L.maxSize(COLUMN_WIDTH, nil),
        THEMEROLE = "settingspanel",
    }
    self._column = iup.vbox{ self._panel, MARGIN = L.margin(L.ROLE.page, 0), EXPAND = "YES" }

    -- iup.flatlabel (owner-drawn), not native iup.label: a native label given an
    -- explicit color loses the OS's transparent-background painting once nested
    -- inside the flatscrollbox below (its custom-drawn viewport doesn't forward
    -- WM_CTLCOLORSTATIC the way a plain vbox/dialog does, and native controls also
    -- don't reliably repaint BGCOLOR set after creation via SetAttribute) --
    -- leaving a solid white box behind the text on dark themes. flatlabel paints
    -- itself directly from BGCOLOR/FGCOLOR every time, like flatbutton/flatframe.
    self._empty = iup.flatlabel{
        TITLE     = "No settings registered. Extensions add their settings here.",
        FLOATING  = "NO",
        FONT      = "Segoe UI, 11",
        THEMEROLE = "settingslabel_muted",
    }
    iup.Append(self._inner, self._empty)

    -- BGCOLOR intentionally omitted here: flatscrollbox is themed directly by
    -- ThemeManager's per-class rule, and hardcoding white would survive theme
    -- switches (this widget is otherwise excluded from re-theming).
    self._scroll = iup.flatscrollbox{
        self._column,
        EXPAND    = "YES",
        SCROLLBAR = "VERTICAL",
        XHIDDEN   = "YES",
    }

    -- BGCOLOR intentionally omitted: vbox is a "void" layout container that
    -- ThemeManager skips re-theming (see ThemeManager's VOID_CONTAINERS comment),
    -- so a hardcoded color here would never update on theme switch. Leaving it
    -- unset lets the color inherit from the dialog, which IS themed.
    self._search_row = iup.hbox{
        iup.hbox{ search_box, MAXSIZE = L.maxSize(COLUMN_WIDTH, nil), EXPAND = "HORIZONTAL" },
        ALIGNMENT = "ACENTER",
        MARGIN    = L.margin(L.ROLE.page, L.ROLE.section),
    }
    self._nav_items = iup.vbox{ GAP = L.gap(1), EXPAND = "HORIZONTAL" }
    self._nav = iup.vbox{
        self._nav_items,
        iup.hbox{ RASTERSIZE = L.size(NAV_WIDTH) },
        MARGIN = "0x" .. L.px(L.ROLE.section),
        EXPAND = "VERTICAL",
    }
    self._lead = iup.fill{ RASTERSIZE = "0x" }
    self._widget = iup.hbox{
        self._lead,
        self._nav,
        iup.vbox{ self._search_row, self._scroll, EXPAND = "YES" },
        EXPAND   = "YES",
        TABTITLE = "Settings",
    }

    -- Chevrons are role-colored, so they have to be re-rendered when the theme
    -- changes. Registering the whole view (rather than each chevron) keeps one
    -- entry in the weak registry regardless of how many sections exist.
    if ThemeReactor then ThemeReactor.register(self) end
end

--- The tab widget to append to the host tab strip.
-- @treturn ihandle
function SettingsView:widget()
    return self._widget
end

--- Fit the page to the width it has: centre list and column together, and give up the
-- list when both won't fit. The scroll area keeps running to the page's edge, so the
-- scrollbar stays there too.
-- @tparam number width
function SettingsView:fitWidth(width)
    local iup = self._iup
    local wide = width >= NAV_MIN_PAGE
    Kit.show(iup, self._nav, wide, self._search)
    local lead = wide and math.floor((width - NAV_WIDTH - COLUMN_WIDTH) / 2) or 1 -- 0 means no size at all
    iup.SetAttribute(self._lead, "RASTERSIZE", lead .. "x")
end

-- Scroll to a section and mark it in the list.
function SettingsView:_goTo(section)
    local iup = self._iup
    for _, other in ipairs(self._sections) do
        iup.SetAttribute(other.nav_btn, "THEMEROLE", other == section and "settings_nav_on" or "settings_nav")
        if self._theme_widget then self._theme_widget(other.nav_btn) end
    end
    iup.SetAttribute(self._scroll, "SCROLLTOCHILD_HANDLE", section.header)
end

--- How to re-theme one widget after its role changes.
function SettingsView:setThemeWidget(fn)
    self._theme_widget = fn
end

-- =======================================================================
-- RELAYOUT
-- =======================================================================
--
-- ### Why this surface does not animate its height
--
-- It used to, and it was the slowest thing in the application. The reason is
-- worth stating exactly, because it is not obvious and two separate attempts to
-- optimise around it failed.
--
-- A layout pass in IUP is `IupRefresh`, and `IupRefresh` DOES NOT SCOPE TO THE
-- WIDGET IT IS GIVEN (iup_layout.c):
--
--     dialog = IupGetDialog(ih);
--     iupLayoutCompute(dialog);
--     iupLayoutUpdate(dialog);
--
-- The argument only selects WHICH DIALOG. And neither half is cheap:
--
--   * `iupBaseComputeNaturalSize` is documented "for containers always compute"
--     -- there is NO caching. Every pass re-measures every container and every
--     label in the dialog, and measuring a label is a GDI text metric call. The
--     cost therefore scales with how many settings rows are registered, which is
--     precisely the number that grows as extensions are added.
--   * `iupLayoutUpdate` then issues a `SetWindowPos` for every widget in the
--     dialog, whether or not it moved.
--
-- Doing that sixty times a second for a 240 ms reveal is thousands of text
-- measurements and tens of thousands of window calls, and it saturates the
-- message queue so thoroughly that the animation's own frames -- delivered on the
-- low-priority `WM_TIMER` -- never get dispatched. The reveal stutters, and the
-- chevron riding on the same frames stutters with it.
--
-- ### Two optimisations that did not work, and why
--
--   * `IupRefreshChildren` is genuinely scoped, but its implementation says
--     "If the container natural size changed from inside, simply ignore the
--     change". It lays children out inside the container's CURRENT size and never
--     lets it grow -- so the reveal became invisible until the final settle
--     snapped it into place.
--   * Rate-limiting the full pass reduced the stutter without removing it, and
--     bought nothing the user could see: a reveal updated a handful of times is
--     not a reveal.
--
-- ### What is done instead
--
-- The height is not animated at all. The body is shown or hidden in ONE layout
-- pass, and the only thing that animates is the chevron -- which is a cached
-- bitmap assigned to a small owner-drawn button, costs a single `RedrawWindow`,
-- and touches no layout whatsoever.
--
-- That is the same thing every other animated icon in this application does
-- (`core.ui.VectorIcon:spin`, the status glyphs, the tab drag caret), and it is
-- why those have always been smooth while this one alone was not. The chevron was
-- never the slow part; it was the only icon bolted to a layout pass.
--
-- The result is a section that opens instantly with a smoothly rotating chevron,
-- which is also simply the more responsive interaction: the content a user
-- clicked for is on screen immediately rather than 240 ms later.

-- Full layout pass, including the scrollbox's scroll range.
--
-- Suppressed while `_batching` is raised so a caller that touches many sections
-- at once (`filter`, on every keystroke) pays for one pass rather than one per
-- section.
function SettingsView:_settle()
    if self._batching then
        self._settle_wanted = true
        return
    end
    pcall(self._iup.Refresh, self._scroll)
end

-- Run `fn` with `_settle` collapsed to a single call at the end.
--
-- Re-entrant, and exception-safe: the flag is always lowered, because leaving it
-- raised would silently suppress every future settle and the page would stop
-- reflowing altogether.
function SettingsView:_batch(fn)
    local depth = (self._batching or 0) + 1
    self._batching = depth

    local ok, err = pcall(fn)

    self._batching = (depth > 1) and (depth - 1) or nil
    if not self._batching and self._settle_wanted then
        self._settle_wanted = nil
        pcall(self._iup.Refresh, self._scroll)
    end

    if not ok then error(err, 0) end
end

--- Attach the shared `core.classes.MotionDirector`.
--
-- Separate from construction because the director is built after this view in
-- the host's startup order. Without one, sections still open and close -- just
-- instantly, which is the same thing the director itself does when the user has
-- motion switched off.
--
-- @tparam MotionDirector director the shared director
function SettingsView:setMotion(director)
    self._motion = director
end

-- =======================================================================
-- CHEVRONS
-- =======================================================================

-- An IUP image handle for the chevron at `degrees`, or nil when icons are off.
-- VectorIcon caches per (size, color, rotation), so repeats cost nothing.
function SettingsView:_chevron(degrees)
    if not (VectorIcon and VectorIcon.available and self._icon_dir) then return nil end
    local ok, handle = pcall(VectorIcon.imageHandle, self._iup, {
        path     = require("core.platform").path:join(self._icon_dir, "chevron--down.svg"),
        size     = CHEVRON_PX,
        color    = VectorIcon.roleColor("neutral"),
        rotation = degrees,
    })
    return ok and handle or nil
end

-- Point a header's chevron at `degrees`, snapped to the quantisation step.
function SettingsView:_setChevron(section, degrees)
    if not section.header_btn then return end
    local snapped = math.floor(degrees / CHEVRON_STEP_DEG + 0.5) * CHEVRON_STEP_DEG
    if section.chevron_deg == snapped then return end
    section.chevron_deg = snapped

    -- `imageHandle` returns a registered handle NAME, not an ihandle, so this is
    -- a plain string attribute set -- the same way VectorIcon binds its own label.
    local handle = self:_chevron(snapped)
    if handle then
        pcall(self._iup.SetAttribute, section.header_btn, "IMAGE", handle)
    end
end

-- Rasterise and cache every angle the toggle animation will ask for.
--
-- Without this the FIRST open of each section rasterises 19 SVGs one at a time,
-- inside `on_frame` -- an `nsvgRasterize` plus a GDI image creation plus an
-- `iup.SetHandle` on the animation's critical path, on the very frames that are
-- meant to be cheap. The cache makes every later toggle free, so the cost was
-- paid exactly once and exactly where it was most visible.
--
-- Cheap to call repeatedly: `VectorIcon.imageHandle` returns immediately for an
-- angle it has already rendered, so this is a no-op after the first section.
function SettingsView:_warmChevrons()
    if self._chevrons_warm then return end
    if not (VectorIcon and VectorIcon.available and self._icon_dir) then return end
    self._chevrons_warm = true

    -- Inclusive of both ends: 0 (fully open) and CHEVRON_CLOSED_DEG (fully
    -- closed) are the two resting states, and every step between them is a frame
    -- the animation will land on.
    local step = (CHEVRON_CLOSED_DEG < 0) and -CHEVRON_STEP_DEG or CHEVRON_STEP_DEG
    for deg = 0, CHEVRON_CLOSED_DEG, step do
        self:_chevron(deg)
    end
end

--- Re-render every chevron after a theme switch.
--
-- Called by `core.ui.ThemeReactor`. Chevrons resolve their color from the active
-- palette at render time and are baked into a bitmap, so unlike a themed widget
-- they do not follow a theme change on their own.
--
-- @local
function SettingsView:_onThemeApply()
    -- The palette decides the chevron's color, and color is part of the
    -- VectorIcon cache key -- so every warmed angle from the previous theme is
    -- now a miss. Re-warm, or the next toggle would rasterise all 19 on the
    -- animation's critical path, which is exactly what the warming exists to
    -- avoid.
    self._chevrons_warm = nil
    self:_warmChevrons()

    for _, section in ipairs(self._sections) do
        local deg = section.chevron_deg
        section.chevron_deg = nil   -- force the re-render past the no-op guard
        self:_setChevron(section, deg or 0)
    end
end

-- =======================================================================
-- BUILDING
-- =======================================================================

-- Build a section's clickable header: chevron, title, and a rule beneath.
function SettingsView:_buildHeader(section, category)
    local iup = self._iup

    -- flatbutton, not a label: it is a control the user clicks, so it needs the
    -- hover feedback and focus behaviour of one. It is also owner-drawn, which
    -- is what lets it carry the chevron image on a themed background inside the
    -- flatscrollbox (see the flatlabel note in the constructor).
    local btn = iup.flatbutton{
        TITLE         = category,
        ALIGNMENT     = "ALEFT:ACENTER",
        EXPAND        = "HORIZONTAL",
        IMAGEPOSITION = "LEFT",
        SPACING       = tostring(L.px(L.ROLE.label_gap)),
        PADDING       = L.margin(1, 3),
        BORDER        = "NO",
        THEMEROLE     = "settingsheader",
    }
    section.header_btn = btn

    local sv = self
    function btn:flat_action()
        sv:toggleSection(section)
        return iup.DEFAULT
    end

    -- More air above a heading than below it, so it reads as opening the card it heads.
    local air = #self._sections > 0 and iup.fill{ RASTERSIZE = "x" .. L.px(L.ROLE.section_gap) } or nil
    return iup.vbox{
        air,
        btn,
        GAP    = L.gap(0),
        MARGIN = L.margin(0),
        EXPAND = "HORIZONTAL",
    }
end

-- Break a description into lines a row can hold.
local function wrap(text)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if line ~= "" and #line + 1 + #word > WRAP_AT then
            lines[#lines + 1] = line
            line = word
        else
            line = line == "" and word or (line .. " " .. word)
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return table.concat(lines, "\n")
end

-- Let a field take the column's width whatever size it was built with: a box is never
-- narrower than what it holds, so a field sized on its own would widen its row and
-- push every other row's edge out of line.
local function release_width(iup, widget)
    if iup.GetClassName(widget) == "text" then
        iup.SetAttribute(widget, "SIZE", nil)
        iup.SetAttribute(widget, "RASTERSIZE", "60x")
        iup.SetAttribute(widget, "EXPAND", "HORIZONTAL")
    end
    if not iup.GetChild then return end
    local i, child = 0, iup.GetChild(widget, 0)
    while child do
        release_width(iup, child)
        i = i + 1
        child = iup.GetChild(widget, i)
    end
end

-- Does this description sit under its label, or behind Show details?
local function inline_description(text)
    return #text <= INLINE_DESCRIPTION and not text:find("\n", 1, true)
end

-- An on/off row reads best as a switch, whose knob slides between its two states.
function SettingsView:_makeSwitch(toggle)
    local iup, view = self._iup, self
    iup.SetAttribute(toggle, "SWITCH", "YES")
    iup.SetAttribute(toggle, "RASTERSIZE", "40x24")
    local changed = toggle.valuechanged_cb
    function toggle:valuechanged_cb()
        local result = changed and changed(self) or iup.DEFAULT
        local motion, on = view._motion, iup.GetAttribute(self, "VALUE") == "ON"
        if motion then
            motion:animate({
                role = "settings_expand", target = self,
                from = on and 0 or 100, to = on and 100 or 0,
                on_frame = function(pos)
                    iup.SetAttribute(self, "SWITCHPOS", tostring(math.floor(pos)))
                    iup.Update(self)
                end,
                on_done = function()
                    iup.ResetAttribute(self, "SWITCHPOS")
                    iup.Update(self)
                end,
            })
        end
        return result
    end
end

-- Build one labelled settings row: name and description on the left, control on the
-- right, in a column whose edge every row in every section shares.
--
-- Returns the row widget, its searchable text, and the description sub-widget that
-- opens and closes (nil unless the description is too long to stay on show).
function SettingsView:_buildRow(entry, category, first)
    local iup = self._iup
    local description = entry.description or ""
    local inline = description ~= "" and inline_description(description)
    local expandable = description ~= "" and not inline

    local label = iup.flatlabel{ TITLE = entry.label or "", THEMEROLE = "settings_name", EXPAND = "HORIZONTAL" }
    local left = { label, GAP = L.gap(1), EXPAND = "HORIZONTAL" }
    if inline then
        left[#left + 1] = iup.flatlabel{ TITLE = wrap(description), THEMEROLE = "settings_description" }
    end

    -- A long description still offers something to press.
    local details_button
    if expandable then
        details_button = iup.flatbutton{ TITLE = "Show details", THEMEROLE = "actionbutton" }
        local view = self
        function details_button:flat_action()
            view:_toggleRow(entry)
            return iup.DEFAULT
        end
    end

    -- A field fills the column; anything else sits on its right edge.
    local control = entry.widget or details_button
    if control and iup.GetClassName(control) == "flattoggle" then self:_makeSwitch(control) end
    local fills = false
    if control and (iup.GetClassName(control) == "flatframe" or iup.GetClassName(control) == "hbox") then
        iup.SetAttribute(control, "EXPAND", "HORIZONTAL")
        iup.SetAttribute(control, "RASTERSIZE", nil)
        fills = true
        release_width(iup, control)
    end
    -- The empty box holds the column at its width. A width set on the row itself would
    -- count as the row's natural size and leave nothing for the field to expand into.
    local cells = { ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }
    if control and not fills then cells[#cells + 1] = iup.fill{} end
    if control then cells[#cells + 1] = control end
    local column = iup.vbox{
        iup.hbox(cells),
        iup.hbox{ RASTERSIZE = L.size(CONTROL_COLUMN) },
        EXPAND = "NO",
    }

    local top = iup.hbox{
        iup.vbox(left),
        column,
        ALIGNMENT = "ACENTER",
        GAP       = L.gap(L.ROLE.section),
        EXPAND    = "HORIZONTAL",
    }

    local children = {}
    if not first then
        children[1] = iup.flatseparator{ ORIENTATION = "HORIZONTAL", STYLE = "LINE", BARSIZE = "1" }
    end
    children[#children + 1] = iup.vbox{ top, MARGIN = L.margin(L.ROLE.section, 3), EXPAND = "HORIZONTAL" }
    local desc
    if expandable then
        desc = iup.flatlabel{ TITLE = description, THEMEROLE = "settings_description" }
        -- Hidden until the row is opened. FLOATING as well as VISIBLE so the
        -- collapsed row takes exactly the height of its control and the rows
        -- above and below close up against it.
        iup.SetAttribute(desc, "FLOATING", "YES")
        iup.SetAttribute(desc, "VISIBLE", "NO")
        children[#children + 1] = iup.vbox{ desc, MARGIN = L.margin(L.ROLE.section, 0), EXPAND = "HORIZONTAL" }
    end
    children.GAP    = L.gap(0)
    children.MARGIN = L.margin(0)
    children.EXPAND = "HORIZONTAL"

    local box = iup.vbox(children)

    local text = ((entry.label or "") .. " " ..
                  (entry.description or "") .. " " .. category):lower()
    return box, text, desc
end

--- Add a category section.
--
-- @tparam string category Section title, shown in the header.
-- @tparam[opt] table opts `entries` and/or `widget` (see the module header).
-- @tparam[opt] boolean mapped True when the view is already on screen, so newly
--   created widgets must be mapped now; when false, `IupShow` maps them later.
-- @treturn table A section record, to be handed back to `removeSection`.
function SettingsView:addSection(category, opts, mapped)
    local iup = self._iup
    opts = opts or {}

    if self._empty then
        iup.SetAttribute(self._empty, "VISIBLE", "NO")
        iup.SetAttribute(self._empty, "FLOATING", "YES")
    end

    local section = {
        category = category,
        rows     = {},
        widgets  = {},
        open     = true,
    }

    local sv = self
    local nav_btn = iup.flatbutton{
        TITLE = category, ALIGNMENT = "ALEFT:ACENTER", EXPAND = "HORIZONTAL",
        THEMEROLE = (#self._sections == 0) and "settings_nav_on" or "settings_nav",
    }
    if opts.icon then Kit.iconize(iup, { { nav_btn, opts.icon } }) end
    function nav_btn:flat_action()
        sv:_goTo(section)
        return iup.DEFAULT
    end
    section.nav_btn = nav_btn
    iup.Append(self._nav_items, nav_btn)
    section.widgets[#section.widgets + 1] = nav_btn

    local header = self:_buildHeader(section, category)
    iup.Append(self._inner, header)
    section.header = header
    section.widgets[#section.widgets + 1] = header

    -- Every row lives inside one clipping container, so opening and closing the
    -- section is a single height animation rather than a per-row cascade -- and
    -- rows that scroll out of the shrinking container are clipped by the native
    -- window rather than spilling over their neighbours.
    local body_inner = iup.vbox{
        GAP    = L.gap(0),
        MARGIN = L.margin(0),
        EXPAND = "HORIZONTAL",
    }
    local body = iup.flatframe{
        body_inner,
        TITLE     = "",
        MARGIN    = L.margin(0),
        EXPAND    = "HORIZONTAL",
        THEMEROLE = "settingscard",
    }
    section.body       = body
    section.body_inner = body_inner
    iup.Append(self._inner, body)
    section.widgets[#section.widgets + 1] = body

    for index, entry in ipairs(opts.entries or {}) do
        local box, text, desc = self:_buildRow(entry, category, index == 1)
        iup.Append(body_inner, box)
        -- Stashed on the entry so `_toggleRow` can find it from the click
        -- handler, which is the only thing that ever holds the entry.
        if desc then entry._desc = desc end
        section.rows[#section.rows + 1] = { box = box, text = text, entry = entry }
    end

    if opts.widget then
        iup.Append(body_inner, opts.widget)
        section.rows[#section.rows + 1] = { box = opts.widget, text = category:lower() }
    end

    self._sections[#self._sections + 1] = section

    if mapped then
        for _, w in ipairs(section.widgets) do iup.Map(w) end
        self:_settle()
    end

    -- Restore the collapsed state the user left this category in. Done after the
    -- map so the natural height is measurable; `instant` skips the animation,
    -- since a section that was already closed should not be seen closing.
    --
    -- Warmed first: `_setOpen` may start an animation that immediately begins
    -- asking for rotated chevrons, and the point is to have them ready before
    -- any frame needs one.
    self:_warmChevrons()
    if self:_storedCollapsed(category) then
        self:_setOpen(section, false, true)
    else
        self:_setChevron(section, 0)
    end

    return section
end

--- Remove a previously added section (used on extension unload/reload).
-- @tparam table section The record returned by `addSection`.
function SettingsView:removeSection(section)
    local iup = self._iup
    for i, s in ipairs(self._sections) do
        if s == section then table.remove(self._sections, i); break end
    end
    if self._motion then
        pcall(function() self._motion:cancel({ target = section.body }) end)
    end
    for _, w in ipairs(section.widgets) do
        iup.Detach(w)
        iup.Destroy(w)
    end
    if #self._sections == 0 and self._empty then
        iup.SetAttribute(self._empty, "VISIBLE", "YES")
        iup.SetAttribute(self._empty, "FLOATING", "NO")
    end
    self:_settle()
end

-- =======================================================================
-- COLLAPSING
-- =======================================================================

-- Settings key for a category's collapsed flag. Namespaced under the host rather
-- than the extension, because this is the host's view of the extension's section
-- and survives the extension being unloaded.
local function collapse_key(category)
    return "settings.collapsed." .. tostring(category)
end

function SettingsView:_storedCollapsed(category)
    if not self._settings then return false end
    local ok, v = pcall(function() return self._settings:get(collapse_key(category)) end)
    return ok and v == true
end

function SettingsView:_storeCollapsed(category, collapsed)
    if not self._settings then return end
    pcall(function()
        self._settings:set(collapse_key(category), collapsed and true or nil)
        self._settings:save()
    end)
end

--- Open or close a section.
--
-- The body is shown or hidden in a single layout pass; only the chevron
-- animates. See the RELAYOUT block for why a height animation is not viable on
-- this surface.
--
-- @tparam table section Section record.
-- @tparam boolean open True to expand.
-- @tparam[opt] boolean instant Skip the chevron animation and land immediately.
function SettingsView:_setOpen(section, open, instant)
    local iup = self._iup
    -- No-op when already in the requested state, instant or not. `filter` runs on
    -- every keystroke across every section, and without this each character typed
    -- would re-measure and re-lay-out the entire settings tree.
    if section.open == open then return end
    section.open = open

    -- A closed body is FLOATING as well as hidden: a hidden widget still
    -- participates in layout and still contributes its parent's GAP, which would
    -- leave a visible gutter under every collapsed section.
    iup.SetAttribute(section.body, "FLOATING", open and "NO" or "YES")
    iup.SetAttribute(section.body, "VISIBLE", open and "YES" or "NO")
    -- Never left pinned, or the section could not grow when an extension adds a
    -- row later. (Older builds animated this attribute; nothing sets it now, but
    -- clearing it keeps a section opened by one of those builds honest.)
    iup.SetAttribute(section.body, "RASTERSIZE", nil)

    -- The one and only layout pass for this toggle.
    self:_settle()

    if instant or not self._motion then
        self:_setChevron(section, open and 0 or CHEVRON_CLOSED_DEG)
        return
    end

    -- Every rotation this animation will ask for, rasterised and cached before
    -- the first frame rather than during it. Done here rather than only at
    -- construction because the chevron's colour comes from the active theme, and
    -- the theme active NOW is the one whose bitmaps are needed.
    self:_warmChevrons()

    local sv = self
    local from = open and CHEVRON_CLOSED_DEG or 0
    local to   = open and 0 or CHEVRON_CLOSED_DEG

    self._motion:animate({
        role   = open and "settings_expand" or "settings_collapse",
        -- A fixed rotation, so a fixed duration: the chevron sweeps the same 90
        -- degrees whether the section holds two rows or twenty. Passing
        -- `distance` here would scale the duration by the section's height, which
        -- is no longer what is moving.
        target = section.body,
        from   = from,
        to     = to,
        -- The whole frame: one cached bitmap onto one small button. No layout, no
        -- measurement -- which is exactly what every other animated icon in the
        -- application does, and why they have always been smooth.
        on_frame = function(deg) sv:_setChevron(section, deg) end,
        on_done  = function() sv:_setChevron(section, to) end,
    })
end

--- Toggle a section open or closed, persisting the new state.
-- @tparam table section Section record.
function SettingsView:toggleSection(section)
    local open = not section.open
    self:_setOpen(section, open)
    self:_storeCollapsed(section.category, not open)
end

-- Toggle a single row's description.
--
-- Carbon's *semantic consistency*: this and a section header are the same gesture
-- with the same meaning -- reveal content hidden in a seam -- so they must behave
-- the same way. Since a section no longer animates its height (see RELAYOUT), a
-- row does not either; both reveal in one layout pass. A row that slid open next
-- to a section that appeared instantly would read as two unrelated mechanisms.
function SettingsView:_toggleRow(entry)
    local desc = entry._desc
    if not desc then return end

    local iup = self._iup
    local opening = (iup.GetAttribute(desc, "FLOATING") ~= "NO")

    iup.SetAttribute(desc, "FLOATING", opening and "NO" or "YES")
    iup.SetAttribute(desc, "VISIBLE", opening and "YES" or "NO")
    iup.SetAttribute(desc, "RASTERSIZE", nil)

    self:_settle()
end

-- =======================================================================
-- FILTERING
-- =======================================================================

--- Live filter by label, description and category.
--
-- An empty query restores every section to the collapse state the user chose. A
-- non-empty one force-expands any section holding a match and hides the rest --
-- a search that leaves its results collapsed has not found anything as far as
-- the user is concerned.
--
-- @tparam string query Search text; empty or whitespace clears the filter.
function SettingsView:filter(query)
    local iup = self._iup
    query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local searching = (query ~= "")
    self._query = query

    -- Batched because this runs on EVERY KEYSTROKE and touches every section.
    -- Each `_setOpen(..., instant)` below settles the scrollbox, and a settle is
    -- a full-dialog relayout -- so an unbatched pass cost one relayout per
    -- section plus one for the trailing settle, i.e. N+1 per character typed.
    -- Collapsed here to exactly one.
    self:_batch(function()
        for _, section in ipairs(self._sections) do
            local any = false
            for _, row in ipairs(section.rows) do
                local show = (not searching) or (row.text:find(query, 1, true) ~= nil)
                iup.SetAttribute(row.box, "FLOATING", show and "NO" or "YES")
                iup.SetAttribute(row.box, "VISIBLE",  show and "YES" or "NO")
                if show then any = true end
            end

            local show_header = (not searching) or any
            iup.SetAttribute(section.header, "FLOATING", show_header and "NO" or "YES")
            iup.SetAttribute(section.header, "VISIBLE",  show_header and "YES" or "NO")

            -- While searching, matches are shown regardless of collapse state; once
            -- the query clears, the user's own arrangement comes back. Instant in
            -- both directions -- this fires on every keystroke, and an animation per
            -- character typed is exactly the motion Carbon says to remove. Note this
            -- deliberately does NOT persist: a search borrows a section open, it does
            -- not rewrite what the user chose.
            local open = searching and any or
                (not searching and not self:_storedCollapsed(section.category))
            self:_setOpen(section, open, true)
        end

        -- Unconditional: rows change visibility on every keystroke even when no
        -- section changed its open state, so the settle cannot be left to
        -- `_setOpen` (which no-ops when already in the requested state).
        self:_settle()
    end)
end

return SettingsView
