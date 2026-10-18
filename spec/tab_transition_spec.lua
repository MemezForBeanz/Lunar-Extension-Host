-- spec/tab_transition_spec.lua — core.ui.TabTransition over the real compositor.
--
-- This is the app's most-repeated animation and its travel distance has been wrong
-- in both directions: first a literal full-width push, which on a maximised 4K page
-- works out around 16,000 px/s and reads as a smear, then a 14% fraction so short
-- the movement was barely visible and the whole thing read as a dissolve.
--
-- What actually governs how it feels is absolute pixels per second, so the
-- geometry assertions are about distance:
--
--   * the pixel cap holds apparent speed constant across window sizes
--   * a small window scales below the cap rather than overshooting its own page
--   * `travel = 1, fade = false` still reproduces the literal Carbon rigid pair,
--     both pages exactly one page width apart at every instant
--   * the composition never leaves a hole: the outgoing page and the incoming page
--     between them always span the page rectangle
--
-- The transition draws through `core.lib.Compositor`. These tests run the real
-- manager over a fake backend that records what reached the "screen" and which
-- snapshots were taken and released, so frames can be sampled as sprites and the
-- lifecycle (one present per tick, group removed, snapshots released, failing
-- closed) is observable here. Only the native window is left to
-- `scripts/motion_check.lua` and a live run.

local TabTransition = require("core.ui.TabTransition")
local Compositor = require("core.lib.Compositor")
local MotionDirector = require("core.classes.MotionDirector")
local Tokens = require("core.lib.MotionTokens")

-- A backend that records presents and hands out counted snapshots.
local function fake_backend(page_w, page_h)
	local b = { presents = {}, hides = 0, snaps = {}, page = { 10, 40, page_w or 1000, page_h or 600 },
		fail_snapshot_at = nil }
	function b:geometry() return { w = 4000, h = 2000, scale = 1 } end
	function b:present(scene, regions, opacity)
		self.presents[#self.presents + 1] = { scene = scene, regions = regions, opacity = opacity }
		self.shown = true
	end
	function b:hide() self.hides = self.hides + 1; self.shown = false end
	function b:rect() return (table.unpack or unpack)(self.page) end
	function b:snapshot()
		local n = #self.snaps + 1
		if self.fail_snapshot_at == n then return nil, "blank capture" end
		local snap = { w = self.page[3], h = self.page[4], released = 0 }
		function snap:release() self.released = self.released + 1 end
		self.snaps[n] = snap
		return snap
	end
	function b:live_snaps()
		local n = 0
		for _, s in ipairs(self.snaps) do if s.released == 0 then n = n + 1 end end
		return n
	end
	return b
end

local function fake_director(roles)
	local d = { roles = roles or {}, cancelled = 0 }
	function d:enabled() return true end
	function d:role(name) return Tokens.role(name, self.roles) end
	function d:animate(spec) self.spec = spec; return { done = function() return false end } end
	function d:finish() end
	function d:cancel() self.cancelled = self.cancelled + 1 end
	return d
end

-- A stateful IUP fake tracking which tab is selected, so arm() captures the
-- outgoing position and the start timer sees the incoming one.
local function fake_iup()
	local iup = { DEFAULT = 0, timers = {} }
	local current_pos = "0"
	function iup.timer(def)
		local t = { def = def }
		iup.timers[#iup.timers + 1] = t
		return t
	end
	function iup.SetAttribute() end
	function iup.GetAttribute(_, name)
		if name == "VALUEPOS" then return current_pos end
	end
	function iup.GetChild(_, pos) return { pos = pos } end
	-- Advance the simulated strip, as iFlatTabsSetCurrentTab does AFTER
	-- TABCHANGE_CB has been delivered.
	function iup._switchTo(pos) current_pos = tostring(pos) end
	return iup
end

-- Build a transition over a fake compositor. `opts.available = false` means none.
local function make(opts)
	opts = opts or {}
	local backend = fake_backend(opts.w, opts.h)
	local comp = Compositor.new(backend)
	local iup = fake_iup()
	local director = opts.director or fake_director(opts.roles)
	local lines = {}
	local t = TabTransition:new({
		iup = iup, director = director,
		compositor = function()
			if opts.available == false then return nil, "none here" end
			return comp
		end,
		log = function(m) lines[#lines + 1] = m end,
	})
	return t, backend, comp, iup, director, lines
end

-- Run a forward switch 0 -> 1 on a page `w` wide.
local function play(w, roles)
	local t, backend, comp, iup, director = make({ w = w, roles = roles })
	local ran = t:run({}, 1, function() iup._switchTo(1) end)
	assert.is_true(ran)
	return t, backend, comp, t._active, director
end

-- Compose the frame at eased progress `t` and return the sprites that reached the
-- backend: backdrop, outgoing image, incoming image.
local function frameAt(tt, backend, comp, state, p)
	state.progress = p
	tt:_frame(state)
	assert.is_true(comp:commit())
	local scene = backend.presents[#backend.presents].scene
	return scene[1], scene[2], scene[3], state
end

-- Distance the incoming page travels: its offset at t=0 (it settles at 0).
local function incoming_travel(tt, backend, comp, state)
	frameAt(tt, backend, comp, state, 0)
	return math.abs(state.to_x)
end

describe("TabTransition travel", function()
	it("caps travel in pixels so apparent speed is the same on any display", function()
		-- A laptop and a 4K display get the SAME slide, so the transition feels
		-- identical rather than four times as fast on the bigger screen.
		local a, ab, ac, as = play(1366)
		assert.are.equal(360, incoming_travel(a, ab, ac, as))
		local b, bb, bc, bs = play(3840)
		assert.are.equal(360, incoming_travel(b, bb, bc, bs))
	end)

	it("scales below the cap on a window too small to reach it", function()
		local w = 800
		local t, b, c, s = play(w)
		assert.are.equal(math.floor(w * 0.32), math.floor(incoming_travel(t, b, c, s)))
	end)

	it("never travels further than the page itself", function()
		local t, b, c, s = play(60)
		assert.is_true(incoming_travel(t, b, c, s) <= 60)
	end)

	it("lets a theme widen the slide", function()
		local t, b, c, s = play(3840, { tab_transition = { travel = 0.5, max_travel = 800 } })
		assert.are.equal(800, incoming_travel(t, b, c, s))
	end)
end)

describe("TabTransition composition", function()
	it("cross-fades the incoming page in", function()
		local t, b, c, s = play(1600)
		local _, _, early = frameAt(t, b, c, s, 0.1)
		local _, _, late = frameAt(t, b, c, s, 0.9)
		assert.is_true(early.alpha < late.alpha)
		-- Opaque before it settles: still translucent at rest looks like the
		-- transition failed to finish.
		assert.are.equal(1, late.alpha)
	end)

	it("settles the incoming page at zero offset, on the page rectangle", function()
		local t, b, c, s = play(1600)
		local _, _, incoming = frameAt(t, b, c, s, 1)
		assert.are.equal(0, s.to_x)
		assert.are.equal(10, incoming.x)
		assert.are.equal(40, incoming.y)
	end)

	it("moves the outgoing page less than the incoming one", function()
		-- Two layers at different rates is the depth cue that makes the arriving
		-- page read as leading rather than as a rigid pair.
		local t, b, c, s = play(1600)
		frameAt(t, b, c, s, 0.5)
		assert.is_true(math.abs(s.from_x) < math.abs(s.to_x))
	end)

	it("leaves no uncovered strip at any point in the slide", function()
		-- The outgoing page is the opaque base; wherever it has vacated must be
		-- covered by the incoming page.
		local w = 1600
		local t, b, c, s = play(w)
		for i = 0, 20 do
			local p = i / 20
			frameAt(t, b, c, s, p)
			assert.is_true(math.min(s.from_x, s.to_x) <= 0, string.format("gap on the left at t=%.2f", p))
			assert.is_true(math.max(s.from_x + w, s.to_x + w) >= w, string.format("gap on the right at t=%.2f", p))
		end
	end)

	it("reproduces the literal Carbon rigid pair at travel = 1 with no fade", function()
		local w = 1200
		local t, b, c, s = play(w, { tab_transition = { travel = 1, fade = false } })
		for i = 0, 10 do
			local _, _, incoming = frameAt(t, b, c, s, i / 10)
			-- Exactly one page width apart at every instant, and drawn opaque.
			assert.are.equal(w, math.abs(s.from_x - s.to_x))
			assert.are.equal(1, incoming.alpha)
		end
	end)

	it("draws the outgoing page ahead of the incoming one, over a backdrop", function()
		local t, b, c, s = play(1000)
		local backdrop, outgoing, incoming = frameAt(t, b, c, s, 0.3)
		assert.are.equal("fill", backdrop.kind)
		assert.are.equal("image", outgoing.kind)
		assert.are.equal("image", incoming.kind)
		assert.are.equal(s.from_snap, outgoing.snap)
		assert.are.equal(s.to_snap, incoming.snap)
	end)

	it("clips every sprite to the page rectangle, so a slide never leaves it", function()
		local t, b, c, s = play(1000)
		for i = 0, 10 do
			local backdrop, outgoing, incoming = frameAt(t, b, c, s, i / 10)
			for _, sprite in ipairs({ backdrop, outgoing, incoming }) do
				assert.are.same({ x = 10, y = 40, w = 1000, h = 600 }, sprite.clip)
			end
		end
	end)

	it("offsets the pages from the page origin by their logical position", function()
		local t, b, c, s = play(1000)
		local _, outgoing, incoming = frameAt(t, b, c, s, 0.5)
		assert.are.equal(10 + math.floor(s.from_x + 0.5), outgoing.x)
		assert.are.equal(10 + math.floor(s.to_x + 0.5), incoming.x)
		assert.is_true(outgoing.x < 10, "forward switch pushes the outgoing page left")
	end)

	it("slides the other way for a backward switch", function()
		local t, b, c, iup = make({ w = 1000 })
		iup._switchTo(2)
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		local s = t._active
		frameAt(t, b, c, s, 0.5)
		assert.is_true(s.from_x > 0, "outgoing page drifts right")
		assert.is_true(s.to_x < 0, "incoming page arrives from the left")
	end)
end)

describe("TabTransition scheduling", function()
	it("animates under the tab_transition role rather than a literal duration", function()
		local _, _, _, _, director = play(1600)
		assert.are.equal("tab_transition", director.spec.role)
		-- No explicit duration: a theme retunes this without touching the module.
		assert.is_nil(director.spec.duration)
		-- And no distance either, or the role's fixed duration would be replaced
		-- by one derived from the page width -- the original bug.
		assert.is_nil(director.spec.distance)
	end)

	it("puts the first frame up at once, so the switched page never shows through", function()
		local _, backend = play(1000)
		assert.are.equal(1, #backend.presents)
	end)
end)

-- A real director on an injectable clock, so frame ends and completion are real.
local function real_director()
	local clock = { t = 0 }
	local dir = MotionDirector:new({
		iup = { DEFAULT = 0, timer = function() return {} end, SetAttribute = function() end },
		clock = function() return clock.t end,
	})
	return dir, clock
end

describe("TabTransition on the compositor", function()
	it("presents one frame per director tick, however many effects ask", function()
		local dir, clock = real_director()
		local t, backend, comp, iup = make({ w = 1000, director = dir })
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		-- A second effect on the same dialog animating in the same ticks.
		dir:animate({ duration = 240, target = "other", from = 0, to = 1, on_frame = function(v)
			comp:set("other", { z = Compositor.Z_SCRIM, regions = {},
				sprites = { { kind = "fill", x = 0, y = 0, w = 10, h = 10, color = 0, alpha = v } } })
			comp:schedule(dir)
		end })
		local before = #backend.presents
		for step = 1, 5 do
			clock.t = step * 0.016
			dir:tick(clock.t)
			assert.are.equal(before + step, #backend.presents, "exactly one present per tick")
		end
	end)

	it("removes its group and releases both snapshots when the animation ends", function()
		local dir, clock = real_director()
		local t, backend, comp, iup = make({ w = 1000, director = dir })
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		assert.is_true(t:busy())
		assert.are.equal(2, backend:live_snaps())
		assert.is_not_nil(next(comp.groups))

		clock.t = 10
		dir:tick(clock.t)

		assert.is_false(t:busy())
		assert.is_nil(next(comp.groups), "the group must be gone")
		assert.is_false(backend.shown, "the overlay must be hidden")
		assert.are.equal(0, backend:live_snaps())
		for _, snap in ipairs(backend.snaps) do assert.are.equal(1, snap.released) end
	end)

	it("settle() collapses a running transition and releases everything", function()
		local dir = real_director()
		local t, backend, comp, iup = make({ w = 1000, director = dir })
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		t:settle()
		assert.is_false(t:busy())
		assert.are.equal(0, dir:activeCount())
		assert.is_nil(next(comp.groups))
		assert.are.equal(0, backend:live_snaps())
	end)

	it("a new switch mid-flight lands the old one and starts fresh", function()
		local dir = real_director()
		local t, backend, comp, iup = make({ w = 1000, director = dir })
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		assert.is_true(t:run({}, 2, function() iup._switchTo(2) end))
		assert.are.equal(1, dir:activeCount())
		assert.are.equal(2, backend:live_snaps(), "only the running transition's pair is held")
		t:settle()
		assert.are.equal(0, backend:live_snaps())
	end)

	it("suspend() settles a running transition", function()
		local dir = real_director()
		local t, backend, comp, iup = make({ w = 1000, director = dir })
		assert.is_true(t:run({}, 1, function() iup._switchTo(1) end))
		t:suspend()
		assert.is_false(t:busy())
		assert.is_nil(next(comp.groups))
		assert.are.equal(0, backend:live_snaps())
		t:resume()
	end)
end)

describe("TabTransition without a compositor", function()
	it("run() still performs the switch, once, and animates nothing", function()
		local t, backend, _, iup, _, lines = make({ available = false })
		local switched = 0
		local ran = t:run({}, 1, function() switched = switched + 1; iup._switchTo(1) end)
		assert.is_false(ran)
		assert.are.equal(1, switched)
		assert.are.equal(0, #backend.presents)
		assert.is_false(t:busy())
		assert.is_truthy(lines[1] and lines[1]:find("no compositor", 1, true))
		assert.is_truthy(t._last_decline:find("none here", 1, true))
	end)

	it("arm() captures nothing and commit() declines cleanly", function()
		local t, backend, _, iup = make({ available = false })
		t:arm({})
		iup._switchTo(1)
		assert.is_false(t:commit({}))
		assert.are.equal(0, #backend.snaps)
	end)

	it("logs a distinct decline reason once", function()
		local t, _, _, iup, _, lines = make({ available = false })
		for _ = 1, 3 do t:run({}, 1, function() iup._switchTo(1) end) end
		assert.are.equal(1, #lines)
	end)

	it("settle() and disarm() are harmless", function()
		local t = make({ available = false })
		t:settle()
		t:disarm()
		assert.is_false(t:busy())
	end)
end)

describe("TabTransition capture failures", function()
	it("still switches when the outgoing capture is blank", function()
		local t, backend, _, iup, _, lines = make({ w = 1000 })
		backend.fail_snapshot_at = 1
		local switched = false
		local ran = t:run({}, 1, function() switched = true; iup._switchTo(1) end)
		assert.is_false(ran)
		assert.is_true(switched)
		assert.is_truthy(t._last_decline:find("blank capture", 1, true))
		assert.are.equal(0, #backend.presents)
	end)

	it("releases the outgoing capture when the incoming one fails", function()
		local t, backend, comp, iup = make({ w = 1000 })
		backend.fail_snapshot_at = 2
		local ran = t:run({}, 1, function() iup._switchTo(1) end)
		assert.is_false(ran)
		assert.are.equal(0, backend:live_snaps())
		assert.is_nil(next(comp.groups))
	end)

	it("fails closed and releases both when the first frame is refused", function()
		local t, backend, comp, iup = make({ w = 1000 })
		function backend:present() return false, "nope" end
		local ran = t:run({}, 1, function() iup._switchTo(1) end)
		assert.is_false(ran)
		assert.is_false(t:busy())
		assert.are.equal(0, backend:live_snaps())
		assert.is_truthy(t._last_decline:find("refused", 1, true))
	end)

	it("skips a page with no rectangle", function()
		local t, backend, _, iup = make({ w = 1000 })
		function backend:rect() return nil end
		local ran = t:run({}, 1, function() iup._switchTo(1) end)
		assert.is_false(ran)
		assert.are.equal(0, backend:live_snaps())
	end)

	it("does nothing when the switch lands on the same tab", function()
		local t, backend = make({ w = 1000 })
		local switched = false
		assert.is_false(t:run({}, 0, function() switched = true end))
		assert.is_true(switched)
		assert.are.equal(0, #backend.snaps)
	end)
end)

describe("TabTransition arm → commit → play pipeline", function()
	-- The end-to-end path for a mouse click: arm() captures the outgoing page,
	-- commit() receives TABCHANGE_CB and schedules the start timer, and the timer
	-- fires _startPending() → _play().
	--
	-- ### The IUP call-order bug this pins
	--
	-- In iup_flattabs.c, `iFlatTabsCallTabChange` (which fires TABCHANGE_CB) is
	-- called *before* `iFlatTabsSetCurrentTab` updates VALUE/VALUEPOS. Reading
	-- VALUEPOS in commit() always saw the outgoing position, so every transition
	-- was silently dropped. The position check is deferred to _startPending, one
	-- millisecond later. The tests reproduce the real call order: commit() fires
	-- BEFORE the simulated iup._switchTo().

	local function stat(t, key) return (t._stats or {})[key] or 0 end

	it("plays after arm + commit + timer (VALUEPOS updated after commit)", function()
		local t, backend, _, iup = make({ w = 1000 })
		local strip = {}
		t:arm(strip)
		assert.are.equal(1, stat(t, "armed"))

		t:commit(strip)
		assert.are.equal(1, stat(t, "committed"))

		iup._switchTo(1)
		local timer = t._start_timer
		assert.is_not_nil(timer, "commit() should have created the start timer")
		timer:action_cb()

		assert.are.equal(1, stat(t, "played"))
		assert.are.equal(1, stat(t, "shown"))
		assert.is_true(t:busy())
		assert.are.equal(2, backend:live_snaps())
	end)

	it("_startPending releases the capture when no navigation happened", function()
		local t, backend = make({ w = 1000 })
		local strip = {}
		t:arm(strip)
		t:commit(strip)
		t._start_timer:action_cb()   -- VALUEPOS never changed
		assert.are.equal(0, stat(t, "played"))
		assert.are.equal(0, backend:live_snaps())
	end)

	it("ignores a commit with no prior arm (programmatic switch)", function()
		local t, _, _, iup = make({ w = 1000 })
		iup._switchTo(1)
		t:commit({})
		assert.are.equal(0, stat(t, "committed"))
		assert.are.equal(0, stat(t, "armed"))
	end)

	it("disarm() releases an armed capture", function()
		local t, backend = make({ w = 1000 })
		t:arm({})
		assert.are.equal(1, backend:live_snaps())
		t:disarm()
		assert.are.equal(0, backend:live_snaps())
	end)

	it("disarm() releases a capture that is waiting for its start timer", function()
		local t, backend = make({ w = 1000 })
		local strip = {}
		t:arm(strip)
		t:commit(strip)
		t:disarm()
		assert.are.equal(0, backend:live_snaps())
	end)

	it("arm() while suspended captures nothing", function()
		local t, backend = make({ w = 1000 })
		t:suspend()
		t:arm({})
		assert.are.equal(0, #backend.snaps)
		t:resume()
	end)

	it("reports the compositor and its counters", function()
		local t = make({ w = 1000 })
		local report = t:report()
		assert.are.equal("yes", report["Compositor available"])
		assert.are.equal("0", report["Count 3 played"])
	end)
end)
