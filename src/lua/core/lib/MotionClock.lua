--- Monotonic clock and system motion preferences for the animation driver.
--
-- Animation timing needs three things Lua's standard library cannot supply on
-- Windows: a clock that measures *wall* time (not CPU time), sub-millisecond
-- resolution, and a guarantee that it never runs backwards. This module provides
-- them through `core.platform`, plus the two OS facilities the rest of the
-- motion system depends on: timer resolution and the reduced-motion setting.
--
-- ### Why not os.clock or os.time
--
-- `os.time()` has one-second resolution -- useless here. `os.clock()` on Windows
-- returns **processor** time, which diverges from wall time whenever the process
-- is descheduled; animations driven by it visibly stall under load and then jump.
-- The platform clock (`QueryPerformanceCounter` on Windows, `CLOCK_MONOTONIC` on
-- Linux) is a monotonic wall clock.
--
-- ### Why high timer resolution matters
--
-- IUP timers are `SetTimer`/`WM_TIMER` on Windows, and `WM_TIMER` cannot fire
-- faster than the system timer resolution -- 15.6 ms by default. A 16 ms animation
-- timer therefore lands on a ~15.6 ms cadence with irregular jitter, which is
-- exactly the frame pattern the eye reads as stutter. `timeBeginPeriod(1)` lowers
-- the resolution to 1 ms for the process, so the 16 ms timer actually fires near
-- 16 ms and 60 fps becomes reachable. (Linux needs nothing; the call is a no-op.)
--
-- This is a process-global setting with a real (small) power cost, so it is
-- **reference-counted**: raised on the first `acquireHighResolution()` and lowered
-- again once every holder has released it. The driver holds it only while
-- animations are actually running, never while idle.
--
-- The OS calls themselves live in `core.platform`; this module adds the motion
-- semantics (reference counting, the reduced-motion contract).
--
-- @module core.lib.MotionClock

local platform_ok, platform = pcall(require, "core.platform")
local clock = platform_ok and platform.clock or nil

local M = {}

--- True when a precise monotonic clock is in use.
M.available = clock ~= nil and clock.precise == true

--- Current monotonic time in seconds, as a float.
--
-- The absolute value is meaningless -- only differences between two readings are.
-- Guaranteed non-decreasing. Without a precise clock it counts whole wall-clock
-- seconds (never `os.clock`, which is CPU time and stands still while idle).
--
-- @treturn number Seconds since an arbitrary fixed origin.
-- @usage
--   local t0 = MotionClock.now()
--   -- ...
--   local elapsed = MotionClock.now() - t0
function M.now()
	if clock then return clock.now() end
	return os.time()
end

-- Reference count for the 1 ms timer resolution.
local hires_holders = 0

--- Raise the system timer resolution to 1 ms (reference-counted).
--
-- Pair every call with `releaseHighResolution()`. Nesting is safe; only the first
-- acquisition touches the system, and only the last release lowers it again.
--
-- @treturn boolean `true` if high resolution is now held.
-- @usage
--   MotionClock.acquireHighResolution()
--   -- ... run animations ...
--   MotionClock.releaseHighResolution()
function M.acquireHighResolution()
	if not M.available then return false end
	hires_holders = hires_holders + 1
	if hires_holders == 1 then pcall(clock.begin_high_resolution) end
	return true
end

--- Release one high-resolution-timer reference taken by `acquireHighResolution`.
-- Lowers the system timer resolution once the last holder releases.
-- @usage MotionClock.releaseHighResolution()
function M.releaseHighResolution()
	if not M.available then return end
	if hires_holders <= 0 then return end
	hires_holders = hires_holders - 1
	if hires_holders == 0 then pcall(clock.end_high_resolution) end
end

--- Does the operating system ask applications to reduce motion?
--
-- Windows: "Show animations in Windows" (Settings > Accessibility > Visual
-- effects). GNOME: `enable-animations`. A substantial number of users disable
-- this because motion causes them genuine discomfort -- vestibular disorders,
-- migraine triggers -- so honouring it is an accessibility obligation, not a
-- nicety. Re-read on every call (the user can change it while the app runs).
--
-- @treturn boolean `true` when the user has asked for reduced motion.
-- @usage if MotionClock.systemReducedMotion() then ... end
function M.systemReducedMotion()
	if not clock then return false end
	local ok, reduced = pcall(clock.reduced_motion)
	return ok and reduced == true
end

return M