--- The command bar's popup: a field and a filtered list, anchored above the bar.
--
-- Opened by Ctrl+P or by clicking the bar in the status strip. What it lists comes
-- from `core.classes.CommandRegistry`; this module is only the window and the keys.
--
-- It is a borderless child dialog rather than a modal. A modal would dim the app and
-- block it for something the user dismisses within a second; this one closes itself
-- the moment focus leaves it, the way a code editor's palette does.
--
-- @classmod core.ui.CommandPalette

local L = require("core.lib.CarbonLayout")

local CommandPalette = {}
CommandPalette.__index = CommandPalette

-- Nine whole rows of 32px, plus the field, the rule and the hint. A height chosen any
-- other way leaves a sliced row above the hint line.
local WIDTH, ROW_HEIGHT, ROWS, CHROME = 720, 32, 9, 88
local HEIGHT = ROW_HEIGHT * ROWS + CHROME

-- A click on the list moves focus from the field to the list, and that fires the
-- field's kill-focus first. Wait this long, then look at where focus really went.
local FOCUS_SETTLE_MS = 90

local PLACEHOLDER = "Type a command, or a lunar:// address"
-- A flat list draws its text at the row's edge whatever PADDING says; the selected row is an
-- inset pill, so the text needs to start inside it.
local ROW_INDENT = "   "
local HINT = "Enter to run    Esc to close"

--- Create the palette. The window is built on first use.
-- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam table opts.registry a `core.classes.CommandRegistry`
-- @tparam userdata opts.parent the main dialog
-- @tparam function opts.anchor `fn() -> x, y, w`: screen position and width of the bar
-- @tparam[opt] function opts.notify_tree_change themes a new widget tree
-- @tparam[opt] function opts.on_error `fn(message)`: a command failed
-- @tparam[opt] function opts.round `fn(dialog)`: rounds the window's corners
-- @tparam[opt] function opts.muted `fn() -> color`: the colour of group headings
function CommandPalette.new(opts)
	return setmetatable({
		_iup = opts.iup,
		_registry = opts.registry,
		_parent = opts.parent,
		_anchor = opts.anchor,
		_theme = opts.notify_tree_change,
		_on_error = opts.on_error,
		_round = opts.round,
		_muted = opts.muted or function() return "128 128 128" end,
		_items = {},
	}, CommandPalette)
end

function CommandPalette:_build()
	if self._dialog then return end
	local iup, palette = self._iup, self

	local field = iup.text({
		BORDER = "NO",
		EXPAND = "HORIZONTAL",
		THEMEROLE = "palette_text",
		NC = "2048",
	})
	-- A label floated over the empty field. Windows' own cue banner disappears on an edit
	-- that has focus, and this one always does.
	local prompt = iup.flatlabel({
		TITLE = PLACEHOLDER, FLOATING = "YES", POSITION = "18,14", RASTERSIZE = "520x24", THEMEROLE = "palette_prompt",
	})
	local list = iup.flatlist({
		EXPAND = "YES",
		FLATSCROLLBAR = "YES",
		SCROLLBAR = "NO",
		SHOWDRAGDROP = "NO",
		SPACING = "4",
		PADDING = "12x4",
		THEMEROLE = "palette_list",
	})
	local hint = iup.flatlabel({
		EXPAND = "HORIZONTAL",
		TITLE = HINT,
		THEMEROLE = "palette_hint",
	})
	local frame = iup.flatframe({
		iup.vbox({
			iup.hbox({ field, prompt, MARGIN = "14x8", GAP = L.gap(3),
				ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }),
			iup.flatseparator({ ORIENTATION = "HORIZONTAL", STYLE = "LINE", BARSIZE = "1" }),
			list,
			iup.hbox({ hint, MARGIN = L.margin(4, 2), EXPAND = "HORIZONTAL" }),
			GAP = L.gap(1),
			MARGIN = L.margin(1),
		}),
		TITLE = "",
		EXPAND = "YES",
		THEMEROLE = "palette_frame",
	})

	self._dialog = iup.dialog({
		frame,
		BORDER = "NO",
		MENUBOX = "NO",
		MAXBOX = "NO",
		MINBOX = "NO",
		RESIZE = "NO",
		RASTERSIZE = WIDTH .. "x" .. HEIGHT,
		PARENTDIALOG = self._parent,
		THEMEROLE = "palette_frame",
	})
	self._field, self._list, self._hint, self._prompt = field, list, hint, prompt

	function field:valuechanged_cb()
		palette:_refresh()
		return iup.DEFAULT
	end

	-- k_any on both: focus lands on the list after a click, and Esc still has to work.
	local function on_key(_, c)
		if c == iup.K_ESC then
			palette:close()
			return iup.IGNORE
		elseif c == iup.K_CR then
			palette:_activate()
			return iup.IGNORE
		elseif c == iup.K_DOWN then
			palette:_move(1)
			return iup.IGNORE
		elseif c == iup.K_UP then
			palette:_move(-1)
			return iup.IGNORE
		elseif c == iup.K_PGDN then
			palette:_move(8)
			return iup.IGNORE
		elseif c == iup.K_PGUP then
			palette:_move(-8)
			return iup.IGNORE
		end
		return iup.CONTINUE
	end
	field.k_any = on_key
	list.k_any = on_key

	function field:killfocus_cb()
		palette:_scheduleFocusCheck()
		return iup.DEFAULT
	end
	function list:killfocus_cb()
		palette:_scheduleFocusCheck()
		return iup.DEFAULT
	end

	-- The press selects the row; running on release means a press dragged off the
	-- list cancels, like any other button.
	function list:flat_button_cb(button, pressed)
		if button == iup.BUTTON1 and pressed == 0 then
			palette:_scheduleActivate()
		end
		return iup.DEFAULT
	end

	self._focus_timer = iup.timer({ time = FOCUS_SETTLE_MS })
	function self._focus_timer:action_cb()
		self.run = "NO"
		if palette:isOpen() and not palette:_hasFocus() then palette:close() end
		return iup.DEFAULT
	end

	iup.Map(self._dialog)
	if self._theme then pcall(self._theme, self._dialog) end
	if self._round then pcall(self._round, self._dialog) end
end

function CommandPalette:_hasFocus()
	local iup = self._iup
	local focus = iup.GetFocus()
	if not focus then return false end
	local dialog = iup.GetDialog(focus)
	return dialog ~= nil and iup.GetName ~= nil
		and require("core.lib.handle").same(iup, dialog, self._dialog)
end

function CommandPalette:_scheduleFocusCheck()
	self._focus_timer.run = "NO"
	self._focus_timer.run = "YES"
end

function CommandPalette:_scheduleActivate()
	local iup, palette = self._iup, self
	local timer = iup.timer({ time = 10 })
	function timer:action_cb()
		self.run = "NO"
		palette:_activate(tonumber(iup.GetAttribute(palette._list, "VALUE")))
		iup.Destroy(self)
		return iup.DEFAULT
	end
	timer.run = "YES"
end

--- Is the palette showing?
function CommandPalette:isOpen()
	return self._dialog ~= nil and self._iup.GetAttribute(self._dialog, "VISIBLE") == "YES"
end

function CommandPalette:_refresh()
	local iup, list = self._iup, self._list
	local text = iup.GetAttribute(self._field, "VALUE") or ""
	local items, provider = self._registry:query(text)
	if self._choices then
		items, provider = self:_filterChoices(text), nil
	end
	iup.SetAttribute(self._prompt, "VISIBLE", text == "" and "YES" or "NO")

	-- With nothing typed the list is browsed, so it is grouped. A search is ranked, and
	-- headings would only break the ranking up.
	local rows = {}
	if text == "" and not self._choices then
		local order, buckets = {}, {}
		for _, item in ipairs(items) do
			local group = item.group or item.category or "Commands"
			if not buckets[group] then
				buckets[group] = {}
				order[#order + 1] = group
			end
			table.insert(buckets[group], item)
		end
		for _, group in ipairs(order) do
			rows[#rows + 1] = { heading = group }
			for _, item in ipairs(buckets[group]) do rows[#rows + 1] = item end
		end
	else
		rows = items
	end
	self._items = rows

	iup.SetAttribute(list, "REMOVEITEM", "ALL")
	for i, item in ipairs(rows) do
		if item.heading then
			iup.SetAttribute(list, tostring(i), ROW_INDENT .. item.heading:upper())
			iup.SetAttributeId(list, "ITEMFGCOLOR", i, self._muted())
		else
			local line = (item.group and item.title) or self._registry.class.label(item)
			if item.detail and item.detail ~= "" then
				line = line .. "    " .. item.detail
			end
			iup.SetAttribute(list, tostring(i), ROW_INDENT .. line)
		end
	end
	if #items > 0 then
		iup.SetAttribute(list, "VALUE", tostring(self:_firstRow()))
		iup.SetAttribute(self._hint, "TITLE", provider and provider.title
			or (self._choices and self._choices.hint) or HINT)
	else
		iup.SetAttribute(self._hint, "TITLE", provider and (provider.empty or "Nothing to show yet")
			or "No matching commands")
	end
end

function CommandPalette:_firstRow()
	for i, row in ipairs(self._items) do
		if not row.heading then return i end
	end
	return 1
end

function CommandPalette:_filterChoices(text)
	local score = self._registry.class.score
	local trimmed = text:match("^%s*(.-)%s*$")
	if trimmed == "" then return self._choices.items end
	local out = {}
	for _, item in ipairs(self._choices.items) do
		if score(trimmed, item.title) then out[#out + 1] = item end
	end
	return out
end

function CommandPalette:_move(delta)
	local count = #self._items
	if count == 0 then return end
	local current = tonumber(self._iup.GetAttribute(self._list, "VALUE")) or 1
	local target = math.max(1, math.min(count, current + delta))
	-- Headings are not stops: carry on in the same direction, or back if at the end.
	local step = delta > 0 and 1 or -1
	while self._items[target] and self._items[target].heading do target = target + step end
	if not self._items[target] then
		target = target - step
		while self._items[target] and self._items[target].heading do target = target - step end
	end
	if not self._items[target] then return end
	self._iup.SetAttribute(self._list, "VALUE", tostring(target))
	self._iup.SetAttribute(self._list, "TOPITEM", tostring(math.max(1, target - 8)))
end

function CommandPalette:_activate(index)
	index = index or tonumber(self._iup.GetAttribute(self._list, "VALUE")) or 1
	local item = self._items[index]
	if not item or item.heading then return end
	self:close()
	-- After the window is gone: a command may open a modal of its own.
	local iup, palette = self._iup, self
	local timer = iup.timer({ time = 10 })
	function timer:action_cb()
		self.run = "NO"
		local ok, message = palette._registry:run(item)
		if not ok and palette._on_error then palette._on_error(message) end
		iup.Destroy(self)
		return iup.DEFAULT
	end
	timer.run = "YES"
end

function CommandPalette:_place()
	local iup = self._iup
	local x, y, w = self._anchor()
	if not x then return iup.CENTERPARENT, iup.CENTERPARENT end
	return math.floor(x + (w - WIDTH) / 2), y
end

--- Open the palette, or close it if it is already open.
-- @tparam[opt] string text starting text
function CommandPalette:toggle(text)
	if self:isOpen() then
		self:close()
	else
		self:open(text)
	end
end

--- Open the palette.
-- @tparam[opt] string text starting text
-- @tparam[opt] table choices show this list in place of commands:
--   `{ items = { item, ... }, placeholder = string, hint = string }`
function CommandPalette:open(text, choices)
	self:_build()
	local iup = self._iup
	self._choices = choices
	iup.SetAttribute(self._prompt, "TITLE", choices and choices.placeholder or PLACEHOLDER)
	iup.SetAttribute(self._field, "VALUE", text or "")
	self:_refresh()
	local x, y = self:_place()
	iup.ShowXY(self._dialog, x, y)
	iup.SetAttribute(self._prompt, "ZORDER", "TOP")
	iup.SetFocus(self._field)
	iup.SetAttribute(self._field, "CARETPOS", tostring(#(text or "")))
end

--- Close the palette and hand focus back to the main window.
function CommandPalette:close()
	if not self:isOpen() then return end
	self._iup.Hide(self._dialog)
	self._choices = nil
	pcall(self._iup.SetAttribute, self._parent, "BRINGFRONT", "YES")
end

return CommandPalette
