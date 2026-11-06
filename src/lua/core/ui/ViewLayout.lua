--- Remembered shell visibility, animated by the host's shared motion director.
local winbatch = require("core.lib.winbatch")
local Layout = {}
Layout.__index = Layout

function Layout.new(opts)
	local settings = opts.settings
	local self = setmetatable({ _iup = opts.iup, _root = opts.root, _motion = opts.motion,
		_settings = settings, _rail = opts.rail, _status = opts.status, _terminal = opts.terminal,
		_listeners = {}, _bars = not settings or settings:get("view_bars_visible") ~= false,
		_open = settings and settings:get("terminal_open") == true or false,
		_height = math.max(120, math.min(900, tonumber(settings and settings:get("terminal_height")) or 260)),
		_bar_target = {}, _terminal_target = {} }, Layout)
	self._bar_progress = self._bars and 1 or 0
	self._terminal_height = self._open and self._height or 0
	self:_barsFrame(self._bar_progress)
	self:_terminalFrame(self._terminal_height)
	return self
end

function Layout:barsVisible() return self._bars end
function Layout:terminalVisible() return self._open end
function Layout:onChange(fn)
	self._listeners[#self._listeners + 1] = fn
	return function()
		for i, listener in ipairs(self._listeners) do if listener == fn then table.remove(self._listeners, i); break end end
	end
end
function Layout:_changed(key, value)
	if self._settings then self._settings:set(key, value); self._settings:save() end
	for _, fn in ipairs(self._listeners) do pcall(fn, self) end
end
function Layout:_refresh(fn)
	winbatch.batch(self._iup, self._root, function()
		fn()
		if self._root then self._iup.Refresh(self._root) end
	end)
end
--- Say what to recompute when the status bar's height changes: the page's height cap
-- comes from it, and the page can't grow into space the cap doesn't allow.
-- @tparam function fn
function Layout:setBudget(fn) self._budget = fn end
function Layout:_barsFrame(value)
	self._bar_progress = value
	self:_refresh(function()
		self._rail:setReveal(value)
		self._status:setReveal(value)
		if self._budget then self._budget() end
	end)
end
function Layout:_terminalFrame(value)
	self._terminal_height = value
	self:_refresh(function() self._terminal:setHeight(value) end)
end
function Layout:_animate(target, from, to, frame)
	if self._motion then
		self._motion:animate({ target = target, from = from, to = to, distance = math.abs(to - from),
			curve = "standard", on_frame = frame })
	else frame(to) end
end
function Layout:toggleBars()
	self._bars = not self._bars
	self:_changed("view_bars_visible", self._bars)
	local from = self._bar_progress
	if self._motion then
		self._motion:animate({ target = self._bar_target, from = from, to = self._bars and 1 or 0,
			distance = 176 * math.abs((self._bars and 1 or 0) - from), curve = "standard",
			on_frame = function(v) self:_barsFrame(v) end })
	else self:_barsFrame(self._bars and 1 or 0) end
end
function Layout:toggleTerminal()
	self._open = not self._open
	self:_changed("terminal_open", self._open)
	self:_animate(self._terminal_target, self._terminal_height, self._open and self._height or 0,
		function(v) self:_terminalFrame(v) end)
	if self._open and self._terminal.focus then self._terminal:focus() end
end
function Layout:setTerminalHeight(height)
	self._height = math.max(120, math.min(900, math.floor(height + 0.5)))
	if self._motion then self._motion:cancel({ target = self._terminal_target }) end
	if self._open then self:_terminalFrame(self._height) end
end
function Layout:saveTerminalHeight()
	if self._settings then self._settings:set("terminal_height", self._height); self._settings:save() end
end
function Layout:terminalHeight() return self._height end
return Layout
