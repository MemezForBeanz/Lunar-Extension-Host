--- The bottom status bar: background work, a status line, extension status elements and the
-- update indicator.
--
-- Extensions reach it through `HostAPI` (`setStatus`, `setUpdateState`,
-- `addStatusElement`, `activity`); the host builds it once.
--
-- The widget tree is a `core.lui` component driven by one store: each method below
-- writes the store and flushes, so a call takes effect before it returns, as it did when
-- the methods wrote attributes by hand. Three things stay imperative, through refs:
-- the status fade (an animated colour the theme also owns), the Settings button's
-- pressed colour (the theme pass writes the same attribute), and the two icon spinners
-- (`core.ui.StatusIcon` widgets embedded with `ui.Native`).
--
-- @classmod core.ui.StatusBar

local L = require("core.lib.CarbonLayout")
local StatusIcon = require("core.ui.StatusIcon")
local ui = require("core.lui")

local StatusBar = {}
StatusBar.__index = StatusBar
local logo_seed_seq = 0

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

-- Components --------------------------------------------------------------------------
-- Each reads only its slice of the store, so a status message renders the status line
-- and nothing else. `p.bar` is the StatusBar: callbacks and refs live there.

local function call(fn) if fn then fn() end end

local Settings = ui.memo(function(p)
	local bar = p.bar
	return ui.Button{ ref = bar._refs.settings, tooltip = "Settings (Ctrl+,)", focusable = true, size = { 48, 28 },
		padding = 0, role = "statusbar_button", onClick = function() call(bar._on_settings) end }
end, nil)

local Activity = ui.memo(function(p)
	local bar = p.bar
	local a = ui.useStore(bar._store, function(s) return s.activity end)
	return ui.HBox{ ref = bar._refs.activity_box, align = "center", gap = L.px(1), hidden = not a.shown,
		ui.Native{ handle = bar._activity_icon:widget() },
		ui.Button{ a.text, ref = bar._refs.activity_text, width = ui.useStore(bar._store, function(s) return s.activity_w end),
			align = "left", valign = "center", ellipsis = true, focusable = false, padding = { 4, 0 },
			role = "statusbar_button", tooltip = a.tip, onClick = function() call(bar._on_activity) end },
	}
end)

local StatusLine = ui.memo(function(p)
	local bar = p.bar
	local text = ui.useStore(bar._store, function(s) return s.status end)
	-- The literals are the Classic (no-override) look; every real theme restyles the bar
	-- through the statusbar/statusbar_text roles. The width is a floor, not a size: long
	-- text ends in an ellipsis, it doesn't widen the window.
	return ui.Label{ text, ref = bar._refs.label, grow = "x", width = 40, ellipsis = true,
		font = "Segoe UI, 9", fg = "60 60 60", role = "statusbar_text" }
end)

local CommandField = ui.memo(function(p)
	local bar = p.bar
	local w = ui.useStore(bar._store, function(s) return s.field_w end)
	local function command() call(bar._on_command) end
	return ui.Frame{ ref = bar._refs.field, title = "", size = { w, 24 }, grow = false, role = "commandbar",
		ui.HBox{ padding = { 2, 1 }, gap = 4, align = "center", grow = "x",
			ui.Button{ "Search or run a command", ref = bar._refs.command, focusable = true, imagePosition = "left",
				align = "left", valign = "center", spacing = 8, grow = "x", role = "commandbar_text", onClick = command },
			ui.Button{ "Ctrl+P", focusable = false, role = "keycap", onClick = command },
		},
	}
end)

local Logo = ui.memo(function(p)
	local bar = p.bar
	local logo = ui.useStore(bar._store, function(s) return s.logo end)
	return ui.HBox{ ref = bar._refs.logo_box, hidden = not logo.shown, align = "center", padding = { 6, 0 },
		-- the image stays while hidden: a mapped image label must stay an image label
		ui.Image{ ref = bar._refs.logo, tooltip = bar._logo_tip, padding = { 6, 0 }, align = "center", valign = "center",
			image = logo.image },
	}
end)

local Focus = ui.memo(function(p)
	local bar = p.bar
	local pane = ui.useStore(bar._store, function(s) return s.pane end)
	return ui.Button{ ref = bar._refs.focus, tooltip = pane.tip, focusable = true, size = { 32, 28 },
		role = "statusbar_button", enabled = pane.split, onClick = function() call(bar._on_focus) end }
end)

local function Bar(p)
	local bar = p.bar
	local revealed = ui.useStore(bar._store, function(s) return s.revealed end)
	local reveal = revealed and {
		hidden = revealed == 0, height = revealed, minSize = { 1, revealed }, maxSize = { 65535, revealed },
	} or { height = StatusBar.HEIGHT }
	return ui.HBox{ uniform = true, height = reveal.height, hidden = reveal.hidden,
		minSize = reveal.minSize, maxSize = reveal.maxSize,
		bg = "240 240 240", role = "statusbar", padding = 0, gap = 0, align = "center", grow = "x",
		ui.HBox{ grow = "x", align = "center", gap = 0,
			Settings{ bar = bar }, Activity{ bar = bar }, StatusLine{ bar = bar } },
		ui.HBox{ grow = "x", align = "center", ui.Spacer{}, CommandField{ bar = bar }, ui.Spacer{} },
		ui.HBox{ grow = "x", align = "center", gap = L.px(2), padding = { 8, 0 },
			ui.Spacer{},
			bar._has_logo and Logo{ bar = bar },
			-- extensions append their status elements here (HostAPI's status_box)
			ui.HBox{ ref = bar._refs.ext_box, gap = L.px(2), align = "center" },
			Focus{ bar = bar },
		},
	}
end

-- The class ------------------------------------------------------------------------------

--- @tparam table opts
-- @tparam table opts.iup
-- @tparam string opts.icon_dir the rasterized Carbon icons (assets/Icons)
function StatusBar.new(opts)
	local iup = opts.iup
	local self = setmetatable({ _iup = iup, _has_logo = opts.has_logo and true or false,
		_logo_tip = opts.logo_tip, _refs = {} }, StatusBar)
	for _, name in ipairs({ "settings", "activity_box", "activity_text", "label", "field", "command",
		"logo_box", "logo", "ext_box", "focus" }) do
		self._refs[name] = {}
	end
	-- Registered with HostAPI by core.ui.UpdateCheck for every installation.
	self._update_icon = StatusIcon.new(iup, {
		dir = opts.icon_dir, size = 16, state = "upd_complete", tip = StatusBar.UPDATE_STATES.current.tip,
	})
	local seed_name
	if self._has_logo then
		-- Seed IMAGE before Map even when the startup theme has no logo variant.
		self._logo_seed = iup.imagergba({ width = 1, height = 1, pixels = { 0, 0, 0, 0 } })
		logo_seed_seq = logo_seed_seq + 1
		seed_name = "LunarStatusLogoSeed_" .. logo_seed_seq
		iup.SetHandle(seed_name, self._logo_seed)
	end
	-- Background work, in place of a word that said nothing. Empty until there is some.
	-- The state matters even though nothing shows yet: IUP fixes a label as image or text
	-- when it maps, and one mapped without an image never draws one.
	self._activity_icon = StatusIcon.new(iup, { dir = opts.icon_dir, size = 16, state = "activity_ok" })
	local bar = self
	local activity_glyph = self._activity_icon:widget()
	function activity_glyph:button_cb(button, pressed)
		if button == iup.BUTTON1 and pressed == 0 and bar._on_activity then bar._on_activity() end
		return iup.DEFAULT
	end

	self._store = ui.createStore({
		status = "",
		activity = { shown = false, text = "" },
		activity_w = StatusBar.ACTIVITY_WIDTH,
		field_w = 320,
		logo = { shown = false, image = seed_name },
		pane = { split = false, tip = "Focus active pane / restore split (Esc to restore)" },
		revealed = nil,
	})
	-- Layout stays the caller's, as before: main.lua lays the window out after fit() and
	-- setReveal(); the bar refreshes only where it always did (see setActivity, setLogo).
	self._root = ui.mount(Bar, { iup = iup, props = { bar = self }, layout = "manual", theme = false })
	self._widget = self._root:widget()
	self._label = self._refs.label.current
	if opts.bind_icon then
		opts.bind_icon(self._refs.settings.current, "settings")
		opts.bind_icon(self._refs.command.current, "search")
		opts.bind_icon(self._refs.focus.current, "view")
	end
	return self
end

-- Write the store and render before returning. False when the render failed (a widget
-- destroyed under the bar); the failure is reported once by the root.
function StatusBar:_set(changes)
	if self._store:set(changes) then return self._root:flush() end
	return true
end

--- The bar itself.
function StatusBar:widget() return self._widget end
function StatusBar:commandWidget() return self._refs.field.current end
function StatusBar:onCommand(fn) self._on_command = fn end
function StatusBar:onSettings(fn) self._on_settings = fn end
--- Show the gear pressed while Settings is the page on screen.
-- Written straight to the widget on every call: the theme pass restyles the same
-- attribute, so it is not state this bar can diff against.
-- @tparam boolean selected
-- @tparam[opt] table colors the `statusbar_button`-style `{ bg, pressed }`
function StatusBar:setSettingsActive(selected, colors)
	colors = colors or {}
	self._iup.SetAttribute(self._refs.settings.current, "BGCOLOR", selected and colors.pressed or colors.bg)
end
function StatusBar:onFocus(fn) self._on_focus = fn end
function StatusBar:setPaneState(split, focused)
	self:_set({ pane = { split = split and true or false,
		tip = focused and "Restore split (Esc)" or "Focus active pane" } })
end
-- A store field holding a table is replaced on each write; skip writes that change nothing.
local function same(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

function StatusBar:fit(width)
	self._width = width
	local changes = {
		field_w = math.max(160, math.min(480, math.floor(width / 3) - 16)),
		activity_w = width < 1100 and 80 or StatusBar.ACTIVITY_WIDTH,
	}
	local logo = self:_logoState()
	if not same(logo, self._store:get().logo) then changes.logo = logo end
	self:_set(changes)
end

function StatusBar:_logoState()
	local cur = self._store:get().logo
	local shown = self._has_logo and self._logo_handle ~= nil and (not self._width or self._width >= 1000)
	return { shown = shown, image = self._logo_handle or cur.image }
end

function StatusBar:setLogo(handle)
	if not self._has_logo or self._logo_handle == handle then return end
	local iup = self._iup
	local image = handle and iup.GetHandle(handle)
	local size = image and (tostring(iup.GetAttribute(image, "WIDTH")) .. "x"
		.. tostring(iup.GetAttribute(image, "HEIGHT"))) or nil
	local resized = size ~= self._logo_size
	self._logo_handle, self._logo_size = handle, size
	local before = self._store:get().logo
	local logo = self:_logoState()
	self:_set({ logo = logo })
	if logo.shown ~= before.shown or resized then iup.Refresh(self._refs.logo_box.current)
	else iup.Update(self._refs.logo.current) end
end

--- Set what a click on the activity slot does.
function StatusBar:onActivity(fn) self._on_activity = fn end
--- Where the activity panel opens from: the bar's left end, which nothing pushes along.
function StatusBar:activityAnchor() return self._refs.settings.current end
--- The box extension status elements go in (HostAPI's `status_box`).
function StatusBar:extBox() return self._refs.ext_box.current end
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
	local icon = self._activity_icon
	-- A status bar that throws would surface as an error in whichever tool reported.
	pcall(function()
		if view and view.state == "running" then
			if not icon:isSpinning() then icon:startSpin() end
		elseif view then
			icon:stopSpin(ACTIVITY_GLYPHS[view.state])
		else
			icon:stopSpin()
		end
		local cur = self._store:get().activity
		local shown = view ~= nil
		local next_view = { shown = shown, text = cur.text, tip = cur.tip }
		if view then
			-- A flat button reads & as a mnemonic.
			next_view.text, next_view.tip = (view.text:gsub("&", "&&")), view.tip or ""
		end
		self:_set({ activity = next_view })
		if shown ~= cur.shown then self._iup.Refresh(self._refs.activity_box.current) end
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
	local ok, rendered = pcall(self._set, self, { status = tostring(msg) })
	if not (ok and rendered) then
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

--- Occupy a fraction of the bar's height without changing any content state.
function StatusBar:setReveal(progress)
	local height = math.floor(StatusBar.HEIGHT * progress + 0.5)
	self._revealed = height
	self:_set({ revealed = height })
end

--- How tall the bar is right now, for whatever shares the window's height with it. A
-- hidden bar's RASTERSIZE can't say: "x0" means no size set, not no height.
-- @treturn number|nil pixels, or nil before the first `setReveal`
function StatusBar:revealedHeight() return self._revealed end

return StatusBar
