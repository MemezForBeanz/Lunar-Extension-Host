--- Cubic-bezier easing evaluation for the motion system.
--
-- Turns the `{x1, y1, x2, y2}` control points published by
-- `core.lib.MotionTokens` into a function `f(t) -> eased`, where `t` and the
-- result both run 0..1.
--
-- ### Why a lookup table
--
-- A CSS-style cubic bezier is a *parametric* curve: the control points define
-- `x(s)` and `y(s)` for a parameter `s`, but an animation needs `y` as a function
-- of `x` (elapsed fraction). There is no closed form, so every evaluation has to
-- numerically invert `x(s)` first.
--
-- This is the hottest path in the whole system -- it runs once per animation per
-- frame, so a handful of concurrent animations at 60 fps is thousands of
-- inversions a second, every second, while the user is also dragging something.
-- Doing Newton-Raphson each time is affordable but wasteful, and worse, it
-- allocates nothing predictable for the GC to ignore.
--
-- So each curve is sampled **once** into a fixed FFI `double[]` of `x` values at
-- evenly spaced `s`, and evaluation becomes a binary search plus two linear
-- interpolations: no iteration, no allocation, no garbage. The table is built
-- lazily on first use and cached forever -- there are only six Carbon curves, so
-- the cache is bounded by design.
--
-- When LuaJIT's FFI is unavailable the module falls back to a plain Lua table and
-- the same algorithm -- only the storage differs, the results are identical. Both
-- agree with the analytic solver to within `5e-5` across all six Carbon curves,
-- which is under a hundredth of a pixel on a 1000 px movement. That fallback is
-- what lets the busted suite exercise this module on any host, and the agreement
-- is pinned by `spec/motion_easing_spec.lua`.
--
-- @module core.lib.MotionEasing

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

--- True when the FFI-backed (allocation-free) sample table is in use.
M.ffi = ffi ~= nil

-- Samples per curve. 256 intervals puts the sampling error well below a single
-- pixel for any animation shorter than the screen, and the whole table is 2 KB --
-- small enough to stay resident in L1 across a frame.
local SAMPLES = 256

local double_array = ffi and ffi.typeof("double[?]") or nil

-- Bezier basis with P0=(0,0) and P3=(1,1), so only the two middle control points
-- are free. Expanded from the standard form to keep the inner loop free of pow().
local function bezier(t, a1, a2)
	local inv = 1 - t
	return 3 * inv * inv * t * a1 + 3 * inv * t * t * a2 + t * t * t
end

local cache = {}

local function cache_key(x1, y1, x2, y2)
	return string.format("%.6f:%.6f:%.6f:%.6f", x1, y1, x2, y2)
end

-- Build the s -> x sample table for one curve.
local function build_samples(x1, x2)
	local n = SAMPLES + 1
	local samples
	if double_array then
		samples = double_array(n)
	else
		samples = {}
	end
	local base = double_array and 0 or 1
	for i = 0, SAMPLES do
		samples[base + i] = bezier(i / SAMPLES, x1, x2)
	end
	return samples, base
end

--- Build (or fetch from cache) an easing function for four bezier control points.
--
-- The returned function is pure, allocation-free and safe to call from a timer
-- callback. It clamps its input, so callers do not need to guard the final frame
-- of an animation against floating-point overshoot.
--
-- Linear motion (`0,0,1,1`) short-circuits to the identity function: it appears
-- unnatural to the eye and Carbon does not use it, but it is genuinely useful for
-- non-visual interpolation, so it is supported rather than forbidden.
--
-- @tparam number x1 First control point X (0..1).
-- @tparam number y1 First control point Y.
-- @tparam number x2 Second control point X (0..1).
-- @tparam number y2 Second control point Y.
-- @treturn function `f(t) -> eased`, both 0..1.
-- @usage
--   local ease = MotionEasing.curve(0.2, 0, 0.38, 0.9)   -- standard productive
--   local v = from + (to - from) * ease(elapsed / duration)
function M.curve(x1, y1, x2, y2)
	x1 = tonumber(x1) or 0
	y1 = tonumber(y1) or 0
	x2 = tonumber(x2) or 1
	y2 = tonumber(y2) or 1

	local key = cache_key(x1, y1, x2, y2)
	local hit = cache[key]
	if hit then return hit end

	local fn
	if x1 == 0 and y1 == 0 and x2 == 1 and y2 == 1 then
		fn = function(t)
			if t <= 0 then return 0 end
			if t >= 1 then return 1 end
			return t
		end
	else
		local samples, base = build_samples(x1, x2)
		local step = 1 / SAMPLES

		fn = function(t)
			if t <= 0 then return 0 end
			if t >= 1 then return 1 end

			-- Binary search for the sample interval bracketing t on the x axis.
			-- Samples are monotonic in x for any valid curve (x1, x2 within 0..1),
			-- which is what makes the search legitimate.
			local lo, hi = 0, SAMPLES
			while hi - lo > 1 do
				local mid = (lo + hi)
				mid = (mid - mid % 2) / 2
				if samples[base + mid] <= t then lo = mid else hi = mid end
			end

			local x_lo = samples[base + lo]
			local x_hi = samples[base + hi]
			local span = x_hi - x_lo
			-- A flat interval means the curve is vertical here; any s in the
			-- interval is as correct as another, so take the left edge.
			local frac = (span > 0) and ((t - x_lo) / span) or 0
			local s = (lo + frac) * step

			return bezier(s, y1, y2)
		end
	end

	cache[key] = fn
	return fn
end

--- Build an easing function from a `{x1, y1, x2, y2}` array.
-- Convenience wrapper for the tables `core.lib.MotionTokens` publishes.
-- @tparam table points Four-element control-point array.
-- @treturn function `f(t) -> eased`.
-- @usage local ease = MotionEasing.fromPoints(MotionTokens.easing("exit"))
function M.fromPoints(points)
	if type(points) ~= "table" then
		return M.curve(0, 0, 1, 1)
	end
	return M.curve(points[1], points[2], points[3], points[4])
end

--- Evaluate a bezier curve analytically, without the sample table.
--
-- Slower than `curve()` (it iterates), and intended for verification rather than
-- animation: `spec/motion_easing_spec.lua` uses it as the independent reference
-- the sample table is checked against.
--
-- @tparam number t Input, 0..1.
-- @tparam number x1 First control point X.
-- @tparam number y1 First control point Y.
-- @tparam number x2 Second control point X.
-- @tparam number y2 Second control point Y.
-- @treturn number Eased output, 0..1.
function M.solve(t, x1, y1, x2, y2)
	if t <= 0 then return 0 end
	if t >= 1 then return 1 end

	-- Newton-Raphson on x(s) - t, falling back to bisection when the derivative
	-- is too flat to trust (which happens near a vertical segment of the curve).
	local s = t
	for _ = 1, 8 do
		local x = bezier(s, x1, x2) - t
		if math.abs(x) < 1e-7 then
			return bezier(s, y1, y2)
		end
		local inv = 1 - s
		local d = 3 * inv * inv * x1 + 6 * inv * s * (x2 - x1) + 3 * s * s * (1 - x2)
		if math.abs(d) < 1e-7 then break end
		s = s - x / d
	end

	local lo, hi = 0, 1
	s = t
	for _ = 1, 60 do
		local x = bezier(s, x1, x2)
		if math.abs(x - t) < 1e-9 then break end
		if x < t then lo = s else hi = s end
		s = (lo + hi) / 2
	end
	return bezier(s, y1, y2)
end

return M
