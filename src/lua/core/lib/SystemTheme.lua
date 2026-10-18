--- "Match system theme": follow the operating system's light/dark mode.
--
-- While `theme_follow_system` is on, Lunar shows the user's light theme
-- (`theme_light`) when the system is in light mode and their dark theme
-- (`theme_dark`) when it is in dark mode, re-checking every few seconds so a
-- change in Windows' app mode or the desktop's color scheme carries over live.
--
-- Choosing a theme while matching (the Settings selector or the Theme menu) sets
-- the theme **for the current mode**, so there is one selector rather than two.
-- An org profile that locks `theme` also locks this: the profile's theme wins.
--
-- The system is asked through `core.platform.system_dark()`: Windows'
-- AppsUseLightTheme, and on Linux the XDG portal / GNOME color scheme / GTK theme
-- name. When it can't tell (nil), the current theme stays. Where asking means
-- running programs (Linux), the timer uses `system_dark_probe` instead, which
-- never blocks the UI: one probe at a time, advanced on each tick.
--
-- An org profile may also lock `theme_light` or `theme_dark` on their own; a
-- pick for a locked mode is refused, and the selector snaps back.
--
-- @classmod core.lib.SystemTheme

local SystemTheme = {}
SystemTheme.__index = SystemTheme

SystemTheme.DEFAULT_LIGHT = "classic"
SystemTheme.DEFAULT_DARK = "classic_dark"

--- Create the controller.
-- @tparam table opts
-- @tparam table opts.settings the `SettingsManager`
-- @tparam table opts.theme_manager the `ThemeManager`
-- @tparam function opts.system_dark `fn() -> true|false|nil` (`core.platform.system_dark`)
-- @tparam[opt] function opts.system_dark_probe `fn() -> probe|nil`, a non-blocking
--   query with `poll() -> done, dark` and `cancel()` (`core.platform.system_dark_probe`)
-- @param[opt] opts.iup the IUP binding, for the polling timer (`start`)
-- @tparam[opt=3000] number opts.interval_ms how often to re-check the system
-- @treturn SystemTheme
function SystemTheme.new(opts)
	local self = setmetatable({
		_settings = opts.settings,
		_themes = opts.theme_manager,
		_system_dark = opts.system_dark,
		_probe_fn = opts.system_dark_probe,
		_iup = opts.iup,
		_interval = opts.interval_ms or 3000,
		_mode = nil,       -- last mode seen: true dark, false light, nil unknown
	}, SystemTheme)
	return self
end

--- Is matching on (and allowed)?
-- @treturn boolean
function SystemTheme:enabled()
	local s = self._settings
	return s:get("theme_follow_system") == true and not (s.isLocked and s:isLocked("theme"))
end

--- Can the user turn matching on? False when an org profile locks the theme.
-- @treturn boolean
function SystemTheme:available()
	local s = self._settings
	return not (s.isLocked and s:isLocked("theme"))
end

--- The theme id to show in a mode.
-- @tparam boolean dark
-- @treturn string
function SystemTheme:themeFor(dark)
	local key = dark and "theme_dark" or "theme_light"
	return self._settings:get(key) or (dark and SystemTheme.DEFAULT_DARK or SystemTheme.DEFAULT_LIGHT)
end

-- Ask the system now (blocking; bounded by the platform). nil when it can't tell.
function SystemTheme:_ask()
	local ok, dark = pcall(self._system_dark)
	if ok then return dark end
	return nil
end

-- Show the theme for `dark` if the mode changed (or `force`).
function SystemTheme:_follow(dark, force)
	if not self:enabled() or dark == nil then return false end
	if dark == self._mode and not force then return false end
	self._mode = dark
	self._themes:apply(self:themeFor(dark))
	return true
end

--- Ask the system and apply the matching theme if the mode changed (or `force`).
-- @tparam[opt] boolean force apply even if the mode is the one last seen
-- @treturn boolean true when a theme was applied
function SystemTheme:sync(force)
	if not self:enabled() then return false end
	return self:_follow(self:_ask(), force)
end

--- One timer tick: with a non-blocking probe, start one or advance the one in
-- flight and act on its answer; otherwise `sync()`.
-- @treturn boolean true when a theme was applied
function SystemTheme:tick()
	if not self:enabled() then
		self:_cancelProbe()
		return false
	end
	if not self._probe_fn then return self:sync() end
	if not self._probe then
		local ok, probe = pcall(self._probe_fn)
		if not ok or not probe then return self:sync() end
		self._probe = probe
	end
	local ok, done, dark = pcall(self._probe.poll)
	if ok and not done then return false end
	self._probe = nil
	local seed = self._pending_seed
	self._pending_seed = nil
	if not ok then return false end
	if seed then
		-- Finishing a turn-on: seed the slot, then show this mode's theme.
		self:_seed(dark, seed)
		pcall(function() self._settings:save() end)
		return self:_follow(dark, true)
	end
	return self:_follow(dark)
end

function SystemTheme:_cancelProbe()
	if self._probe then
		pcall(self._probe.cancel)
		self._probe = nil
	end
	self._pending_seed = nil
end

--- Turn matching on or off (the Settings toggle). Turning it on applies the
-- system's mode at once; the current theme becomes the starting choice for
-- its mode, so turning it on never surprises the user with a theme they never picked.
-- @tparam boolean on
-- @treturn boolean false when the setting is locked or couldn't be saved
function SystemTheme:setEnabled(on)
	local s = self._settings
	if not self:available() then return false end
	local current = on and self._themes:current() or nil
	-- Where asking the system means running programs, don't block the click on
	-- it: start a probe and finish turning on when it answers (`tick`).
	local probe
	if on and self._probe_fn then
		local ok, p = pcall(self._probe_fn)
		if ok then probe = p end
	end
	local dark
	if on and not probe then
		dark = self:_ask()
		self:_seed(dark, current)
	end
	if not s:set("theme_follow_system", on == true) then
		if probe then pcall(probe.cancel) end
		return false
	end
	pcall(function() s:save() end)
	self._mode = nil
	self:_cancelProbe()
	if probe then
		self._probe, self._pending_seed = probe, current
		self:_setRate(SystemTheme.PROBE_TICK_MS)
	elseif on then
		self:_follow(dark, true)
	end
	return true
end

-- Seed the current mode's slot with the theme the user is looking at, so turning
-- matching on never swaps it for one they didn't pick (a slot the org locked
-- keeps its value: set refuses it).
function SystemTheme:_seed(dark, current)
	if dark == nil or not current then return end
	local t = self._themes.themeById and self._themes:themeById(current)
	local fits = (not t) or (t:isDark() == dark)
	if fits then self._settings:set(dark and "theme_dark" or "theme_light", current) end
end

--- A theme the user picked (Settings selector or Theme menu). While matching,
-- it becomes the theme for the current mode; otherwise it is simply applied.
-- @tparam string id
-- @treturn boolean false when the pick was refused (that mode's theme is locked)
function SystemTheme:choose(id)
	if self:enabled() then
		local dark = self._mode
		if dark == nil then dark = self:_ask() end
		if dark ~= nil then
			self._mode = dark
			local s = self._settings
			local key = dark and "theme_dark" or "theme_light"
			if (s.isLocked and s:isLocked(key)) or not s:set(key, id) then
				-- Put the selector and menu back on the theme on screen.
				if self._themes._syncControls then pcall(self._themes._syncControls, self._themes) end
				return false
			end
			pcall(function() s:save() end)
		end
	end
	self._themes:apply(id)
	return true
end

--- Start re-checking the system every `interval_ms` (needs `opts.iup`). The
-- check is skipped entirely while matching is off.
function SystemTheme:start()
	local iup = self._iup
	if not iup or self._timer then return end
	local me = self
	self._timer = iup.timer({ time = self._interval })
	self._rate = self._interval
	function self._timer.action_cb()
		pcall(me.tick, me)
		-- A probe in flight is advanced quickly; between checks, the slow rate.
		me:_setRate(me._probe and SystemTheme.PROBE_TICK_MS or me._interval)
		return iup.DEFAULT
	end
	self._timer.run = "YES"
end

--- How often a probe in flight is advanced, in milliseconds.
SystemTheme.PROBE_TICK_MS = 50

function SystemTheme:_setRate(ms)
	local t = self._timer
	if not t or self._rate == ms then return end
	self._rate = ms
	t.run = "NO"
	t.time = ms
	t.run = "YES"
end

--- Stop the timer (and any probe in flight).
function SystemTheme:stop()
	self:_cancelProbe()
	if self._timer then
		self._timer.run = "NO"
		if self._iup.Destroy then pcall(self._iup.Destroy, self._timer) end
		self._timer = nil
	end
end

return SystemTheme
