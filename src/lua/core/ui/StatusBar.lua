--- The bottom status bar: background work, a status line, extension status elements and the
-- update indicator.
--
-- Extensions reach it through `HostAPI` (`setStatus`, `setUpdateState`,
-- `addStatusElement`, `activity`); the host builds it once.
--
-- @classmod core.ui.StatusBar

local L = require("core.lib.CarbonLayout")
local StatusIcon = require("core.ui.StatusIcon")

local StatusBar = {}
StatusBar.__index = StatusBar

--- Update indicator states: the pre-rasterized Carbon icon and its tooltip.
StatusBar.UPDATE_STATES = {
	current = { icon = "upd_complete", tip = "Software up to date\nNo newer published GitHub release is available for this app or its bundled extensions." },
	available = { icon = "upd_get", tip = "Update available\nA newer published release is available on GitHub." },
	unavailable = { icon = "upd_check", tip = "Couldn't check for updates\nGitHub release metadata could not be retrieved or validated." },
	checking = { icon = "upd_check", tip = "Checking for updates..." },
	ready = { icon = "upd_now", tip = "Update ready to install\nThe downloaded update is staged and ready to apply." },
}
StatusBar.UPDATE_CLICK_HINT = "\n\nClick to check for updates now."

StatusBar.HEIGHT = 28

--- How wide the activity slot's text is. Fixed, so that progress ticking over doesn't
-- lay the whole window out again.
StatusBar.ACTIVITY_WIDTH = 220
-- What the activity slot shows once work has ended (`Activity:status`'s states).
local ACTIVITY_GLYPHS = {
	ok = "activity_ok", failed = "activity_failed", cancelled = "activity_stopped", attention = "activity_dot",
}

--- Parse an IUP `"R G B"` colour into three numbers (nil if it isn't one).
function StatusBar.parse_rgb(value)
	local r, g, b = tostring(value or ""):match("^(%d+)%s+(%d+)%s+(%d+)")
	if not r then return nil end
	return tonumber(r), tonumber(g), tonumber(b)
end

--- @tparam table opts
-- @tparam table opts.iup
-- @tparam string opts.icon_dir the rasterized Carbon icons (assets/Icons)
function StatusBar.new(opts)
	local iup = opts.iup
	local self = setmetatable({ _iup = iup }, StatusBar)
	-- The literals are the Classic (no-override) look; every real theme
	-- restyles the bar through the statusbar/statusbar_text roles instead of
	-- the hardcoded gray this bar carried for years.
	self._label = iup.label({
		TITLE = "",
		EXPAND = "HORIZONTAL",
		-- A floor, not a size: long text ends in an ellipsis, it doesn't widen the window.
		RASTERSIZE = "40x",
		ELLIPSIS = "YES",
		FONT = "Segoe UI, 9",
		FGCOLOR = "60 60 60",
		THEMEROLE = "statusbar_text",
	})
	-- Registered with HostAPI by core.ui.UpdateCheck for every installation.
	self._update_icon = StatusIcon.new(iup, {
		dir = opts.icon_dir, size = 16, state = "upd_complete", tip = StatusBar.UPDATE_STATES.current.tip,
	})
	self._ext_box = iup.hbox({ GAP = L.gap(2), ALIGNMENT = "ACENTER" })

	-- Background work, in place of a word that said nothing. Empty until there is some.
	-- Sixteen pixels of icon and one line of text, so it fits the bar however slim.
	-- The state matters even though nothing shows yet: IUP fixes a label as image or text
	-- when it maps, and one mapped without an image never draws one.
	self._activity_icon = StatusIcon.new(iup, { dir = opts.icon_dir, size = 16, state = "activity_ok" })
	self._activity_text = iup.flatbutton({
		TITLE = "",
		RASTERSIZE = StatusBar.ACTIVITY_WIDTH .. "x",
		ALIGNMENT = "ALEFT:ACENTER",
		TEXTELLIPSIS = "YES",
		CANFOCUS = "NO",
		PADDING = "4x0",
		THEMEROLE = "statusbar_button",
	})
	local bar = self
	function self._activity_text:flat_action()
		if bar._on_activity then bar._on_activity() end
		return iup.DEFAULT
	end
	local activity_glyph = self._activity_icon:widget()
	function activity_glyph:button_cb(button, pressed)
		if button == iup.BUTTON1 and pressed == 0 and bar._on_activity then bar._on_activity() end
		return iup.DEFAULT
	end
	self._activity_box = iup.hbox({
		activity_glyph, self._activity_text,
		ALIGNMENT = "ACENTER", GAP = L.gap(1), FLOATING = "YES", VISIBLE = "NO",
	})

	self._menu = iup.flatbutton({ TIP = "Menu", CANFOCUS = "YES", RASTERSIZE = "48x28",
		PADDING = "0x0", THEMEROLE = "statusbar_button" })
	self._command = iup.flatbutton({ TITLE = "Search or run a command", CANFOCUS = "YES",
		IMAGEPOSITION = "LEFT", ALIGNMENT = "ALEFT:ACENTER", SPACING = "8", EXPAND = "HORIZONTAL",
		THEMEROLE = "commandbar_text" })
	self._keycap = iup.flatbutton({ TITLE = "Ctrl+P", CANFOCUS = "NO", THEMEROLE = "keycap" })
	self._field = iup.flatframe({ iup.hbox({ self._command, self._keycap,
		MARGIN = "2x1", GAP = "4", ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }),
		TITLE = "", RASTERSIZE = "320x24", EXPAND = "NO", THEMEROLE = "commandbar" })
	self._focus = iup.flatbutton({ TIP = "Focus active pane / restore split (Esc to restore)",
		CANFOCUS = "YES", RASTERSIZE = "32x28", THEMEROLE = "statusbar_button", ACTIVE = "NO" })
	if opts.bind_icon then
		opts.bind_icon(self._menu, "menu")
		opts.bind_icon(self._command, "search")
		opts.bind_icon(self._focus, "view")
	end
	function self._menu:flat_action() if bar._on_menu then bar._on_menu() end; return iup.DEFAULT end
	local function command() if bar._on_command then bar._on_command() end; return iup.DEFAULT end
	self._command.flat_action, self._keycap.flat_action = command, command
	function self._focus:flat_action() if bar._on_focus then bar._on_focus() end; return iup.DEFAULT end
	self._widget = iup.hbox({
		iup.hbox({ self._menu, self._activity_box, self._label,
			EXPAND = "HORIZONTAL", ALIGNMENT = "ACENTER", GAP = "0" }),
		iup.hbox({ iup.fill({}), self._field, iup.fill({}), EXPAND = "HORIZONTAL", ALIGNMENT = "ACENTER" }),
		iup.hbox({ iup.fill({}), self._ext_box, self._focus,
			EXPAND = "HORIZONTAL", ALIGNMENT = "ACENTER", GAP = L.gap(2), MARGIN = "8x0" }),
		HOMOGENEOUS = "YES", RASTERSIZE = "x" .. StatusBar.HEIGHT,
		BGCOLOR = "240 240 240", THEMEROLE = "statusbar", MARGIN = "0x0", GAP = "0",
		ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL",
	})
	return self
end

--- The bar itself.
function StatusBar:widget() return self._widget end
function StatusBar:commandWidget() return self._field end
function StatusBar:onCommand(fn) self._on_command = fn end
function StatusBar:onMenu(fn) self._on_menu = fn end
function StatusBar:onFocus(fn) self._on_focus = fn end
function StatusBar:setPaneState(split, focused)
	self._iup.SetAttribute(self._focus, "ACTIVE", split and "YES" or "NO")
	self._iup.SetAttribute(self._focus, "TIP", focused and "Restore split (Esc)" or "Focus active pane")
end
function StatusBar:fit(width)
	self._iup.SetAttribute(self._field, "RASTERSIZE", math.max(160, math.min(480, math.floor(width / 3) - 16)) .. "x24")
	self._iup.SetAttribute(self._activity_text, "RASTERSIZE", (width < 1100 and 80 or StatusBar.ACTIVITY_WIDTH) .. "x")
end

--- Set what a click on the activity slot does.
function StatusBar:onActivity(fn) self._on_activity = fn end
--- Where the activity panel opens from: the bar's left end, which nothing pushes along.
function StatusBar:activityAnchor() return self._menu end
--- The box extension status elements go in (HostAPI's `status_box`).
function StatusBar:extBox() return self._ext_box end
--- The update indicator (a `core.ui.StatusIcon`).
function StatusBar:updateIcon() return self._update_icon end

--- Animate status changes through this director (it is built after the bar).
function StatusBar:setMotion(director)
	self._motion = director
end

--- Show what `core.classes.Activity` says is going on.
-- @tparam[opt] table view `{ state, text, tip }`; nil empties the slot
function StatusBar:setActivity(view)
	local key = view and (view.state .. "|" .. view.text .. "|" .. tostring(view.tip)) or ""
	if key == self._activity_key then return end
	self._activity_key = key
	local iup, box, icon, text = self._iup, self._activity_box, self._activity_icon, self._activity_text
	-- A status bar that throws would surface as an error in whichever tool reported.
	pcall(function()
		if view and view.state == "running" then
			if not icon:isSpinning() then icon:startSpin() end
		elseif view then
			icon:stopSpin(ACTIVITY_GLYPHS[view.state])
		else
			icon:stopSpin()
		end
		if view then
			-- A flat button reads & as a mnemonic.
			iup.SetAttribute(text, "TITLE", (view.text:gsub("&", "&&")))
			iup.SetAttribute(text, "TIP", view.tip or "")
		end
		local shown = view ~= nil
		if shown ~= (self._activity_shown or false) then
			self._activity_shown = shown
			iup.SetAttribute(box, "FLOATING", shown and "NO" or "YES")
			iup.SetAttribute(box, "VISIBLE", shown and "YES" or "NO")
			iup.Refresh(box)
		end
	end)
end

--- Show a status message.
--
-- The new text fades in rather than replacing the old one: the bar is
-- peripheral, and a hard swap there draws the eye more than the information
-- usually deserves (motion role `status_change`, so a theme can retime it). IUP
-- has no per-widget opacity, so the fade runs the text colour from the bar's
-- background up to its resting colour, both read from the live widget so it
-- follows the theme.
-- @tparam string msg
function StatusBar:setStatus(msg)
	local iup, label = self._iup, self._label
	if not label then return end
	if not pcall(iup.SetAttribute, label, "TITLE", tostring(msg)) then
		-- A dead label must never turn status updates into repeated error dialogs.
		self._label = nil
		return
	end
	local motion = self._motion
	if not motion then return end

	-- While a fade runs, FGCOLOR holds an in-between colour; reading it then would
	-- make that the new resting colour. Reuse the running fade's endpoints instead.
	local fade = self._fade
	if not fade then
		local to_r, to_g, to_b, from_r, from_g, from_b
		local read = pcall(function()
			to_r, to_g, to_b = StatusBar.parse_rgb(iup.GetAttribute(label, "FGCOLOR"))
			from_r, from_g, from_b = StatusBar.parse_rgb(iup.GetAttribute(label, "BGCOLOR"))
		end)
		-- No explicit colours: nothing to fade between, and the text is right as is.
		if not read or not to_r or not from_r then return end
		fade = { to_r, to_g, to_b, from_r, from_g, from_b }
	end
	self._fade = fade
	local to_r, to_g, to_b, from_r, from_g, from_b = unpack(fade)

	motion:animate({
		role     = "status_change",
		target   = label,
		from     = 0,
		to       = 1,
		on_frame = function(v)
			pcall(iup.SetAttribute, label, "FGCOLOR", string.format("%d %d %d",
				from_r + (to_r - from_r) * v, from_g + (to_g - from_g) * v, from_b + (to_b - from_b) * v))
		end,
		on_done = function()
			if self._fade == fade then self._fade = nil end
		end,
	})
end

--- Show an update state (`StatusBar.UPDATE_STATES`; unknown means current).
-- @tparam string state
-- @tparam[opt] string tooltip replaces the state's own
function StatusBar:setUpdateState(state, tooltip)
	local s = StatusBar.UPDATE_STATES[state] or StatusBar.UPDATE_STATES.current
	local icon = self._update_icon
	pcall(function() icon:set(s.icon, (tooltip or s.tip) .. StatusBar.UPDATE_CLICK_HINT) end)
end

--- Spin the update indicator while a check runs.
function StatusBar:startUpdateSpin()
	local s, icon = StatusBar.UPDATE_STATES.checking, self._update_icon
	pcall(function() icon:startSpinState(s.icon, "ccw", s.tip) end)
end

function StatusBar:stopUpdateSpin()
	local icon = self._update_icon
	pcall(function() icon:stopSpin() end)
end

return StatusBar
