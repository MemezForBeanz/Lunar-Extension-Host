--- The fade between two themes.
--
-- Rewriting every widget's colours once per frame is not an option: one theme pass
-- walks the whole tree. So this fades a picture instead. The window is captured and
-- laid over itself in the dialog's compositor, the theme changes once underneath it,
-- and the picture fades away. Every colour in the window appears to move together,
-- and each frame costs one layer alpha change.
--
-- Pressing again mid-fade keeps what is on screen: the half-faded picture stays over
-- a fresh capture, and the new picture fades from there, so nothing jumps.
--
-- With motion off, or where there is no compositor or capture, the theme just changes.
--
-- @classmod core.ui.ThemeTransition
local Compositor = require("core.lib.Compositor")

local ThemeTransition = {}
ThemeTransition.__index = ThemeTransition

local GROUP = "theme_transition"

--- @tparam table opts
-- @tparam function opts.compositor `fn() -> manager|nil`
-- @tparam table opts.motion `core.classes.MotionDirector`
function ThemeTransition.new(opts)
	return setmetatable({ _compositor = opts.compositor, _motion = opts.motion }, ThemeTransition)
end

--- Is a fade on screen?
function ThemeTransition:busy() return self._fade ~= nil end

local function release(snaps)
	for _, snap in ipairs(snaps) do pcall(snap.release, snap) end
end

function ThemeTransition:_end()
	local fade = self._fade
	if not fade then return end
	self._fade = nil
	fade.comp:remove(GROUP)
	fade.comp:commit()
	release(fade.snaps)
end

--- End any fade now and show the live window.
function ThemeTransition:settle()
	local fade = self._fade
	if fade and fade.handle then fade.handle:cancel() end
	self:_end()
end

function ThemeTransition:_manager()
	local ok, comp = pcall(self._compositor)
	if not ok or not comp then return nil end
	if not self._hooked then
		self._hooked = true
		-- The picture is only right at the size it was taken.
		comp:on("resize", function() self:settle() end)
		comp:on("dpi", function() self:settle() end)
	end
	return comp
end

--- Change the theme, faded where it can be.
-- @tparam function paint does the switch; called exactly once, before this returns
function ThemeTransition:run(paint)
	local comp = self._motion:enabled() and self:_manager() or nil
	local snap = comp and comp:snapshot()
	if not snap or snap.w <= 0 or snap.h <= 0 then
		if snap then release({ snap }) end
		self:settle()
		return paint()
	end

	-- Mid-fade: the older picture stays on top at the alpha it had reached.
	local previous = self._fade
	local sprites = { { kind = "image", snap = snap, x = 0, y = 0, alpha = 1 } }
	local snaps = { snap }
	if previous then
		if previous.handle then previous.handle:cancel() end
		local older = previous.snaps[1]
		sprites[2] = { kind = "image", snap = older, x = 0, y = 0, alpha = previous.alpha }
		snaps[2] = older
		for i = 2, #previous.snaps do pcall(previous.snaps[i].release, previous.snaps[i]) end
	end

	comp:set(GROUP, { z = Compositor.Z_THEME, sprites = sprites, regions = {}, opacity = 1 })
	comp:commit() -- on screen before the repaint begins, so the repaint is never seen
	local fade = { comp = comp, snaps = snaps, alpha = 1 }
	self._fade = fade
	local ok, err = pcall(paint)
	if not ok then
		self:_end()
		error(err, 0)
	end

	fade.handle = self._motion:animate({
		role = "theme_transition", from = 1, to = 0,
		on_frame = function(value)
			fade.alpha = value
			comp:setOpacity(GROUP, math.max(0, math.min(1, value)))
			comp:schedule(self._motion)
		end,
		on_done = function(completed)
			if completed and self._fade == fade then self:_end() end
		end,
	})
end

return ThemeTransition
