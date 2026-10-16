--- Multi-select IUP list with mouse drag-to-reorder, per-row colouring, and an optional right-click menu.
-- Backed by a single native IUP (flat)list; any number of items is supported efficiently.
-- A horizontal insertion-line indicator shows the drop position during a drag.
--
-- For any extension that needs an ordered, reorderable, selectable list.
--
-- **Construction options** (`ReorderableList:new(iup, opts)`):
--
-- * `opts.format` `function(entry) -> string` *(required)* — row display text.
-- * `opts.color` `function(entry) -> "r g b"|nil` — per-row foreground color.
-- * `opts.image` `function(entry) -> string|nil` — per-row IUP image handle name.
-- * `opts.reorderable` `boolean` (default `true`) — enable drag-to-reorder.
-- * `opts.on_reorder` `function(from, to)` — called after a drag move completes.
-- * `opts.menu` `ContextMenu|items-spec` — optional right-click context menu.
-- * `opts.on_context` `function(pos)` — called before the context menu pops.
-- * `opts.on_activate` `function(exclusive)` — user interacted with the list (focus hint);
--   `exclusive` is `true` for a plain (non Ctrl/Shift) click.
-- * `opts.tooltip` `function(entry) -> string|nil` — hover tooltip per row.
-- * `opts.role` `string` — `BQROLE` tag for focus routing.
-- * `opts.visiblelines` `string|number` (default `"8"`) — visible row count.
-- * `opts.font` `string` (default `"Consolas, 9"`) — list font.
-- * `opts.flat` `boolean` — use `iup.flatlist` instead of `iup.list`.
-- * `opts.indicator` `string` — drop-line display text.
-- * `opts.outer_scroll` `boolean` — wrap in a `flatscrollbox` for external scroll.
-- * `opts.border` `boolean` (default `true`) — render the native etched border.
-- * `opts.motion` `core.classes.MotionDirector|nil` — optional director for staggered entrance
--   animation when entries are loaded via `setEntries`. Omit for instant behaviour.
--
-- @usage
--   local ReorderableList = require("core.ui.ReorderableList")
--   local list = ReorderableList:new(iup, {
--       format = function(e) return e.name end,
--       color  = function(e) return e.active and "0 0 0" or "160 160 160" end,
--       on_reorder = function(from, to)
--           print("moved from " .. from .. " to " .. to)
--       end,
--   })
--   list:setEntries({ {name="Alpha"}, {name="Beta"} })
--   vbox:append(list:widget())
-- @classmod core.ui.ReorderableList

local class = require("middleclass")
local ContextMenu = require("core.ui.ContextMenu")
local Theme = require("core.classes.Theme")
local ListEntrance = require("core.ui.ListEntrance")

local ReorderableList = class("ReorderableList")

local DEFAULT_INDICATOR = "--------------------  drop here  --------------------"
local INDICATOR_COLOR   = "0 90 200"

--- Create a new ReorderableList.
-- @tparam userdata iup The IUP library reference.
-- @tparam table opts Construction options (see module description).
-- @treturn ReorderableList New instance.
function ReorderableList:initialize(iup, opts)
    opts = opts or {}
    assert(type(opts.format) == "function", "ReorderableList requires opts.format")
    self._iup        = iup
    self._format     = opts.format
    self._color      = opts.color
    self._image      = opts.image
    self._reorder    = opts.reorderable ~= false
    self._on_reorder = opts.on_reorder
    self._on_context = opts.on_context
    self._on_activate = opts.on_activate
    self._tooltip_fn = opts.tooltip
    self._role       = opts.role
    self._indicator  = opts.indicator or DEFAULT_INDICATOR
    self._entries    = {}
    self._outer_scroll = opts.outer_scroll == true
    self._motion     = opts.motion or nil

    local list_attrs = {
        EXPAND       = "YES",
        MULTIPLE     = "YES",
        VISIBLELINES = tostring(opts.visiblelines or "8"),
        FONT         = Theme.color("font", opts.font or "Consolas, 9"),
    }
    if self._outer_scroll then list_attrs.SCROLLBAR = "NO" end
    -- Drop the native etched border when the list lives inside a themed frame, so
    -- the frame's (recolorable) border is the only visible outline rather than a
    -- white native border sitting inside a green frame.
    if opts.border == false then list_attrs.BORDER = "NO" end
    self._list = (opts.flat and iup.flatlist or iup.list)(list_attrs)
    if self._role then
        iup.SetAttribute(self._list, "BQROLE", self._role)
        iup.SetAttribute(self._list, "THEMEROLE", self._role)
    end
    -- Optional per-row icon: opts.image(entry) -> registered IUP image handle name
    -- (or nil for no icon). Enables SHOWIMAGE so the list reserves an icon column.
    if self._image then
        iup.SetAttribute(self._list, "SHOWIMAGE", "YES")
    end
    if self._outer_scroll then
        self._widget = iup.flatscrollbox{
            self._list,
            EXPAND = "YES",
            SCROLLBAR = "VERTICAL",
        }
        if self._role then
            iup.SetAttribute(self._widget, "THEMEROLE", self._role .. "_scroll")
            iup.SetAttribute(self._widget, "BQROLE", self._role)
        end
    else
        self._widget = self._list
    end

    -- Optional right-click menu (accept a ContextMenu or a raw items spec).
    if opts.menu then
        if type(opts.menu) == "table" and opts.menu.isInstanceOf
           and opts.menu:isInstanceOf(ContextMenu) then
            self._menu = opts.menu
        else
            self._menu = ContextMenu:new(iup, opts.menu)
        end
    end

    -- Drag state (see button_cb/motion_cb below).
    self._drag_from      = nil
    self._drag_active    = false
    self._drag_row_top   = nil
    self._drag_row_h     = nil
    self._drag_gap_shown = nil

    self:_installCallbacks()
end

-- ---------------------------------------------------------------------------
-- Model / display
-- ---------------------------------------------------------------------------

--- Return the IUP widget handle to add to a layout.
-- @treturn userdata IUP list (or flatscrollbox wrapper when `opts.outer_scroll` was set).
function ReorderableList:widget() return self._widget end

--- Return a live reference to the backing entry array.
-- @treturn table The array; modifications are reflected immediately on the next `refresh()`.
function ReorderableList:entries() return self._entries end

--- Replace the backing entry array and redraw all rows.
-- When a director was supplied at construction, the list widget enters with a
-- height-grow animation so the population reads as a content arrival rather
-- than a hard swap. `refresh()` itself is not animated — only `setEntries`
-- triggers the entrance, because a reorder or in-place update should not
-- replay the cascade.
-- @tparam table t New array of entry objects.
function ReorderableList:setEntries(t)
    self._entries = t or {}
    self:refresh()
    -- Animate the whole list widget as a single staggered entrance so the
    -- load reads as a content arrival. The list is one IUP widget (not one
    -- per row), so we pass it as a 1-element array. No explicit container
    -- needed: ListEntrance falls back to refreshing the widget itself, which
    -- is correct for a self-contained list.
    if self._motion and #self._entries > 0 then
        ListEntrance.play(self._motion, { self._list })
    end
end

--- Append a single entry to the end of the list and refresh.
-- @param entry An entry object accepted by the `opts.format` function.
function ReorderableList:append(entry)
    self._entries[#self._entries + 1] = entry
    self:refresh()
end

--- Return the number of entries in the list.
-- @treturn number Entry count.
function ReorderableList:count() return #self._entries end

--- Rebuild all rows from the current entry array.
-- Clears and repopulates the IUP list; reapplies per-row colors and images.
function ReorderableList:refresh()
    local iup = self._iup
    iup.SetAttribute(self._list, "REMOVEITEM", "ALL")
    if self._outer_scroll then
        iup.SetAttribute(self._list, "VISIBLELINES", tostring(math.max(1, #self._entries)))
    end
    for i, entry in ipairs(self._entries) do
        iup.SetAttribute(self._list, "APPENDITEM", self._format(entry))
        local color = (self._color and self._color(entry)) or Theme.color("listText", "0 0 0")
        iup.SetAttributeId(self._list, "FGCOLOR", i, color)
        if self._image then
            iup.SetAttributeId(self._list, "IMAGE", i, self._image(entry))
        end
    end
    if self._outer_scroll then iup.Refresh(self._widget) end
end

--- Refresh a single row's text and color in place.
-- More efficient than a full `refresh()` when only one entry has changed.
-- @tparam number i 1-based row index.
function ReorderableList:refreshItem(i)
    local iup   = self._iup
    local entry = self._entries[i]
    if not entry then return end
    iup.SetAttributeId(self._list, "", i, self._format(entry))
    local color = (self._color and self._color(entry)) or Theme.color("listText", "0 0 0")
    iup.SetAttributeId(self._list, "FGCOLOR", i, color)
    if self._image then
        iup.SetAttributeId(self._list, "IMAGE", i, self._image(entry))
    end
end

--- Re-evaluate and re-apply the per-row image for rows matching a predicate.
-- Cheap enough for a timer-driven animation (e.g. a spinner on the active row)
-- without rebuilding the whole list.
-- @tparam[opt] function pred `pred(entry) -> bool`; `nil` updates all rows.
function ReorderableList:updateImages(pred)
    if not self._image then return end
    for i, entry in ipairs(self._entries) do
        if (not pred) or pred(entry) then
            self._iup.SetAttributeId(self._list, "IMAGE", i, self._image(entry))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Selection (MULTIPLE list VALUE is a "+/-" string)
-- ---------------------------------------------------------------------------

--- Return the 1-based positions of all selected rows.
-- @treturn table Array of selected row indices, e.g. `{1, 3}`.
function ReorderableList:getSelection()
    local sel = {}
    local v = self._iup.GetAttribute(self._list, "VALUE")
    if v then
        for i = 1, #v do
            if v:sub(i, i) == "+" then sel[#sel + 1] = i end
        end
    end
    return sel
end

--- Set the selection to the given 1-based row positions.
-- All other rows are deselected.
-- @tparam table positions Array of 1-based row indices to select.
function ReorderableList:setSelection(positions)
    local want = {}
    for _, p in ipairs(positions or {}) do want[p] = true end
    local t = {}
    for i = 1, #self._entries do t[i] = want[i] and "+" or "-" end
    self._iup.SetAttribute(self._list, "VALUE", table.concat(t))
end

--- Select all rows.
function ReorderableList:selectAll()
    local all = {}
    for i = 1, #self._entries do all[i] = i end
    self:setSelection(all)
end

--- Deselect all rows.
function ReorderableList:clearSelection()
    self:setSelection({})
end

--- Return whether this list currently owns keyboard focus.
-- Matched by the `BQROLE` attribute set during construction, so two lists that
-- share a tab are disambiguated correctly.
-- @treturn boolean `true` when this list has focus.
function ReorderableList:hasFocus()
    local iup = self._iup
    local f = iup.GetFocus()
    if not f then return false end
    if self._role then
        return iup.GetAttribute(f, "BQROLE") == self._role
    end
    return f == self._list
end

-- ---------------------------------------------------------------------------
-- Drag-to-reorder
--
-- On press we record the grabbed row AND measure the list's row geometry (top of
-- row 1 + row height) from the *clean* list. From then on the drop target is
-- computed arithmetically from the cursor Y, snapping to the gap above/below
-- whichever row is closest. During the drag a horizontal insertion line is drawn
-- at that gap. Because the gap is derived from cached geometry (not by hit-testing
-- the mutated list), inserting the indicator row never corrupts the calculation.
-- ---------------------------------------------------------------------------

function ReorderableList:_rowAt(x, y)
    local ok, pos = pcall(self._iup.ConvertXYToPos, self._list, x, y)
    pos = ok and tonumber(pos) or nil
    if pos and pos >= 1 then return pos end
    return nil
end

function ReorderableList:_measureGeometry(x, y, row)
    local top, bot, cap, n = y, y, 80, 0
    while top > 0 and n < cap and self:_rowAt(x, top - 1) == row do
        top = top - 1; n = n + 1
    end
    n = 0
    while n < cap and self:_rowAt(x, bot + 1) == row do
        bot = bot + 1; n = n + 1
    end
    local h = bot - top + 1
    if h >= 2 then
        self._drag_row_h   = h
        self._drag_row_top = top - (row - 1) * h
    else
        self._drag_row_h, self._drag_row_top = nil, nil
    end
end

function ReorderableList:_gapAtY(y)
    if not self._drag_row_h or not self._drag_row_top then return nil end
    local k = math.floor((y - self._drag_row_top) / self._drag_row_h + 0.5)
    local gap = k + 1
    if gap < 1 then gap = 1 end
    if gap > #self._entries + 1 then gap = #self._entries + 1 end
    return gap
end

function ReorderableList:_renderIndicator(gap)
    local iup = self._iup
    iup.SetAttribute(self._list, "REMOVEITEM", "ALL")
    local row = 0
    local function append(text, color, image)
        row = row + 1
        iup.SetAttribute(self._list, "APPENDITEM", text)
        if color then iup.SetAttributeId(self._list, "FGCOLOR", row, color) end
        if self._image then iup.SetAttributeId(self._list, "IMAGE", row, image) end
    end
    local indicator_color = Theme.color("listSelText", INDICATOR_COLOR)
    for i, entry in ipairs(self._entries) do
        if i == gap then append(self._indicator, indicator_color, nil) end
        append(self._format(entry), self._color and self._color(entry),
               self._image and self._image(entry))
    end
    if gap == #self._entries + 1 then append(self._indicator, indicator_color, nil) end
    iup.SetAttribute(self._list, "VALUE", "")
end

function ReorderableList:_drop(from, gap)
    if not from or not gap then self:refresh(); return end
    local target = gap
    if from < target then target = target - 1 end
    local e = table.remove(self._entries, from)
    if not e then self:refresh(); return end
    if target < 1 then target = 1 end
    if target > #self._entries + 1 then target = #self._entries + 1 end
    table.insert(self._entries, target, e)
    self:refresh()
    self:setSelection({ target })
    if self._on_reorder then self._on_reorder(from, target) end
end

function ReorderableList:_endDrag()
    self._drag_active    = false
    self._drag_from      = nil
    self._drag_row_top   = nil
    self._drag_row_h     = nil
    self._drag_gap_shown = nil
end

function ReorderableList:_updateTooltipAt(x, y)
    if not self._tooltip_fn then return end
    local pos = self:_rowAt(x, y)
    local entry = pos and self._entries[pos] or nil
    local tip = entry and self._tooltip_fn(entry) or nil
    tip = tip and tostring(tip) or ""
    if tip ~= self._hover_tip then
        self._hover_tip = tip
        self._iup.SetAttribute(self._list, "TIP", tip)
    end
end

--- Enable or disable drag-to-reorder temporarily.
-- Useful while a build is running and the queue should be locked.
-- @tparam boolean enabled `true` to allow reordering, `false` to block it.
function ReorderableList:setReorderEnabled(enabled)
    self._reorder = enabled and true or false
end

function ReorderableList:_installCallbacks()
    local iup  = self._iup
    local self_ = self
    local list = self._list

    function list:button_cb(button, pressed, x, y, status)
        self_:_updateTooltipAt(x, y)
        if pressed == 1 then
            -- Grab keyboard focus on click so dialog-level shortcuts route to
            -- this list rather than being sunk into a previously focused control.
            pcall(self_._iup.SetFocus, list)
        end
        if pressed == 1 and self_._on_activate then
            -- A plain click is an exclusive selection; Ctrl/Shift extend. Signal
            -- which so the host can clear sibling lists on a plain click only.
            local shift = status and status:sub(1, 1) == "S"
            local ctrl  = status and status:sub(2, 2) == "C"
            self_._on_activate(not (shift or ctrl))
        end
        if button == iup.BUTTON3 and pressed == 1 then
            if self_._menu then
                local pos = self_:_rowAt(x, y)
                if pos then
                    local sel, already = self_:getSelection(), false
                    for _, p in ipairs(sel) do if p == pos then already = true; break end end
                    if not already then self_:setSelection({ pos }) end
                end
                if self_._on_context then self_._on_context(pos) end
                self_._menu:popup()
            end
        elseif button == iup.BUTTON1 and self_._reorder then
            if pressed == 1 then
                self_._drag_from = self_:_rowAt(x, y)
                if self_._drag_from then
                    self_._drag_active    = true
                    self_._drag_gap_shown = nil
                    self_:_measureGeometry(x, y, self_._drag_from)
                end
            elseif self_._drag_active then
                local gap = self_._drag_row_h and self_:_gapAtY(y) or self_:_rowAt(x, y)
                local from = self_._drag_from
                self_:_endDrag()
                self_:_drop(from, gap)
            end
        end
        return iup.DEFAULT
    end

    function list:motion_cb(x, y, _status)
        self_:_updateTooltipAt(x, y)
        if not self_._drag_active or not self_._drag_from then return iup.DEFAULT end
        if not self_._drag_row_h then
            local cur = self_:_rowAt(x, y)
            if cur then self_:setSelection({ cur }) end
            return iup.DEFAULT
        end
        local gap = self_:_gapAtY(y)
        if gap and gap ~= self_._drag_gap_shown then
            self_:_renderIndicator(gap)
            self_._drag_gap_shown = gap
        end
        return iup.DEFAULT
    end
end

return ReorderableList
