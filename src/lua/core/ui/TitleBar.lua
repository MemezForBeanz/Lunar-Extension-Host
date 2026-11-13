--- The window caption: the light/dark button, top toolbar tabs and the view controls.
-- @classmod core.ui.TitleBar

local WindowChrome = require("core.ui.WindowChrome")
local ModeIcon = require("core.ui.ModeIcon")

local StripView = require("core.ui.TabStripView")

local TitleBar = {}
TitleBar.__index = TitleBar

TitleBar.HEIGHT = 40
local BUTTON_HEIGHT = 28

local SIDE_MARGIN = 8
local GAP = 8
local BUTTON = 32
local MARK = 20
local VIEW_BUTTONS = 3
-- A strip has no natural width of its own: it takes its page's, and these pages are empty.
-- So the bar works it out, with a little over for what the control adds around a title.
local TAB_SLACK = 10

--- Space for tabs, leaving a caption drag area and the native window buttons.
function TitleBar.layout(width, reserved, tabs)
	local before = SIDE_MARGIN + BUTTON + GAP
	local after = VIEW_BUTTONS * BUTTON
	local available = math.max(0, width - before - after - (reserved or 0) - 80)
	local groups = math.min(available, tabs or available)
	return { left = before + groups, groups = groups }
end

--- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam userdata opts.root the main strip
-- @tparam function opts.icon `(name, size) -> image handle`, an icon that follows the theme
-- @tparam[opt] function opts.is_hidden `(page) -> bool`: pages that keep no tab in the bar
-- @tparam[opt] function opts.frame `(name, svg) -> path`, where animation frames are kept
function TitleBar.new(opts)
	local iup = opts.iup
	local self = setmetatable({
		_iup = iup, _root = opts.root, _icon = opts.icon, _frame = opts.frame, _dark = true,
	}, TitleBar)
	local bar = self

	local function button(tip, on_press)
		local widget = iup.flatbutton({
			TIP = tip, CANFOCUS = "YES", FOCUSFEEDBACK = "NO", RASTERSIZE = BUTTON .. "x" .. BUTTON_HEIGHT,
			THEMEROLE = "titlebar_button",
		})
		function widget:flat_action()
			on_press()
			return iup.DEFAULT
		end
		return widget
	end

	self._mode = button("Switch to light theme", function()
		if bar._on_mode then bar._on_mode() end
	end)
	opts.icon(self._mode, "lunar-mark", MARK, "accent")
	self._menu = button("Menu", function() if bar._on_menu then bar._on_menu() end end)
	opts.icon(self._menu, "menu")
	self._bars = button("Hide sidebar and status bar", function() if bar._on_bars then bar._on_bars() end end)
	opts.icon(self._bars, "open-panel--filled--left")
	self._terminal = button("Show terminal (Ctrl+`)", function()
		if bar._on_terminal then bar._on_terminal() end
	end)
	opts.icon(self._terminal, "open-panel--bottom")

	self._groups = iup.flattabs({
		EXPAND = "NO", CANFOCUS = "NO", THEMEROLE = "titlebar_tabs", EXTRABUTTONS = "1", TABSIMAGEPOSITION = "RIGHT",
		-- the + follows the last tab (beside the mode button when there are none)
		EXTRAFOLLOW1 = "YES",
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
		self._mode,
		iup.vbox({ iup.fill({}), self._groups, EXPAND = "VERTICALFREE" }),
		ALIGNMENT = "ACENTER", GAP = tostring(GAP), MARGIN = SIDE_MARGIN .. "x0",
	})
	self._widget = iup.hbox({
		-- The strut holds the bar's height: a box takes its height from its children.
		iup.label({ TITLE = "", RASTERSIZE = "0x" .. TitleBar.HEIGHT }),
		self._left, iup.fill({}), self._menu, self._bars, self._terminal, self._reserved,
		ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL", GAP = "0",
		MARGIN = "0x0",
	})
	return self
end

function TitleBar:widget() return self._widget end
--- The top toolbar's mirror of the main tree.
function TitleBar:groupStrip() return self._groups end
function TitleBar:onMode(fn) self._on_mode = fn end
function TitleBar:onMenu(fn) self._on_menu = fn end
function TitleBar:onBars(fn) self._on_bars = fn end
function TitleBar:onTerminal(fn) self._on_terminal = fn end
function TitleBar:setMotion(director) self._motion = director end
function TitleBar:setOrder(order) self._view:setOrder(order) end
function TitleBar:themeChanged()
	self._view:themeChanged()
	self._iup.Update(self._mode) -- its accent colour changed, and the bar behind it may not have
end
function TitleBar:sync(pages)
	local visible = self._view:sync(pages)
	local hidden = {}
	for i, show in ipairs(visible) do hidden[i] = not show end
	self:_measureTabs(pages, hidden)
	self:fit(self._width, true)
end

--- Say what the two view buttons will do, and show what is open.
-- @tparam boolean bars the sidebar and status bar are showing
-- @tparam boolean terminal the terminal is open
function TitleBar:setViewState(bars, terminal)
	local iup = self._iup
	self._icon(self._bars, bars and "open-panel--filled--left" or "open-panel--left")
	iup.SetAttribute(self._bars, "TIP", (bars and "Hide" or "Show") .. " sidebar and status bar")
	iup.Update(self._bars)
	self._icon(self._terminal, terminal and "open-panel--filled--bottom" or "open-panel--bottom")
	iup.SetAttribute(self._terminal, "TIP", (terminal and "Hide" or "Show") .. " terminal (Ctrl+`)")
	iup.Update(self._terminal)
end

--- What the mode button says right now.
function TitleBar:modeTip() return self._iup.GetAttribute(self._mode, "TIP") end

--- The theme mode on screen: a moon for dark, a sun for light.
-- @tparam boolean dark
-- @tparam[opt] boolean can_change false when the other mode can't be reached
-- @tparam[opt] string why what the button says then
function TitleBar:setMode(dark, can_change, why)
	local iup = self._iup
	iup.SetAttribute(self._mode, "TIP",
		can_change == false and why or ("Switch to " .. (dark and "light" or "dark") .. " theme"))
	if dark == self._dark then return end
	self._dark = dark
	local target = dark and 0 or 1
	local function finish()
		self._turn, self._progress = nil, target
		self._icon(self._mode, dark and "lunar-mark" or "light", MARK, "accent")
		iup.Update(self._mode)
	end
	if self._turn then self._turn:cancel() end
	if not self._motion or not self._motion:enabled() then return finish() end
	local start = self._progress or (1 - target)
	self._turn = self._motion:animate({
		role = "theme_mode_icon", from = start, to = target,
		on_frame = function(value)
			self._progress = value
			self:_paintFrame(value)
		end,
		on_done = function(completed) if completed then finish() end end,
	})
end

-- One frame of the turn. A frame that can't be drawn is skipped: the turn still ends on
-- the real icon.
function TitleBar:_paintFrame(value)
	if not self._frame then return end
	local step = math.floor(math.max(0, math.min(1, value)) * ModeIcon.FRAMES + 0.5)
	local path = self._frame("mode-1-" .. step, ModeIcon.svg(step / ModeIcon.FRAMES))
	if not path or path == self._frame_path then return end
	self._frame_path = path
	local VectorIcon = require("core.ui.VectorIcon")
	if not VectorIcon.available then return end
	local handle = VectorIcon.imageHandle(self._iup, { path = path, size = MARK, color = VectorIcon.roleColor("accent") })
	if handle then
		self._iup.SetAttribute(self._mode, "IMAGE", handle)
		self._iup.Update(self._mode) -- a flat button doesn't redraw for a new image alone
	end
end

-- The width of a tab's title in the strip's own font, from IUP's driver: only the strip
-- would know, and it doesn't say. Close enough on a build without the export.
local function text_width(iup, strip, text)
	-- The ImGui host measures with the element's own font, as the driver would.
	local measure = rawget(iup, "_textWidth")
	if measure then return measure(strip, text) end
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
			total = total + text_width(iup, self._groups, title) + 2 * pad + TAB_SLACK
			local image = iup.GetAttributeId(self._root, "TABIMAGE", i - 1)
			if image then
				local handle = iup.GetHandle(image)
				local width = handle and tonumber(iup.GetAttribute(handle, "WIDTH")) or 16
				total = total + width + (tonumber(iup.GetAttribute(self._groups, "TABSIMAGESPACING")) or 2)
			end
		end
	end
	self._tabs_width = total + BUTTON -- the + alone when no tab is showing
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
	iup.SetAttribute(self._groups, "RASTERSIZE", math.max(1, math.min(lay.groups, self._tabs_width or BUTTON)) .. "x32")
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
