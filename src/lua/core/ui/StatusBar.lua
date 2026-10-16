--- The bottom status bar: a status line, the update indicator, extension status
-- elements, and the org's logo when its profile ships one.
--
-- Extensions reach it through `HostAPI` (`setStatus`, `setUpdateState`,
-- `addStatusElement`); the host builds it once.
--
-- @classmod core.ui.StatusBar

local L = require("core.lib.CarbonLayout")
local StatusIcon = require("core.ui.StatusIcon")
local VectorIcon = require("core.ui.VectorIcon")

local StatusBar = {}
StatusBar.__index = StatusBar

--- Update indicator states: the pre-rasterized Carbon icon and its tooltip.
StatusBar.UPDATE_STATES = {
	current = { icon = "upd_complete", tip = "Software up to date\nThis app and its installed extensions match the latest release on the update share." },
	available = { icon = "upd_get", tip = "Update available\nA newer release was found on the update share." },
	unavailable = { icon = "upd_check", tip = "Couldn't check for updates\nThe update share couldn't be reached or read." },
	checking = { icon = "upd_check", tip = "Checking for updates..." },
	ready = { icon = "upd_now", tip = "Update ready to install\nThe downloaded update is staged and ready to apply." },
}
StatusBar.UPDATE_CLICK_HINT = "\n\nClick to check for updates now."

--- Parse an IUP `"R G B"` colour into three numbers (nil if it isn't one).
function StatusBar.parse_rgb(value)
	local r, g, b = tostring(value or ""):match("^(%d+)%s+(%d+)%s+(%d+)")
	if not r then return nil end
	return tonumber(r), tonumber(g), tonumber(b)
end

--- @tparam table opts
-- @tparam table opts.iup
-- @tparam string opts.icon_dir the rasterized Carbon icons (assets/Icons)
-- @tparam[opt] string opts.logo an SVG to show at the right end (the org's logo)
function StatusBar.new(opts)
	local iup = opts.iup
	local self = setmetatable({ _iup = iup }, StatusBar)
	self._label = iup.label({
		TITLE = "Status: Ready",
		EXPAND = "HORIZONTAL",
		FONT = "Segoe UI, 9",
		FGCOLOR = "60 60 60",
	})
	-- Registered with HostAPI by whoever owns update checks (core.ui.UpdateCheck),
	-- and only when there is a share to check.
	self._update_icon = StatusIcon.new(iup, {
		dir = opts.icon_dir, size = 24, state = "upd_complete", tip = StatusBar.UPDATE_STATES.current.tip,
	})
	self._ext_box = iup.hbox({ GAP = L.gap(2), ALIGNMENT = "ACENTER" })
	local logo_image = opts.logo and VectorIcon.logoHandle(iup, opts.logo, 20)
	self._widget = iup.hbox({
		self._label,
		iup.fill({}),
		self._ext_box,
		logo_image and iup.label({ IMAGE = logo_image, TITLE = "" }) or nil,
		BGCOLOR = "240 240 240",
		MARGIN = L.margin(3, 2),
		GAP = L.gap(3),
		ALIGNMENT = "ACENTER",
		-- HORIZONTAL, not IupHbox's default YES. A vertically expanding child of
		-- the window's vbox is handed `natural height + empty`, and `empty` goes
		-- negative when the content is taller than the window, which squeezed the
		-- bar to nothing. Horizontal-only makes it a fixed-height row.
		EXPAND = "HORIZONTAL",
	})
	return self
end

--- The bar itself.
function StatusBar:widget() return self._widget end
--- The box extension status elements go in (HostAPI's `status_box`).
function StatusBar:extBox() return self._ext_box end
--- The update indicator (a `core.ui.StatusIcon`).
function StatusBar:updateIcon() return self._update_icon end

--- Animate status changes through this director (it is built after the bar).
function StatusBar:setMotion(director)
	self._motion = director
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
	if not pcall(iup.SetAttribute, label, "TITLE", "Status: " .. tostring(msg)) then
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
