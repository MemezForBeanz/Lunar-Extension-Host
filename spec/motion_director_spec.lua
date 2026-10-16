-- spec/motion_director_spec.lua — core.classes.MotionDirector, the animation driver.
--
-- The director is the single choke point every animation in the app passes
-- through, so its guarantees are load-bearing:
--
--   * disabling motion completes animations at their END value, synchronously —
--     otherwise the off-switch strands widgets mid-flight, and a "reduce motion"
--     setting that leaves the UI half-animated is worse than no setting at all
--   * progress is driven by the CLOCK, not by a frame count — a driver that
--     stretches under load slows the UI down exactly when it is already busy
--   * one timer, stopped when idle — an animation system that keeps a 60 Hz timer
--     running forever is a battery bug
--   * scheduling on a target supersedes what was already running on it — without
--     it, clicking rapidly between tabs stacks animations fighting over the same
--     pixels
--
-- IUP is faked and the clock is injected, so every one of those is tested
-- deterministically rather than by sleeping and hoping.

local MotionDirector = require("core.classes.MotionDirector")
local Easing = require("core.lib.MotionEasing")
local Tokens = require("core.lib.MotionTokens")

-- A fake IUP exposing only what the director touches: timer creation and the RUN
-- attribute. Timers are collected so tests can assert on the driver's lifecycle.
local function fake_iup()
	local timers = {}
	local iup = { DEFAULT = 0, _timers = timers }
	function iup.timer(def)
		local t = { def = def, running = (def and def.RUN == "YES") or false }
		timers[#timers + 1] = t
		return t
	end
	function iup.SetAttribute(w, name, value)
		if name == "RUN" then w.running = (value == "YES") end
	end
	return iup
end

-- A director with a clock the test drives by hand.
local function make(opts)
	opts = opts or {}
	local clock = { t = 0 }
	local iup = fake_iup()
	opts.iup = iup
	opts.clock = function() return clock.t end
	return MotionDirector:new(opts), clock, iup
end

describe("MotionDirector interpolation", function()
	it("interpolates from `from` to `to` through the eased curve", function()
		local dir, clock = make()
		local seen
		dir:animate({
			duration = 100, from = 0, to = 100,
			curve = "standard", style = "productive",
			on_frame = function(v) seen = v end,
		})

		clock.t = 0.05
		dir:tick()

		local points = Tokens.easing("standard", "productive")
		local want = 100 * Easing.solve(0.5, points[1], points[2], points[3], points[4])
		-- Same tolerance the easing spec pins the sample table to: this test is
		-- about the director wiring the curve in correctly, not about the curve's
		-- own precision, which is covered there.
		assert.is_true(math.abs(seen - want) < 5e-3)
	end)

	it("delivers exactly `to` on the final frame", function()
		local dir, clock = make()
		local last
		dir:animate({ duration = 100, from = 7, to = 42, on_frame = function(v) last = v end })
		clock.t = 0.2
		dir:tick()
		assert.are.equal(42, last)
	end)

	it("reports completion through on_done", function()
		local dir, clock = make()
		local completed
		dir:animate({ duration = 100, on_done = function(c) completed = c end })
		clock.t = 0.2
		dir:tick()
		assert.is_true(completed)
	end)

	it("honours a delay before the first frame", function()
		local dir, clock = make()
		local fired = false
		dir:animate({ duration = 100, delay = 50, on_frame = function() fired = true end })

		clock.t = 0.02
		dir:tick()
		assert.is_false(fired)

		clock.t = 0.08
		dir:tick()
		assert.is_true(fired)
	end)

	it("derives a Carbon duration from `distance` when none is given", function()
		local dir, clock = make()
		local done = false
		-- Tokens.duration(0) is fast_02 (110ms), so this must not be finished at
		-- 80ms and must be finished by 120ms.
		dir:animate({ distance = 0, on_done = function() done = true end })
		clock.t = 0.08
		dir:tick()
		assert.is_false(done)
		clock.t = 0.12
		dir:tick()
		assert.is_true(done)
	end)
end)

describe("MotionDirector timing under load", function()
	it("is time-based, not frame-based", function()
		-- The point of the whole design. Two frames instead of fifteen must still
		-- finish on schedule; a frame-counting driver would run four times too long
		-- precisely when the app is already struggling.
		local dir, clock = make()
		local last
		dir:animate({ duration = 240, from = 0, to = 1, on_frame = function(v) last = v end })

		clock.t = 0.05
		dir:tick()
		clock.t = 0.24
		dir:tick()

		assert.are.equal(0, dir:activeCount())
		assert.are.equal(1, last)
	end)

	it("lands completed after a stall longer than the animation", function()
		-- After a multi-second freeze the user has lost all context; starting a
		-- 240ms slide *then* is more disorienting than arriving already settled.
		local dir, clock = make()
		local completed
		dir:animate({ duration = 240, on_done = function(c) completed = c end })
		clock.t = 0.016
		dir:tick()
		clock.t = 8.0
		dir:tick()
		assert.are.equal(0, dir:activeCount())
		assert.is_true(completed)
	end)
end)

describe("MotionDirector timer lifecycle", function()
	it("starts one shared timer and reuses it for every animation", function()
		local dir, clock, iup = make()
		dir:animate({ duration = 100 })
		dir:animate({ duration = 100 })
		dir:animate({ duration = 100 })
		assert.are.equal(1, #iup._timers)
		assert.is_true(iup._timers[1].running)
		clock.t = 1
		dir:tick()
	end)

	it("stops the timer once nothing is running", function()
		local dir, clock, iup = make()
		dir:animate({ duration = 100 })
		assert.is_true(iup._timers[1].running)

		clock.t = 0.2
		dir:tick()
		assert.are.equal(0, dir:activeCount())
		assert.is_false(iup._timers[1].running)
	end)

	it("restarts the same timer for a later animation", function()
		local dir, clock, iup = make()
		dir:animate({ duration = 100 })
		clock.t = 0.2
		dir:tick()
		assert.is_false(iup._timers[1].running)

		dir:animate({ duration = 100 })
		assert.are.equal(1, #iup._timers)
		assert.is_true(iup._timers[1].running)
	end)
end)

describe("MotionDirector cancellation", function()
	it("supersedes an animation already running on the same target", function()
		local dir = make()
		local target = {}
		local first_result
		dir:animate({ duration = 500, target = target, on_done = function(c) first_result = c end })
		dir:animate({ duration = 500, target = target })

		assert.are.equal(1, dir:activeCount())
		-- Superseded, not completed: the value it was heading for is no longer
		-- wanted, so delivering it would fight the replacement animation.
		assert.is_false(first_result)
	end)

	it("cancels by tag without delivering the end value", function()
		local dir = make()
		local seen
		dir:animate({ duration = 500, tag = "a", from = 0, to = 9, on_frame = function(v) seen = v end })
		dir:animate({ duration = 500, tag = "b" })

		assert.are.equal(1, dir:cancel({ tag = "a" }))
		assert.is_nil(seen)
		assert.are.equal(1, dir:activeCount())
	end)

	it("cancels by owner, which is how an unloading extension is cleaned up", function()
		local dir = make()
		local ext = {}
		dir:animate({ duration = 500, owner = ext })
		dir:animate({ duration = 500, owner = ext })
		dir:animate({ duration = 500 })

		assert.are.equal(2, dir:cancel({ owner = ext }))
		assert.are.equal(1, dir:activeCount())
	end)

	it("requires every field of a filter to match", function()
		local dir = make()
		local ext = {}
		dir:animate({ duration = 500, tag = "x", owner = ext })
		assert.are.equal(0, dir:cancel({ tag = "x", owner = {} }))
		assert.are.equal(1, dir:activeCount())
	end)

	it("finishes at the end value when asked to complete rather than cancel", function()
		local dir = make()
		local seen, completed
		dir:animate({
			duration = 500, from = 0, to = 33,
			on_frame = function(v) seen = v end,
			on_done = function(c) completed = c end,
		})
		dir:finishAll()
		assert.are.equal(33, seen)
		assert.is_true(completed)
		assert.are.equal(0, dir:activeCount())
	end)

	it("reports cancellation through the handle", function()
		local dir = make()
		local h = dir:animate({ duration = 500 })
		assert.is_false(h:done())
		h:cancel()
		assert.is_true(h:done())
		assert.is_false(h.completed)
	end)
end)

describe("MotionDirector disabled mode", function()
	it("delivers the end value synchronously and completes", function()
		-- The guarantee that makes the off-switch trustworthy: callers never have
		-- to set the final state themselves or branch on whether motion is on.
		local dir, _, iup = make({ enabled = false })
		local seen, completed
		local h = dir:animate({
			duration = 500, from = 0, to = 88,
			on_frame = function(v) seen = v end,
			on_done = function(c) completed = c end,
		})

		assert.are.equal(88, seen)
		assert.is_true(completed)
		assert.is_true(h:done())
		assert.are.equal(0, dir:activeCount())
		-- and nothing was ever scheduled
		assert.are.equal(0, #iup._timers)
	end)

	it("reports itself disabled", function()
		local dir = make({ enabled = false })
		assert.is_false(dir:enabled())
	end)

	it("completes in-flight animations at their end value when switched off", function()
		local dir, clock = make()
		local seen
		dir:animate({ duration = 500, from = 0, to = 100, on_frame = function(v) seen = v end })
		clock.t = 0.05
		dir:tick()
		assert.is_true(seen < 100)

		dir:configure({ enabled = false })
		assert.are.equal(100, seen)
		assert.are.equal(0, dir:activeCount())
	end)

	it("can be switched back on", function()
		local dir = make({ enabled = false })
		dir:configure({ enabled = true })
		assert.is_true(dir:enabled())
		dir:animate({ duration = 500 })
		assert.are.equal(1, dir:activeCount())
	end)
end)

describe("MotionDirector speed scale", function()
	it("multiplies duration", function()
		local dir, clock = make({ scale = 2.0 })
		dir:animate({ duration = 100 })

		clock.t = 0.15
		dir:tick()
		assert.are.equal(1, dir:activeCount(), "2x scale should still be running at 150ms")

		clock.t = 0.21
		dir:tick()
		assert.are.equal(0, dir:activeCount())
	end)

	it("scales delays too, so choreography keeps its shape", function()
		local dir, clock = make({ scale = 2.0 })
		local fired = false
		dir:animate({ duration = 100, delay = 50, on_frame = function() fired = true end })

		clock.t = 0.08
		dir:tick()
		assert.is_false(fired, "a 50ms delay at 2x should not have elapsed by 80ms")

		clock.t = 0.12
		dir:tick()
		assert.is_true(fired)
	end)

	it("ignores a zero or negative scale", function()
		local dir = make()
		dir:configure({ scale = 0 })
		assert.are.equal(1.0, dir:scale())
		dir:configure({ scale = -3 })
		assert.are.equal(1.0, dir:scale())
	end)

	it("applies a valid scale", function()
		local dir = make()
		dir:configure({ scale = 0.5 })
		assert.are.equal(0.5, dir:scale())
	end)
end)

describe("MotionDirector robustness", function()
	it("drops an animation whose easing function throws", function()
		-- The easing function is a public spec field, so an extension can supply
		-- one. Before this was guarded, a throwing curve escaped tick() and left
		-- the re-entrancy flag raised, which killed every animation in the process
		-- and pinned the shared 60Hz timer forever.
		local dir, clock = make()
		dir:animate({ duration = 500, easing = function() error("bad curve") end })
		dir:animate({ duration = 500, tag = "innocent" })

		clock.t = 0.016
		assert.has_no.errors(function() dir:tick() end)
		assert.are.equal(1, dir:activeCount(), "the unrelated animation should survive")

		-- and the driver must still be usable afterwards
		clock.t = 0.032
		dir:tick()
		assert.are.equal(1, dir:activeCount())
		clock.t = 1.0
		dir:tick()
		assert.are.equal(0, dir:activeCount())
	end)

	it("drops an animation whose easing function returns a non-number", function()
		-- A curve missing its `return` yields nil, which used to throw during the
		-- interpolation arithmetic -- outside the pcall, with the same consequence.
		local dir, clock = make()
		dir:animate({ duration = 500, easing = function() end })
		clock.t = 0.016
		assert.has_no.errors(function() dir:tick() end)
		assert.are.equal(0, dir:activeCount())
	end)

	it("never leaves the re-entrancy flag raised, so later ticks still run", function()
		local dir, clock = make()
		dir:animate({ duration = 500, easing = function() error("boom") end })
		clock.t = 0.016
		dir:tick()

		-- If _ticking stayed true, this animation would never advance again.
		local advanced = false
		dir:animate({ duration = 100, on_frame = function() advanced = true end })
		clock.t = 0.05
		dir:tick()
		assert.is_true(advanced, "the driver wedged after an escaping error")
	end)

	it("stops the shared timer after an escaping error", function()
		local dir, clock, iup = make()
		dir:animate({ duration = 500, easing = function() error("boom") end })
		clock.t = 0.016
		dir:tick()
		assert.are.equal(0, dir:activeCount())
		assert.is_false(iup._timers[1].running,
			"the timer kept spinning with nothing to drive")
	end)

	it("drops an animation whose frame callback throws", function()
		-- A throwing callback would otherwise throw on every frame forever, and at
		-- 60 Hz that turns one bug into a flood.
		local dir, clock = make()
		local calls = 0
		dir:animate({ duration = 500, on_frame = function() calls = calls + 1 error("boom") end })

		clock.t = 0.016
		dir:tick()
		clock.t = 0.032
		dir:tick()

		assert.are.equal(1, calls)
		assert.are.equal(0, dir:activeCount())
	end)

	it("allows scheduling from inside a frame callback", function()
		local dir, clock = make()
		local spawned = false
		dir:animate({
			duration = 200,
			on_frame = function()
				if not spawned then
					spawned = true
					dir:animate({ duration = 200, tag = "inner" })
				end
			end,
		})
		clock.t = 0.02
		dir:tick()
		assert.are.equal(2, dir:activeCount())
	end)

	it("allows cancelling from inside a frame callback", function()
		local dir, clock = make()
		dir:animate({ duration = 200, tag = "victim" })
		dir:animate({
			duration = 200,
			on_frame = function() dir:cancel({ tag = "victim" }) end,
		})
		clock.t = 0.02
		dir:tick()
		assert.are.equal(1, dir:activeCount())
	end)

	it("ignores a re-entrant tick", function()
		local dir, clock = make()
		local depth, max_depth = 0, 0
		dir:animate({
			duration = 200,
			on_frame = function()
				depth = depth + 1
				if depth > max_depth then max_depth = depth end
				dir:tick()
				depth = depth - 1
			end,
		})
		clock.t = 0.02
		dir:tick()
		assert.are.equal(1, max_depth)
	end)

	it("survives a nil spec", function()
		local dir = make()
		assert.has_no.errors(function() dir:animate() end)
	end)

	it("releases everything on shutdown", function()
		local dir, _, iup = make()
		dir:animate({ duration = 500 })
		dir:animate({ duration = 500 })
		dir:shutdown()
		assert.are.equal(0, dir:activeCount())
		assert.is_false(iup._timers[1].running)
	end)

	it("works without an IUP binding at all", function()
		-- Nothing schedules, but callers still get their end state, so a headless
		-- or partially-initialised host degrades instead of erroring.
		local dir = MotionDirector:new({ clock = function() return 0 end })
		local seen
		dir:animate({ duration = 100, from = 0, to = 5, on_frame = function(v) seen = v end })
		dir:finishAll()
		assert.are.equal(5, seen)
	end)
end)
