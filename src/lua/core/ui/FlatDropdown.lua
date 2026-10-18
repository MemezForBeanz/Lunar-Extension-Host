--- A dropdown drawn by IUP itself instead of the native combo box.
--
-- An `IupDropButton` whose drop child is an `IupFlatList`, themed through the
-- `dropbutton` and `dropdown_list` roles, so the closed control, its border and
-- the open list all follow the active theme. A native `iup.list{DROPDOWN="YES"}`
-- follows the operating system's theme instead (a stock combo on Windows, the
-- desktop's GTK theme on Linux) and can't be styled to match. Use this for every
-- choice the user picks from a list.
--
-- It carries the fixes the Build Queue selectors arrived at:
--
--   * The popup closes on the list's button **release**. `VALUECHANGED_CB` alone
--     can't do it: the flat list fires nothing when the user re-picks the item
--     that is already selected, so the popup would stay open. Closing on release
--     (not press) leaves the press-time selection dispatch intact.
--   * Drags and clicks on the list's own scrollbar don't count as a pick.
--   * The attribute that closes it is `SHOWDROPDOWN`; `DROPDOWN` is not a
--     dropbutton attribute and setting it does nothing, silently.
--   * The closed caption is set from the item the code knows it picked, never
--     read back out of a list that may have just been rebuilt.
--   * Each dropdown gets its own drop-child handle name: the dropbutton binding
--     finds its child by name, and two dropdowns sharing one would share a list.
--   * The popup is sized to the button (`visible_columns`), and its height is
--     capped (`max_lines`), so a long list scrolls instead of running off screen.
--
-- Keyboard, like a native combo box: Space or Enter opens it (the dropbutton's
-- own handling), the arrow keys move in the open list starting from the selected
-- item (fork patch 0003), Enter picks and closes, Escape closes. While closed,
-- Up/Down/Home/End change the selection directly.
--
-- Accessibility: this is a drawn control, so a screen reader announces it as a
-- button with its caption, not as a combo box with items. That is a known gap
-- against a native list (Windows UI Automation / ATK work, tracked separately).
--
-- @classmod core.ui.FlatDropdown
-- @usage
--   local FlatDropdown = require("core.ui.FlatDropdown")   -- or ctx.ui.FlatDropdown
--   local dd = FlatDropdown.new(iup, {
--       items = { "Small", "Medium", "Large" },
--       value = 2,
--       expand = true,
--       on_change = function(index, label) ctx:setStatus("Size: " .. label) end,
--   })
--   parent_box:append(dd.widget)

local FlatDropdown = {}
FlatDropdown.__index = FlatDropdown

local handle_seq = 0

--- Create a dropdown.
-- @param iup the IUP binding
-- @tparam[opt] table opts
-- @tparam[opt] table opts.items labels, in order
-- @tparam[opt] number opts.value index of the selected item (nil shows `placeholder`)
-- @tparam[opt] string opts.placeholder caption while nothing is selected
-- @tparam[opt] function opts.on_change `fn(index, label)` when the **user** picks an item
-- @tparam[opt] number opts.width fixed width in pixels
-- @tparam[opt] boolean opts.expand fill the available width instead
-- @tparam[opt] string opts.font IUP font for the button and the list
-- @tparam[opt=14] number opts.visible_columns popup width hint, in characters
-- @tparam[opt=12] number opts.max_lines most rows the open list shows before scrolling
-- @tparam[opt] string opts.name a stable prefix for the drop child's handle name
-- @treturn FlatDropdown with `widget` (the control to place) and `list` fields
function FlatDropdown.new(iup, opts)
	opts = opts or {}
	handle_seq = handle_seq + 1
	local self = setmetatable({
		_iup = iup,
		_items = {},
		_value = nil,
		_placeholder = opts.placeholder or "",
		_on_change = opts.on_change,
		_max_lines = math.max(1, tonumber(opts.max_lines) or 12),
		_silent = false,
	}, FlatDropdown)

	local list = iup.flatlist({
		READONLY       = "YES",
		VISIBLECOLUMNS = tostring(opts.visible_columns or 14),
		VISIBLELINES   = "1",
		FLATSCROLLBAR  = "YES",
		-- The flat scrollbar draws itself; the native one stays off so the popup
		-- never falls back to an unthemed system bar.
		SCROLLBAR      = "NO",
		FONT           = opts.font,
		THEMEROLE      = "dropdown_list",
	})
	-- The dropbutton finds its drop child by handle name (iuplua's constructor
	-- can't pass it), so each instance needs its own.
	local name = string.format("%s_%d", opts.name or "lunar_flatdropdown", handle_seq)
	iup.SetHandle(name, list)

	local btn = iup.dropbutton({
		TITLE       = self._placeholder,
		DROPCHILD   = name,
		FONT        = opts.font,
		THEMEROLE   = "dropbutton",
		DROPONARROW = "NO",
		RASTERSIZE  = opts.width and (tostring(opts.width) .. "x") or nil,
		EXPAND      = opts.expand and "HORIZONTAL" or nil,
	})

	self.list, self.widget, self.handle_name = list, btn, name

	local dd = self
	local press_x, press_y
	function list:flat_button_cb(button, pressed, x, y)
		if button ~= iup.BUTTON1 then return iup.DEFAULT end
		if pressed == 1 then
			press_x, press_y = x, y
			return iup.DEFAULT
		end
		-- Only a click that lands where it started is a pick.
		local moved = (not press_x) or math.abs(x - press_x) > 3 or math.abs(y - press_y) > 3
		press_x, press_y = nil, nil
		if moved then return iup.DEFAULT end
		-- Clicks on the owner-drawn scrollbar, while it is showing, aren't picks.
		if iup.GetAttribute(list, "YHIDDEN") == "NO" then
			local w = tonumber(tostring(iup.GetAttribute(list, "RASTERSIZE") or ""):match("^(%d+)"))
			local sb = tonumber(iup.GetAttribute(list, "SCROLLBARSIZE")) or 12
			if w and x > w - sb - 2 then return iup.DEFAULT end
		end
		dd:close()
		return iup.DEFAULT
	end

	-- Enter in the open list keeps the item the arrows reached and closes. A named
	-- key callback is used only for its key, so the list's own K_ANY keeps the
	-- arrows and type-to-find working.
	function list:k_cr()
		dd:close()
		pcall(iup.SetFocus, btn)
		return iup.DEFAULT
	end

	-- Closed: the arrows step through the choices, as on a native combo box.
	local function step(to)
		return function()
			local n = #dd._items
			if n == 0 then return iup.DEFAULT end
			local index = to(dd._value or 0, n)
			if index < 1 then index = 1 elseif index > n then index = n end
			if index ~= dd._value then dd:_pick(index) end
			return iup.DEFAULT
		end
	end
	btn.k_down = step(function(v) return v + 1 end)
	btn.k_up = step(function(v) return v - 1 end)
	btn.k_home = step(function() return 1 end)
	btn.k_end = step(function(_, n) return n end)

	function list:valuechanged_cb()
		if dd._silent then return iup.DEFAULT end
		local index = tonumber(iup.GetAttribute(list, "VALUE") or "")
		if not (index and dd._items[index]) then return iup.DEFAULT end
		dd:_notify(index)
		return iup.DEFAULT
	end

	self:setItems(opts.items or {}, opts.value)
	return self
end

-- The user picked `index` (already selected in the list).
function FlatDropdown:_notify(index)
	local label = self._items[index]
	self._value = index
	self:_caption(label)
	if self._on_change then self._on_change(index, label) end
end

-- A pick made from the closed button's keys: select it in the list too.
function FlatDropdown:_pick(index)
	self._silent = true
	self._iup.SetAttribute(self.list, "VALUE", tostring(index))
	self._silent = false
	self:_notify(index)
end

function FlatDropdown:_caption(label)
	local iup = self._iup
	local text = label or self._placeholder
	iup.SetAttribute(self.widget, "TITLE", text)
	-- The full text on hover: a long value is wider than the button.
	pcall(iup.SetAttribute, self.widget, "TIP", label or nil)
end

--- Replace the items, optionally selecting one. Doesn't call `on_change`.
-- @tparam table items labels, in order
-- @tparam[opt] number value index to select (nil clears the selection)
function FlatDropdown:setItems(items, value)
	local iup, list = self._iup, self.list
	self._items = {}
	for i, label in ipairs(items) do self._items[i] = tostring(label) end
	self._silent = true
	for i, label in ipairs(self._items) do iup.SetAttribute(list, tostring(i), label) end
	-- Setting the entry after the last one to nil truncates the list.
	iup.SetAttribute(list, tostring(#self._items + 1), nil)
	iup.SetAttribute(list, "VISIBLELINES", tostring(math.max(1, math.min(#self._items, self._max_lines))))
	self._silent = false
	self:setValue(value)
end

--- Select an item from code. Doesn't call `on_change`.
-- @tparam[opt] number index (nil, or out of range, shows the placeholder)
function FlatDropdown:setValue(index)
	local iup = self._iup
	index = tonumber(index)
	if index and not self._items[index] then index = nil end
	self._value = index
	self._silent = true
	iup.SetAttribute(self.list, "VALUE", index and tostring(index) or nil)
	self._silent = false
	self:_caption(index and self._items[index] or nil)
end

--- The selected index, or nil.
-- @treturn number|nil
function FlatDropdown:value()
	return self._value
end

--- The selected label, or nil.
-- @treturn string|nil
function FlatDropdown:label()
	return self._value and self._items[self._value] or nil
end

--- Close the popup if it is open.
function FlatDropdown:close()
	pcall(self._iup.SetAttribute, self.widget, "SHOWDROPDOWN", "NO")
end

return FlatDropdown
