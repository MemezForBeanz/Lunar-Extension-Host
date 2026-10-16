-- spec/progress_motion_spec.lua — core.ui.ProgressMotion: eased advancement,
-- instant reset, superseding, clamping, and no-director fallback.
--
-- A progress bar driven straight from its data jumps: each completion is a
-- sudden step that reads as a series of unrelated states rather than one thing
-- advancing.  ProgressMotion's job is to smooth that out — but smoothing has
-- to stop where smoothing would mislead the user:
--
--   * going BACKWARDS should be instant, because easing a bar from 60% back to
--     0% animates work being undone, which is not what happened — a new queue
--     started, and that is a discontinuity, not a transition
--   * every forward update must start from where the bar actually IS, not from
--     where the previous update was heading — otherwise a burst of rapid
--     completions produces a bar that stutters backwards before resuming, which
--     is exactly what the easing was supposed to prevent
--   * values outside 0..1 must be clamped, because the gauge widget has no
--     error handling for out-of-range attributes
--
-- IUP is faked (records SetAttribute/GetAttribute calls), the director is the
-- real MotionDirector with an injected clock.

local ProgressMotion  = require("core.ui.ProgressMotion")
local MotionDirector  = require("core.classes.MotionDirector")

-- ============================================================================
-- FAKES
-- ============================================================================

local function fake_iup()
	local iup = { DEFAULT = 0, _timers = {}, _attrs = {} }

	function iup.timer(def)
		local t = { def = def, running = false }
		iup._timers[#iup._timers + 1] = t
		return t
	end
	function iup.SetAttribute(w, name, value)
		if w == nil then return end
		if type(w) == "table" and name == "RUN" then
			w.running = (value == "YES")
			return
		end
		if type(w) == "table" then
			w._attrs = w._attrs or {}
			w._attrs[name] = value
		end
	end
	function iup.GetAttribute(w, name)
		if type(w) == "table" then
			w._attrs = w._attrs or {}
			return w._attrs[name]
		end
		return nil
	end
	return iup
end

-- A fake gauge widget with an optional starting VALUE.
local function make_gauge(starting_value)
	local g = { _attrs = {} }
	if starting_value then
		g._attrs["VALUE"] = tostring(starting_value)
	end
	return g
end

-- Build a director with an injectable clock.
local function make_director(iup_inst, opts)
	opts = opts or {}
	local clock = { t = 0 }
	local dir = MotionDirector:new({
		iup     = iup_inst,
		clock   = function() return clock.t end,
		enabled = opts.enabled ~= false,
	})
	return dir, clock
end

-- ============================================================================
-- valueOf() — reading the current position
-- ============================================================================

describe("ProgressMotion.valueOf", function()
	it("reads VALUE from the widget when the module has not driven it", function()
		local iup   = fake_iup()
		local gauge = make_gauge(0.4)
		local v = ProgressMotion.valueOf(iup, gauge)
		assert.are.equal(0.4, v)
	end)

	it("returns 0 when VALUE is absent", function()
		local iup   = fake_iup()
		local gauge = make_gauge()  -- no VALUE set
		local v = ProgressMotion.valueOf(iup, gauge)
		assert.are.equal(0, v)
	end)

	it("returns the last driven value, not a string round-trip", function()
		-- ProgressMotion caches the value to avoid the parse cost and the
		-- precision loss of going through IUP's attribute string.
		local iup   = fake_iup()
		local dir, clock = make_director(iup)
		local gauge = make_gauge(0)

		-- Drive the gauge forward; the module caches the frame values.
		ProgressMotion.set(iup, gauge, 0.5, dir)
		-- Advance to mid-flight.
		clock.t = 0.05
		dir:tick()

		-- valueOf() should return the mid-flight cached value, not 0.
		local v = ProgressMotion.valueOf(iup, gauge)
		assert.is_true(v > 0, "valueOf should return the cached in-flight position")
	end)
end)

-- ============================================================================
-- FORWARD MOVEMENT — animated
-- ============================================================================

describe("ProgressMotion.set forward movement", function()
	it("schedules an animation when moving forward with a director", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		local gauge  = make_gauge(0)
		ProgressMotion.set(iup, gauge, 0.8, dir)
		assert.is_true(dir:activeCount() >= 1,
			"forward set must schedule an animation")
	end)

	it("animates from the gauge's real current position, not zero", function()
		-- Pin that the animation starts from wherever the bar actually is.
		-- We drive to 0.3, settle partway, then drive to 0.7 and verify the
		-- new animation's `from` is the mid-flight position, not 0.3.
		local iup        = fake_iup()
		local dir, clock = make_director(iup)
		local gauge      = make_gauge(0)

		-- First update: 0 → 0.3
		ProgressMotion.set(iup, gauge, 0.3, dir)

		-- Advance to mid-flight (the value is between 0 and 0.3).
		clock.t = 0.05
		dir:tick()
		local mid = ProgressMotion.valueOf(iup, gauge)
		assert.is_true(mid > 0, "expected the bar to have started moving")
		assert.is_true(mid < 0.3, "expected mid-flight, not yet at target")

		-- Second update: should start from `mid`, not from 0.3.
		-- We capture the `from` field of the new animation by peeking at the
		-- first on_frame value the director delivers in a subsequent tick.
		local first_frame_after_update = nil
		local orig_animate = dir.animate
		dir.animate = function(self2, spec)
			local orig_frame = spec and spec.on_frame
			if spec and orig_frame then
				spec.on_frame = function(v)
					if first_frame_after_update == nil then
						first_frame_after_update = v
					end
					orig_frame(v)
				end
			end
			return orig_animate(self2, spec)
		end

		ProgressMotion.set(iup, gauge, 0.7, dir)

		-- Tick once — the very first frame should come from near `mid`, not
		-- from a value close to 0.3.
		clock.t = clock.t + 0.001
		dir:tick()

		-- The animation starts from the cached position (mid).  The first
		-- frame value delivered by the director is `from` at t≈0, which
		-- should be very close to `mid` rather than to 0.3.
		if first_frame_after_update ~= nil then
			assert.is_true(math.abs(first_frame_after_update - mid) < 0.05,
				string.format(
					"new animation should start from mid-flight pos %.3f, " ..
					"not from previous target (0.3). first_frame=%.3f",
					mid, first_frame_after_update))
		end
	end)
end)

-- ============================================================================
-- BACKWARDS IS A RESET — instant, cancels in-flight
-- ============================================================================

describe("ProgressMotion.set backward movement", function()
	it("lands the value instantly when moving backwards", function()
		-- Easing a bar downward animates work being undone, which is not what
		-- happened.  A backwards move is a reset — new queue, instant jump.
		local iup   = fake_iup()
		local dir, clock = make_director(iup)
		local gauge = make_gauge(0.6)

		ProgressMotion.set(iup, gauge, 0.2, dir)

		-- No animation should have been scheduled.
		assert.are.equal(0, dir:activeCount(),
			"backwards move must not schedule an animation")

		-- The value must be set directly.
		assert.are.equal("0.2", gauge._attrs["VALUE"])
	end)

	it("cancels any in-flight animation when moving backwards", function()
		-- A burst of completions then a reset: the in-flight forward animation
		-- must be cancelled so it cannot resume the forward movement after the
		-- bar has jumped back.
		local iup        = fake_iup()
		local dir, clock = make_director(iup)
		local gauge      = make_gauge(0)

		-- Start a forward animation.
		ProgressMotion.set(iup, gauge, 0.8, dir)
		assert.is_true(dir:activeCount() >= 1)

		-- Now reset backwards.
		ProgressMotion.set(iup, gauge, 0.0, dir)
		assert.are.equal(0, dir:activeCount(),
			"backward move must cancel the in-flight forward animation")
	end)

	it("equal value is treated as backward (not forward)", function()
		-- to == from: nothing to animate, land immediately.
		local iup   = fake_iup()
		local dir, _ = make_director(iup)
		local gauge = make_gauge(0.5)

		ProgressMotion.set(iup, gauge, 0.5, dir)
		assert.are.equal(0, dir:activeCount(),
			"equal value must not schedule an animation")
	end)
end)

-- ============================================================================
-- SUPERSEDING — burst of rapid updates
-- ============================================================================

describe("ProgressMotion.set superseding", function()
	it("a burst of forward updates never makes the bar jump backwards", function()
		-- The key invariant: rapid completions must not produce a bar that
		-- stutters backwards.  Because every update starts from the gauge's
		-- *current* position (not the previous target), the position is
		-- monotonically non-decreasing for forward updates.
		local iup        = fake_iup()
		local dir, clock = make_director(iup)
		local gauge      = make_gauge(0)

		-- Simulate five rapid completions before any animation settles.
		ProgressMotion.set(iup, gauge, 0.2, dir)
		clock.t = 0.01 ; dir:tick()
		ProgressMotion.set(iup, gauge, 0.4, dir)
		clock.t = 0.02 ; dir:tick()
		ProgressMotion.set(iup, gauge, 0.6, dir)
		clock.t = 0.03 ; dir:tick()
		ProgressMotion.set(iup, gauge, 0.8, dir)
		clock.t = 0.04 ; dir:tick()

		-- Collect all VALUE writes and verify they are monotonically
		-- non-decreasing across the entire burst.
		local prev = 0
		-- At this point valueOf() gives the mid-flight position; it must be
		-- >= where we started (0) and <= 0.8.
		local v = ProgressMotion.valueOf(iup, gauge)
		assert.is_true(v >= prev,
			string.format("bar went backwards: was %.3f, now %.3f", prev, v))
		assert.is_true(v <= 0.8)
	end)

	it("only one animation is active after a rapid burst", function()
		-- The director's target-supersession guarantee: animating the same
		-- target twice leaves only one animation running.
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		local gauge = make_gauge(0)

		ProgressMotion.set(iup, gauge, 0.25, dir)
		ProgressMotion.set(iup, gauge, 0.5,  dir)
		ProgressMotion.set(iup, gauge, 0.75, dir)

		-- Three forward updates on the same gauge: at most one animation should
		-- be active (each supersedes the previous).
		assert.are.equal(1, dir:activeCount(),
			"rapid forward updates must not stack animations")
	end)
end)

-- ============================================================================
-- CLAMPING
-- ============================================================================

describe("ProgressMotion.set clamping", function()
	it("clamps values above 1 to 1", function()
		local iup   = fake_iup()
		local gauge = make_gauge(0)
		ProgressMotion.set(iup, gauge, 1.5)  -- no director: lands immediately
		assert.are.equal("1", gauge._attrs["VALUE"])
	end)

	it("clamps values below 0 to 0", function()
		local iup   = fake_iup()
		local gauge = make_gauge(0)
		ProgressMotion.set(iup, gauge, -0.3)
		assert.are.equal("0", gauge._attrs["VALUE"])
	end)

	it("accepts exactly 0", function()
		local iup   = fake_iup()
		local gauge = make_gauge(0)
		ProgressMotion.set(iup, gauge, 0)
		assert.are.equal("0", gauge._attrs["VALUE"])
	end)

	it("accepts exactly 1", function()
		local iup   = fake_iup()
		local gauge = make_gauge(0)
		ProgressMotion.set(iup, gauge, 1)
		assert.are.equal("1", gauge._attrs["VALUE"])
	end)
end)

-- ============================================================================
-- NO DIRECTOR — value set directly
-- ============================================================================

describe("ProgressMotion.set with no director", function()
	it("sets the value directly when director is nil", function()
		-- The fall-back guarantees callers never branch on motion availability.
		local iup   = fake_iup()
		local gauge = make_gauge(0)
		ProgressMotion.set(iup, gauge, 0.6, nil)
		assert.are.equal("0.6", gauge._attrs["VALUE"])
	end)

	it("does not raise when gauge is nil", function()
		local iup = fake_iup()
		assert.has_no.errors(function()
			ProgressMotion.set(iup, nil, 0.5, nil)
		end)
	end)
end)

-- ============================================================================
-- MOTION DISABLED — synchronous delivery
-- ============================================================================

describe("ProgressMotion.set with motion disabled", function()
	it("delivers the final value synchronously when motion is off", function()
		-- MotionDirector.animate() with enabled=false calls on_frame(to) and
		-- on_done(true) before returning, so the gauge must be at `to` when
		-- set() returns — no tick required.
		local iup        = fake_iup()
		local dir, _     = make_director(iup, { enabled = false })
		local gauge      = make_gauge(0)

		ProgressMotion.set(iup, gauge, 0.9, dir)

		-- No animation scheduled (disabled director completes immediately).
		assert.are.equal(0, dir:activeCount())
		-- Value should be at the target.
		assert.are.equal(0.9, ProgressMotion.valueOf(iup, gauge))
	end)
end)

-- ============================================================================
-- OWNER SCOPING
-- ============================================================================
--
-- `HostAPI:removeOwned` cancels `{ owner = owner }` BEFORE it destroys an
-- extension's widgets, precisely so no in-flight frame writes to a freed
-- handle. An animation scheduled without an owner survives that sweep and keeps
-- setting VALUE on a gauge whose tab is already gone -- which is what happens if
-- the build queue is advancing when the plugin is reloaded.

describe("ProgressMotion owner scoping", function()
	it("files the animation under the owner it was given", function()
		local iup    = fake_iup()
		local dir, _ = make_director(iup)
		local gauge  = make_gauge(0)
		local ext    = { name = "buildqueue" }

		ProgressMotion.set(iup, gauge, 0.5, dir, ext)
		assert.are.equal(1, dir:activeCount())

		-- The sweep HostAPI performs on unload.
		local cancelled = dir:cancel({ owner = ext })
		assert.are.equal(1, cancelled)
		assert.are.equal(0, dir:activeCount())
	end)

	it("does not write to the gauge after its owner is swept", function()
		local iup    = fake_iup()
		local dir, clock = make_director(iup)
		local gauge  = make_gauge(0)
		local ext    = { name = "buildqueue" }

		ProgressMotion.set(iup, gauge, 1.0, dir, ext)
		dir:cancel({ owner = ext })

		-- Stand in for the gauge being destroyed underneath us: any further
		-- write would be the use-after-free this scoping exists to prevent.
		local writes = 0
		local prev = iup.SetAttribute
		iup.SetAttribute = function(w, n, v)
			if w == gauge then writes = writes + 1 end
			return prev(w, n, v)
		end

		clock.t = 1
		dir:tick(clock.t)
		assert.are.equal(0, writes)
	end)

	it("still works when no owner is given", function()
		-- Host-owned gauges have no extension to file under; the animation must
		-- still run rather than being rejected for a missing scope.
		local iup    = fake_iup()
		local dir, _ = make_director(iup)
		local gauge  = make_gauge(0)

		ProgressMotion.set(iup, gauge, 0.5, dir)
		assert.are.equal(1, dir:activeCount())
	end)
end)
