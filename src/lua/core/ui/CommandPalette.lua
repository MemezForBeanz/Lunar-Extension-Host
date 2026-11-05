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
local Kit = require("core.ui.Kit")

local CommandPalette = {}
CommandPalette.__index = CommandPalette

-- Nine whole rows of 32px, plus the field, the rule and the hint. A height chosen any
-- other way leaves a sliced row above the hint line.
local WIDTH, ROW_HEIGHT, ROWS, CHROME = 640, 32, 8, 92
local CATEGORY_WIDTH, SHORTCUT_WIDTH, RECENT_MAX = 120, 72, 5
local HEIGHT = ROW_HEIGHT * ROWS + CHROME

-- A click on the list moves focus from the field to the list, and that fires the
-- field's kill-focus first. Wait this long, then look at where focus really went.
local FOCUS_SETTLE_MS = 90

local PLACEHOLDER = "Type a command, or a lunar:// address"
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
		_settings = opts.settings,
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
		TITLE = PLACEHOLDER, FLOATING = "YES", POSITION = "18,14", RASTERSIZE = "520x22", THEMEROLE = "palette_prompt",
	})
	-- Focus stays in the field, so the keyboard keeps typing whichever way a row is chosen.
	self._rows = Kit.rowList(iup, {
		role = "palette_rows",
		column_widths = { CATEGORY_WIDTH, SHORTCUT_WIDTH, 0 },
		on_part = function(pos) palette:_scheduleActivate(pos) end,
		empty_title = "", empty_hint = "",
	})
	local list = self._rows.widget
	iup.SetAttribute(list, "EXPAND", "YES")
	iup.SetAttribute(list, "CANFOCUS", "NO")
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

	function field:killfocus_cb()
		palette:_scheduleFocusCheck()
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

function CommandPalette:_scheduleActivate(pos)
	local iup, palette = self._iup, self
	local timer = iup.timer({ time = 10 })
	function timer:action_cb()
		self.run = "NO"
		palette:_activate(pos)
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

	-- With nothing typed the list is browsed: what was used last, then everything in its
	-- group. A search is ranked, and regrouping would only break the ranking up.
	local rows
	if text == "" and (not self._choices or self._choices.grouped) then
		rows = self:_browse(items)
	else
		rows = items
	end
	self._items = rows

	local cells = {}
	for i, item in ipairs(rows) do
		local title = (item.group and item.title) or item.title or self._registry.class.label(item)
		if item.detail and item.detail ~= "" then title = title .. "    " .. item.detail end
		cells[i] = {
			title = title,
			column1 = item.recent and "Recent" or item.group or item.category,
			column2 = item.shortcut,
		}
	end
	self._rows:setRows(cells)
	iup.SetAttribute(list, "POSY", "0")
	self._top = 1
	if #items > 0 then
		self._rows:select(1)
		iup.SetAttribute(self._hint, "TITLE", provider and provider.title
			or (self._choices and self._choices.hint) or HINT)
	else
		iup.SetAttribute(self._hint, "TITLE", provider and (provider.empty or "Nothing to show yet")
			or "No matching commands")
	end
end

function CommandPalette:_recentIds()
	local stored = self._settings and self._settings:get("palette.recent")
	return type(stored) == "table" and stored or {}
end

function CommandPalette:_remember(item)
	if not (self._settings and item.id) or self._choices then return end
	local ids = { item.id }
	for _, id in ipairs(self:_recentIds()) do
		if id ~= item.id and #ids < RECENT_MAX then ids[#ids + 1] = id end
	end
	self._settings:set("palette.recent", ids)
	self._settings:save()
end

-- Recents first, then each group together in the order it first appears.
function CommandPalette:_browse(items)
	local by_id, used, rows = {}, {}, {}
	for _, item in ipairs(items) do
		if item.id then by_id[item.id] = item end
	end
	if not self._choices then
		for _, id in ipairs(self:_recentIds()) do
			local item = by_id[id]
			if item then
				local copy = {}
				for k, v in pairs(item) do copy[k] = v end
				copy.recent = true
				rows[#rows + 1] = copy
				used[id] = true
			end
		end
	end
	local order, buckets = {}, {}
	for _, item in ipairs(items) do
		if not (item.id and used[item.id]) then
			local group = item.group or item.category or "Commands"
			if not buckets[group] then
				buckets[group] = {}
				order[#order + 1] = group
			end
			table.insert(buckets[group], item)
		end
	end
	for _, group in ipairs(order) do
		for _, item in ipairs(buckets[group]) do rows[#rows + 1] = item end
	end
	return rows
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
	local target = math.max(1, math.min(count, self._rows:selected() + delta))
	self._rows:select(target)
	local top = self._top or 1
	if target < top then top = target end
	if target >= top + ROWS then top = target - ROWS + 1 end
	self._top = top
	self._iup.SetAttribute(self._list, "POSY", tostring((top - 1) * ROW_HEIGHT))
end

function CommandPalette:_activate(index)
	index = index or self._rows:selected()
	local item = self._items[index]
	if not item then return end
	self:_remember(item)
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
--   `{ items = { item, ... }, placeholder = string, hint = string, grouped = boolean }`
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
