--- Scrollable multi-select list with per-row textual checkboxes backed by a single `iup.flatlist`.
-- Because the whole list is one IUP widget (not one widget per row), a list of hundreds of items
-- is cheap to re-theme and to reload. For drag-to-reorder, see `core.ui.ReorderableList`.
--
-- Item text colour is intentionally NOT set per row; every row inherits the list's
-- themed `FGCOLOR`, so a theme switch recolours all rows by re-theming the single widget.
--
-- **Construction options** (`CheckList:new(iup, opts)`):
--
-- * `opts.format` `function(item) -> string` *(required)* — row label text.
-- * `opts.checked_default` `boolean` (default `true`) — initial checkbox state for new items.
-- * `opts.show_checkboxes` `boolean` (default `true`) — render a textual `[x]`/`[ ]` prefix.
-- * `opts.show_border` `boolean` (default `true`) — render a themed border.
-- * `opts.font` `string` (default `"Consolas, 9"`) — list font.
-- * `opts.menu` `ContextMenu|items-spec` — optional right-click context menu.
-- * `opts.on_check` `function(index, checked)` — called when a checkbox changes.
-- * `opts.on_activate` `function(exclusive)` — user interacted with this list (focus hint);
--   `exclusive` is `true` for a plain (non Ctrl/Shift) selection.
-- * `opts.role` `string` — `BQROLE` tag for focus routing.
-- * `opts.themerole` `string` (default `"list_bordered"`) — `THEMEROLE` for appearance; defaults to the
--   active-queue accent-text/no-fill selection style.
-- * `opts.motion` `core.classes.MotionDirector|nil` — optional director for staggered entrance
--   animation when the list is populated. Omit to keep today's instant behaviour.
--
-- @usage
--   local CheckList = require("core.ui.CheckList")
--   local list = CheckList:new(iup, {
--       format = function(t) return t.name end,
--       on_check = function(i, checked)
--           print(i, checked)
--       end,
--   })
--   list:setItems({ {name="Alpha"}, {name="Beta"} })
--   vbox:append(list:widget())
-- @classmod core.ui.CheckList

local class = require("middleclass")
local ContextMenu = require("core.ui.ContextMenu")
local Theme = require("core.classes.Theme")
local ListEntrance = require("core.ui.ListEntrance")

local CheckList = class("CheckList")

--- Create a new CheckList.
-- @tparam userdata iup The IUP library reference.
-- @tparam table opts Construction options (see module description).
-- @treturn CheckList New instance.
function CheckList:initialize(iup, opts)
    opts = opts or {}
    assert(type(opts.format) == "function", "CheckList requires opts.format")
    self._iup             = iup
    self._format          = opts.format
    self._checked_default = opts.checked_default ~= false
    self._show_checkboxes = opts.show_checkboxes ~= false
    self._font            = opts.font or "Consolas, 9"
    self._on_check        = opts.on_check
    self._on_activate     = opts.on_activate
    self._role            = opts.role
    self._show_border     = opts.show_border ~= false
    -- THEMEROLE drives appearance only (BQROLE below drives focus routing). Default
    -- to the active-queue list's role so the selection style (accent text, no fill)
    -- matches the rest of the build panel.
    self._themerole       = opts.themerole or "list_bordered"
    self._motion          = opts.motion or nil

    self._items     = {}   -- backing item objects (1-based, live ref via items())
    self._checked   = {}   -- per-index checkbox state (model; survives re-render)
    self._anchor    = nil  -- anchor for shift-click range selection
    self._selection = {}   -- pure-Lua selection state (index -> true); NOT derived from VALUE

    self._list = iup.flatlist{
        EXPAND       = "YES",
        MULTIPLE     = "YES",  -- VALUE "+/-" string; selection written by us via flat_button_cb
        -- Owner-drawn flat scrollbar (not the native Win32 SCROLLBAR), matching the
        -- rest of the app: native scrollbars are separate HWND children that ignore
        -- our owner-drawn theming and don't repaint cleanly under the theme switch's
        -- LockWindowUpdate batch. FLATSCROLLBAR picks up the role's scrollbg/scrollfg
        -- so the list keeps the themed IupFlatScrollBox look it had before.
        FLATSCROLLBAR = "YES",
        SCROLLBAR    = "NO",
        -- Drop the native etched border so the role's (themable) border is the only
        -- outline, rather than a white native frame sitting inside it.
        BORDER       = "NO",
        CANFOCUS     = "YES",
        VISIBLELINES = "8",
        FONT         = Theme.color("font", self._font),
    }
    if self._role then iup.SetAttribute(self._list, "BQROLE", self._role) end
    if self._themerole then iup.SetAttribute(self._list, "THEMEROLE", self._themerole) end
    if not self._show_border then iup.SetAttribute(self._list, "BORDERWIDTH", "0") end

    if opts.menu then
        if type(opts.menu) == "table" and opts.menu.isInstanceOf
           and opts.menu:isInstanceOf(ContextMenu) then
            self._menu = opts.menu
        else
            self._menu = ContextMenu:new(iup, opts.menu)
        end
    end

    self:_installCallbacks()
end

--- Return the IUP flatlist handle to add to a layout.
-- @treturn userdata IUP flatlist handle.
function CheckList:widget() return self._list end

--- Return a live reference to the backing item array.
-- @treturn table The item array last passed to `setItems`.
function CheckList:items()  return self._items end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- The display text for row `i`: an optional textual checkbox prefix plus the
-- caller's formatted label. Item colour is intentionally NOT set here so each row
-- inherits the list's themed FGCOLOR and recolours for free on a theme switch.
function CheckList:_itemText(i)
    local label = self._format(self._items[i])
    if self._show_checkboxes then
        return (self._checked[i] and "[x] " or "[ ] ") .. label
    end
    return label
end

-- Repaint a single row's text in place (used when its checkbox state changes).
function CheckList:_renderItem(i)
    if not self._items[i] then return end
    self._iup.SetAttributeId(self._list, "", i, self:_itemText(i))
end

--- Rebuild rows from a new item array.
-- Resets all checkboxes to `opts.checked_default` and clears the selection.
-- No widgets are created or destroyed — only the single flatlist is refilled.
-- When a director was supplied at construction, the list widget enters with a
-- height-grow animation so the population reads as a cascade rather than a snap.
-- @tparam table items Array of item objects; each is passed to `opts.format`.
function CheckList:setItems(items)
    local iup = self._iup
    self._items   = items or {}
    self._anchor  = nil
    self._checked = {}

    iup.SetAttribute(self._list, "REMOVEITEM", "ALL")
    local default_checked = self._checked_default and true or false
    for i = 1, #self._items do
        self._checked[i] = default_checked
        iup.SetAttribute(self._list, "APPENDITEM", self:_itemText(i))
    end
    -- Clear selection so a reload starts with nothing selected.
    self._selection = {}
    self._iup.SetAttribute(self._list, "VALUE", "")

    -- Animate the whole list widget as a single staggered entrance so the
    -- population reads as a content arrival rather than a hard swap. The list
    -- is one IUP widget (not one per row), so we pass it as a 1-element array;
    -- the height-grow still reads as an entrance, and a director that is nil or
    -- has motion off both reduce to instant behaviour with no branching here.
    -- No explicit container needed: ListEntrance falls back to refreshing the
    -- widget itself when none is supplied, which is correct for a self-contained
    -- list that manages its own layout.
    if self._motion and #self._items > 0 then
        ListEntrance.play(self._motion, { self._list })
    end
end

-- ---------------------------------------------------------------------------
-- Selection (Lua _selection table + VALUE written by us; flat_button_cb +
-- IGNORE prevents the native simple-toggle from ever running)
-- ---------------------------------------------------------------------------

--- Return the 1-based indices of all selected rows.
-- @treturn table Array of selected row indices, e.g. `{1, 3}`.
function CheckList:getSelection()
    local sel = {}
    for i = 1, #self._items do
        if self._selection[i] then sel[#sel + 1] = i end
    end
    return sel
end

-- Replace full selection: updates _selection table AND writes VALUE so the
-- native list renders the highlight correctly.
function CheckList:_applySelection(want)
    self._selection = {}
    local n = #self._items
    local t = {}
    for i = 1, n do
        if want[i] then
            self._selection[i] = true
            t[i] = "+"
        else
            t[i] = "-"
        end
    end
    self._iup.SetAttribute(self._list, "VALUE", table.concat(t))
end

--- Select or deselect all rows at once.
-- @tparam boolean value `true` to select all, `false` to deselect all.
function CheckList:setAllSelected(value)
    local want = {}
    if value then
        for i = 1, #self._items do want[i] = true end
    end
    self:_applySelection(want)
end

--- Set the selected state of a single row without affecting the others.
-- @tparam number index 1-based row index.
-- @tparam boolean value `true` to select, `false` to deselect.
function CheckList:setSelected(index, value)
    if not self._items[index] then return end
    local want = {}
    for i, v in pairs(self._selection) do want[i] = v end
    want[index] = value and true or nil
    self:_applySelection(want)
end

--- Select only the given row (all others are deselected) and update the anchor for shift-click.
-- @tparam number index 1-based row index.
function CheckList:selectOnly(index)
    local want = {}
    if self._items[index] then want[index] = true end
    self:_applySelection(want)
    self._anchor = index
end

--- Invert the current selection (selected rows become unselected and vice versa).
function CheckList:invertSelection()
    local want = {}
    for i = 1, #self._items do want[i] = not self._selection[i] or nil end
    self:_applySelection(want)
end

-- ---------------------------------------------------------------------------
-- Checkbox state (model-backed; rendered as a text prefix when show_checkboxes)
-- ---------------------------------------------------------------------------

--- Return whether the given row's checkbox is checked.
-- @tparam number index 1-based row index.
-- @treturn boolean `true` if checked.
function CheckList:isChecked(index)
    return self._checked[index] == true
end

--- Set the checkbox state of a single row.
-- Fires `opts.on_check(index, value)` if the state actually changed.
-- @tparam number index 1-based row index.
-- @tparam boolean value `true` to check, `false` to uncheck.
function CheckList:setChecked(index, value)
    if not self._items[index] then return end
    local v = value and true or false
    if self._checked[index] == v then return end
    self._checked[index] = v
    if self._show_checkboxes then self:_renderItem(index) end
    if self._on_check then self._on_check(index, v) end
end

--- Return the checkbox state of every row.
-- @treturn table Array of booleans, one per row (1-based), e.g. `{true, false, true}`.
function CheckList:getChecked()
    local t = {}
    for i = 1, #self._items do t[i] = self._checked[i] == true end
    return t
end

--- Set the checkbox of every currently selected row to `value`.
-- @tparam boolean value `true` to check, `false` to uncheck.
function CheckList:setSelectionChecked(value)
    for _, i in ipairs(self:getSelection()) do
        self:setChecked(i, value)
    end
end

--- Toggle the checkboxes of the selection as a group.
-- If any selected row is checked, all are unchecked; otherwise all are checked.
-- @treturn boolean `false` if nothing is selected; `true` otherwise.
function CheckList:toggleSelectionChecked()
    local sel = self:getSelection()
    if #sel == 0 then return false end
    local any_on = false
    for _, i in ipairs(sel) do
        if self:isChecked(i) then any_on = true; break end
    end
    self:setSelectionChecked(not any_on)
    return true
end

-- ---------------------------------------------------------------------------
-- Focus / interaction
-- ---------------------------------------------------------------------------

--- Return whether this list currently owns keyboard focus.
-- @treturn boolean `true` when this list has focus.
function CheckList:hasFocus()
    local iup = self._iup
    local f = iup.GetFocus()
    if not f then return false end
    if self._role then
        return iup.GetAttribute(f, "BQROLE") == self._role
    end
    return f == self._list
end

-- Notify the owner that the user just interacted with this list (focus/active-list
-- hint). `exclusive` is true for a plain (non Ctrl/Shift) selection so the host can
-- clear sibling lists; modifier-extended selections pass false.
function CheckList:_activated(exclusive)
    if self._on_activate then self._on_activate(exclusive and true or false) end
end

function CheckList:_rowAt(x, y)
    local ok, pos = pcall(self._iup.ConvertXYToPos, self._list, x, y)
    pos = ok and tonumber(pos) or nil
    if pos and pos >= 1 then return pos end
    return nil
end

function CheckList:_installCallbacks()
    local iup   = self._iup
    local self_ = self
    local list  = self._list

    -- FLAT_BUTTON_CB fires BEFORE IupFlatList's internal click processing.
    -- Returning iup.IGNORE suppresses the internal handler (including the
    -- simple-toggle that causes plain clicks to accumulate into a multi-select).
    -- We compute and write the desired selection ourselves, then ignore.
    function list:flat_button_cb(button, pressed, x, y, status)
        if button == iup.BUTTON1 then
            if pressed == 1 then
                pcall(self_._iup.SetFocus, list)
                local shift = status and status:sub(1, 1) == "S"
                local ctrl  = status and status:sub(2, 2) == "C"
                local pos = self_:_rowAt(x, y)
                if pos then
                    if shift and self_._anchor then
                        local a, b = self_._anchor, pos
                        if a > b then a, b = b, a end
                        local want = {}
                        for i = a, b do want[i] = true end
                        self_:_applySelection(want)
                    elseif ctrl then
                        local want = {}
                        for i, v in pairs(self_._selection) do want[i] = v end
                        want[pos] = not want[pos] or nil
                        self_:_applySelection(want)
                        self_._anchor = pos
                    else
                        self_:selectOnly(pos)
                    end
                end
                self_:_activated(not (shift or ctrl))
            end
            return iup.IGNORE  -- suppress internal toggle for both press and release
        elseif button == iup.BUTTON3 and pressed == 1 then
            local pos = self_:_rowAt(x, y)
            if pos and not self_._selection[pos] then self_:selectOnly(pos) end
            self_:_activated(true)
            if self_._menu then self_._menu:popup() end
        end
        return iup.DEFAULT
    end

    -- Keyboard navigation (arrow keys) still fires valuechanged_cb; sync our
    -- _selection table from the VALUE the list computed so reads stay correct.
    function list:valuechanged_cb()
        local v = self_._iup.GetAttribute(list, "VALUE") or ""
        self_._selection = {}
        for i = 1, #v do
            if v:sub(i, i) == "+" then self_._selection[i] = true end
        end
        self_:_activated(true)
        return iup.DEFAULT
    end
end

return CheckList
