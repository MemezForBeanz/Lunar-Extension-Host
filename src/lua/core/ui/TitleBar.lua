--- The window caption: Settings, branding and top toolbar tabs.
-- @classmod core.ui.TitleBar

local WindowChrome = require("core.ui.WindowChrome")

local StripView = require("core.ui.TabStripView")

local TitleBar = {}
TitleBar.__index = TitleBar

TitleBar.HEIGHT = 40
local BUTTON_HEIGHT = 28

local SIDE_MARGIN = 8
local GAP = 8
local BUTTON = 32
local MARK = 20
-- A strip has no natural width of its own: it takes its page's, and these pages are empty.
-- So the bar works it out, with a little over for what the control adds around a title.
local TAB_SLACK = 10

--- Space for tabs, leaving a caption drag area and the native window buttons.
function TitleBar.layout(width, reserved, tabs)
	local before = SIDE_MARGIN + BUTTON + GAP + MARK + GAP
	local available = math.max(0, width - before - (reserved or 0) - 80)
	local groups = math.min(available, tabs or available)
	return { left = before + groups, groups = groups }
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
		_iup = iup, _root = opts.root, _is_settings = opts.is_settings,
	}, TitleBar)
	local bar = self

	self._menu = iup.flatbutton({
		TIP = "Settings (Ctrl+,)", CANFOCUS = "YES", RASTERSIZE = BUTTON .. "x" .. BUTTON_HEIGHT,
		THEMEROLE = "titlebar_button",
	})
	opts.icon(self._menu, "settings")
	function self._menu:flat_action()
		if bar._on_settings then bar._on_settings() end
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
		EXPAND = "NO", CANFOCUS = "NO", THEMEROLE = "titlebar_tabs", EXTRABUTTONS = "1",
	})
	self._view = StripView.new({ iup = iup, root = opts.root, strip = self._groups, is_hidden = opts.is_hidden })
	opts.icon(self._groups, "add", 16, "neutral", "EXTRAIMAGE1")
	iup.SetAttributeId(self._groups, "EXTRATIP", 1, "New tab group")
	function self._groups:extrabutton_cb(id, pressed)
		if opts.root.extrabutton_cb then return opts.root.extrabutton_cb(opts.root, id, pressed) end
		return iup.DEFAULT
	end

	-- A fill, not a label: anything with a window here would cover the painted buttons.
	self._reserved = iup.fill({ RASTERSIZE = "1x" })
	self._left = iup.hbox({
		self._menu, self._mark,
		iup.vbox({ iup.fill({}), self._groups, EXPAND = "VERTICALFREE" }),
		ALIGNMENT = "ACENTER", GAP = tostring(GAP), MARGIN = SIDE_MARGIN .. "x0",
	})
	self._widget = iup.hbox({
		-- The strut holds the bar's height: a box takes its height from its children.
		iup.label({ TITLE = "", RASTERSIZE = "0x" .. TitleBar.HEIGHT }),
		self._left, iup.fill({}), self._reserved,
		ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", GAP = "0",
		MARGIN = "0x0",
	})
	return self
end

function TitleBar:widget() return self._widget end
--- The top toolbar's mirror of the main tree.
function TitleBar:groupStrip() return self._groups end
function TitleBar:onSettings(fn) self._on_settings = fn end
function TitleBar:setOrder(order) self._view:setOrder(order) end
function TitleBar:themeChanged() self._view:themeChanged() end
function TitleBar:sync(pages)
	local visible = self._view:sync(pages)
	local hidden = {}
	for i, show in ipairs(visible) do hidden[i] = not show end
	self:_measureTabs(pages, hidden)
	self:fit(self._width, true)
	local iup = self._iup
	local manager = require("core.ui.ThemeReactor").themeManager()
	local theme = manager and manager:activeTheme()
	local rules = theme and theme:rules() or {}
	local colors = rules.titlebar_window or {}
	local page = iup.GetAttribute(self._root, "VALUE_HANDLE")
	local selected = page and self._is_settings and self._is_settings(page)
	iup.SetAttribute(self._menu, "BGCOLOR", selected and colors.pressed or colors.bg)
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
	self._tabs_width = math.max(80, total + 32)
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
	iup.SetAttribute(self._groups, "RASTERSIZE", math.max(1, math.min(lay.groups, self._tabs_width or 80)) .. "x32")
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
