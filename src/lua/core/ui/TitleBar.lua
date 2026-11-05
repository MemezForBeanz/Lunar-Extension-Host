--- The bar across the top of the window: app menu, mark, tab groups and the command field. On Windows 11 it is the window's caption too (`winframe`); elsewhere it
-- sits under the system caption and the window keeps its own buttons.
--
-- ### The groups are a mirror
--
-- A group is a tab of the main strip, whose page holds the group's own strip, and that tree
-- belongs to `core.classes.TabGroups`. The bar can't hold the main strip's tabs without
-- taking its pages, so the main strip hides its tabs and this draws them: a second
-- `iup.flattabs` with one empty page per tab. Overflow arrows, hover and hit testing come
-- from the control, and presses go to the main strip's own handlers, so dragging a tab,
-- spring-open and the context menu are all `core.classes.TabOrder`'s code as before.
--
-- Positions match one for one. Settings keeps a position with its tab hidden, and with
-- Settings open the rail's gear reads as selected instead of any group.
--
-- @classmod core.ui.TitleBar

local WindowChrome = require("core.ui.WindowChrome")

local TitleBar = {}
TitleBar.__index = TitleBar

TitleBar.HEIGHT = 40
TitleBar.FIELD_HEIGHT = 28

local SIDE_MARGIN = 8
local GAP = 8
local BUTTON = 32
local MARK = 20
-- A strip has no natural width of its own: it takes its page's, and these pages are empty.
-- So the bar works it out, with a little over for what the control adds around a title.
local TAB_SLACK = 10

--- How wide the command field is in a window this wide.
function TitleBar.fieldWidth(width)
	if width >= 1500 then return 480 end
	if width >= 1000 then return 360 end
	return math.max(200, math.floor(width / 3))
end

--- Lay the bar out across `width`: the field centred on the window unless the groups need
-- the room or the right end would run into it. Pure, so it's testable without a window.
-- @tparam number width
-- @tparam[opt] number reserved what the window buttons take
-- @tparam[opt] number tabs what the groups would like
-- @treturn table `{ field, left, groups }` in pixels
function TitleBar.layout(width, reserved, tabs)
	local field = TitleBar.fieldWidth(width)
	local right = SIDE_MARGIN + (reserved or 0)
	local before = SIDE_MARGIN + BUTTON + GAP + MARK + GAP
	local left = math.floor((width - field) / 2)
	left = math.max(left, before + (tabs or 0))
	left = math.min(left, width - field - right)
	left = math.max(SIDE_MARGIN + BUTTON + GAP, left)
	return { field = field, left = left, groups = math.max(0, left - before) }
end

--- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam userdata opts.root the main strip
-- @tparam function opts.icon `(name, size) -> image handle`, an icon that follows the theme
-- @tparam[opt] userdata opts.logo the org's logo, an image handle, in place of the mark
-- @tparam[opt] function opts.is_hidden `(page) -> bool`: pages that keep no tab in the bar
function TitleBar.new(opts)
	local iup = opts.iup
	local self = setmetatable({
		_iup = iup, _root = opts.root, _is_hidden = opts.is_hidden, _pages = {}, _count = 0,
	}, TitleBar)
	local bar = self

	self._menu = iup.flatbutton({
		TIP = "Menu", CANFOCUS = "YES", RASTERSIZE = BUTTON .. "x" .. TitleBar.FIELD_HEIGHT,
		THEMEROLE = "titlebar_button",
	})
	opts.icon(self._menu, "menu")
	function self._menu:flat_action()
		if bar._on_menu then bar._on_menu() end
		return iup.DEFAULT
	end

	self._mark = iup.label({
		TITLE = "", TIP = "Lunar Extension Host", RASTERSIZE = MARK .. "x" .. MARK, ALIGNMENT = "ACENTER:ACENTER",
	})
	if opts.logo then
		iup.SetAttribute(self._mark, "IMAGE", opts.logo)
	else
		opts.icon(self._mark, "lunar-mark", MARK, "accent")
	end

	self._groups = iup.flattabs({
		EXPAND = "NO", CANFOCUS = "NO", THEMEROLE = "titlebar_tabs",
	})
	self:_wireGroups()

	self._hint = iup.flatbutton({
		TITLE = "Search or run a command",
		TIP = "Search commands, or go to a lunar:// address (Ctrl+P)",
		IMAGEPOSITION = "LEFT",
		ALIGNMENT = "ALEFT:ACENTER",
		SPACING = "8",
		EXPAND = "HORIZONTAL",
		CANFOCUS = "YES",
		THEMEROLE = "commandbar_text",
	})
	opts.icon(self._hint, "search", 14, "neutral")
	self._keycap = iup.flatbutton({
		TITLE = "Ctrl+P", CANFOCUS = "NO", THEMEROLE = "keycap", TIP = "Open the command bar",
	})
	local function command()
		if bar._on_command then bar._on_command() end
		return iup.DEFAULT
	end
	self._hint.flat_action, self._keycap.flat_action = command, command
	self._field = iup.flatframe({
		iup.hbox({
			self._hint, self._keycap,
			ALIGNMENT = "ACENTER", MARGIN = "2x2", GAP = "4", EXPAND = "HORIZONTAL",
		}),
		TITLE = "", EXPAND = "NO", RASTERSIZE = "360x" .. TitleBar.FIELD_HEIGHT, THEMEROLE = "commandbar",
	})

	-- A fill, not a label: anything with a window here would cover the painted buttons.
	self._reserved = iup.fill({ RASTERSIZE = "1x" })
	self._left = iup.hbox({
		self._menu, self._mark,
		iup.vbox({ iup.fill({}), self._groups, EXPAND = "VERTICALFREE" }),
		ALIGNMENT = "ACENTER", GAP = tostring(GAP), MARGIN = SIDE_MARGIN .. "x0",
	})
	self._widget = iup.hbox({
		-- The strut holds the bar's height: a box takes its height from its children.
		iup.label({ TITLE = "", RASTERSIZE = "1x" .. TitleBar.HEIGHT }),
		self._left, self._field, iup.fill({}), self._reserved,
		ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", GAP = "0",
		MARGIN = "0x0",
	})
	return self
end

function TitleBar:widget() return self._widget end
--- The field the palette opens over.
function TitleBar:commandWidget() return self._field end
--- The strip that stands in for the main strip's tabs (see `core.classes.TabOrder`).
function TitleBar:groupStrip() return self._groups end
--- What the menu button does.
function TitleBar:onMenu(fn) self._on_menu = fn end
--- What the command field does.
function TitleBar:onCommand(fn) self._on_command = fn end

-- A press is the main strip's: its handlers read positions, and TabOrder resolves them
-- against this strip. The switch itself reaches the main strip from tabchange_cb.
function TitleBar:_wireGroups()
	local iup, groups, root = self._iup, self._groups, self._root
	local bar = self
	function groups:flat_button_cb(button, pressed, x, y, status)
		local result = iup.DEFAULT
		if root.flat_button_cb then result = root.flat_button_cb(root, button, pressed, x, y, status) end
		-- Leaving Settings by the group that was open: the strip sees no change to report.
		if bar._away and button == iup.BUTTON1 and pressed == 0 then
			local ok, pos = pcall(iup.ConvertXYToPos, self, x, y)
			if ok and tostring(pos) == iup.GetAttribute(self, "VALUEPOS") then bar:_select(tonumber(pos)) end
		end
		return result
	end
	function groups:flat_motion_cb(x, y, status)
		if root.flat_motion_cb then return root.flat_motion_cb(root, x, y, status) end
		return iup.DEFAULT
	end
	function groups:rightclick_cb(pos)
		if root.rightclick_cb then return root.rightclick_cb(root, pos) end
		return iup.DEFAULT
	end
	function groups:tabchange_cb()
		if not bar._syncing then bar:_select(tonumber(iup.GetAttribute(self, "VALUEPOS"))) end
		return iup.DEFAULT
	end
end

-- Show position `pos` of the main strip. IUP doesn't report a change it was told to make,
-- so the host's scoping and the page transition, both chained on tabchange_cb, hear it here.
function TitleBar:_select(pos)
	local iup, root = self._iup, self._root
	local old = iup.GetChild(root, tonumber(iup.GetAttribute(root, "VALUEPOS")) or 0)
	iup.SetAttribute(root, "VALUEPOS", tostring(pos))
	if root.tabchange_cb then root.tabchange_cb(root, iup.GetChild(root, pos), old) end
end

-- With a page open that has no tab here, the group that was open stays put but stops
-- reading as selected. The strip can't select nothing, and a hidden tab it scrolls to.
function TitleBar:_setAway(away)
	if away == self._away then return end
	self._away = away
	local iup, palette = self._iup, require("core.ui.ThemeReactor").palette()
	iup.SetAttribute(self._groups, "TABSACTIVELINE", not away and palette.accent or nil)
	iup.SetAttribute(self._groups, "FORECOLOR", away and palette.textMuted or palette.text)
end

--- A theme pass has changed the groups' font, and reset the colours `_setAway` manages.
function TitleBar:themeChanged()
	self._shape = nil
	self._away = nil
end

--- Bring the groups in line with the main strip.
-- @tparam table pages the main strip's pages, in order
function TitleBar:sync(pages)
	local iup, groups = self._iup, self._groups
	self._syncing = true
	while self._count < #pages do
		local page = iup.vbox({})
		iup.Append(groups, page)
		if iup.GetAttribute(self._widget, "WID") then iup.Map(page) end
		self._pages[#self._pages + 1] = page
		self._count = self._count + 1
	end
	while self._count > #pages and self._count > 1 do
		iup.Destroy(table.remove(self._pages))
		self._count = self._count - 1
	end

	local hidden_active = false
	local active = tonumber(iup.GetAttribute(self._root, "VALUEPOS")) or 0
	local shape, hidden = {}, {}
	for i, page in ipairs(pages) do
		local pos = i - 1
		hidden[i] = self._is_hidden and self._is_hidden(page) or false
		shape[i] = (hidden[i] and "-" or "+") .. (iup.GetAttributeId(self._root, "TABTITLE", pos) or "")
		if hidden[i] and pos == active then hidden_active = true end
	end
	shape = table.concat(shape, "\0")
	local changed = shape ~= self._shape
	if changed then
		self._shape = shape
		for i = 1, #pages do
			local pos = i - 1
			iup.SetAttributeId(groups, "TABTITLE", pos, iup.GetAttributeId(self._root, "TABTITLE", pos) or "")
			iup.SetAttributeId(groups, "TABVISIBLE", pos, hidden[i] and "NO" or "YES")
		end
	end
	if changed then self:_measureTabs(pages, hidden) end
	if not hidden_active and #pages > 0 and tostring(iup.GetAttribute(groups, "VALUEPOS")) ~= tostring(active) then
		iup.SetAttribute(groups, "VALUEPOS", tostring(active))
	end
	self:_setAway(hidden_active)
	self._syncing = false
	if changed then
		-- Natural width follows the titles, and what's left of the bar is a drag handle.
		pcall(iup.Refresh, self._widget)
		self:fit(self._width, true)
	end
	iup.Update(groups)
end

-- The width of a tab's title in the strip's own font, from IUP's driver: only the strip
-- would know, and it doesn't say. Close enough on a build without the export.
local function text_width(strip, text)
	local width
	pcall(function()
		local ffi = require("ffi")
		local IupFFI = require("core.classes.IupFFI")
		pcall(ffi.cdef, "int iupdrvFontGetStringWidth(void* ih, const char* str);")
		width = ffi.C.iupdrvFontGetStringWidth(IupFFI.ptr(strip), text)
	end)
	return width or #text * 8
end

-- How wide the visible tabs and the buttons after them are together.
function TitleBar:_measureTabs(pages, hidden)
	local iup = self._iup
	local pad = tonumber(tostring(iup.GetAttribute(self._groups, "TABSPADDING") or ""):match("^(%d+)")) or 12
	local total = 0
	for i = 1, #pages do
		if not hidden[i] then
			local title = iup.GetAttributeId(self._root, "TABTITLE", i - 1) or ""
			total = total + text_width(self._groups, title) + 2 * pad + TAB_SLACK
		end
	end
	self._tabs_width = total
end

--- Fit the bar to the window. Attributes only: the window's own layout pass follows.
-- @tparam number width client width
-- @tparam[opt] boolean force
function TitleBar:fit(width, force)
	if not width or width <= 0 then return end
	-- Windows sizes the buttons in the window's own DPI, and a move to another monitor
	-- changes that; a high contrast switch takes them away altogether.
	local reserved = self._frame_dialog and require("winframe").reserved(self._frame_dialog) or 0
	if reserved ~= self._frame_width then
		self._frame_width = reserved
		self._iup.SetAttribute(self._reserved, "RASTERSIZE", math.max(reserved, 1) .. "x") -- 0 means no size at all
		force = true
	end
	if width == self._width and not force then return end
	self._width = width
	local iup = self._iup
	local lay = TitleBar.layout(width, reserved, self._tabs_width)
	iup.SetAttribute(self._left, "RASTERSIZE", lay.left .. "x")
	iup.SetAttribute(self._field, "RASTERSIZE", lay.field .. "x" .. TitleBar.FIELD_HEIGHT)
	iup.SetAttribute(self._groups, "RASTERSIZE", math.min(lay.groups, self._tabs_width or 0) .. "x")
end

--- Make the bar the window's caption, where the platform can. Call between Map and Show,
-- so the first frame is already the final one.
-- @tparam userdata dialog the mapped main dialog
-- @tparam table theme_mgr `core.classes.ThemeManager`
-- @treturn boolean the bar is the caption
function TitleBar:adoptFrame(dialog, theme_mgr)
	local ok, winframe = pcall(require, "winframe")
	if not ok or not winframe.supported() or not winframe.attach(dialog) then return false end
	self._frame_dialog = dialog
	winframe.caption(dialog, TitleBar.HEIGHT)
	local function colours()
		local theme = theme_mgr:activeTheme()
		local rules = theme and theme:rules() or {}
		local r = rules.titlebar_window or {}
		local function ref(value) return WindowChrome.colorref(value) or 0 end
		pcall(winframe.colors, dialog, ref(r.bg), ref(r.fg), ref(r.muted), ref(r.hover), ref(r.pressed))
	end
	theme_mgr:onApply(colours)
	colours()
	return true
end


return TitleBar
