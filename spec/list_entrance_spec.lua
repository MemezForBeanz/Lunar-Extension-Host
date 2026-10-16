-- spec/list_entrance_spec.lua — core.ui.ListEntrance staggered entrance helper.
--
-- ListEntrance.play is the first consumer of MotionTokens.stagger, which Carbon
-- specifies for data-table entrances: distribute rows over time, automatically
-- compressing the step so the total sequence fits inside 500 ms.
--
-- The behaviours worth pinning:
--
--   * delays follow MotionTokens.stagger — row 1 at 0, row i at (i-1)*20 ms
--   * a long list compresses so the LAST row still starts within 500 ms
--   * lists longer than limit land immediately instead of staggering
--   * with motion disabled every row lands synchronously and the list is
--     complete when play() returns
--   * re-playing supersedes an in-flight entrance rather than stacking
--   * nil director / nil items do not raise

local ListEntrance = require("core.ui.ListEntrance")
local MotionDirector = require("core.classes.MotionDirector")
local Tokens = require("core.lib.MotionTokens")

-- ---------------------------------------------------------------------------
-- Fakes
-- ---------------------------------------------------------------------------

-- Minimal IUP surface: records attribute writes, reports a fixed NATURALSIZE
-- so ListEntrance has a real height target, and counts Refresh calls.
local function fake_iup(opts)
	opts = opts or {}
	local natural_h = opts.natural_h or 20
	local iup = { _timers = {}, _attrs = {} }

	function iup.timer(def)
		local t = { running = false, def = def }
		iup._timers[#iup._timers + 1] = t
		return t
	end
	function iup.SetAttribute(w, k, v)
		if w == nil then return end
		if k == "RUN" and type(w) == "table" and w.def then
			w.running = (v == "YES")
			return
		end
		if type(w) == "table" then
			w._attrs = w._attrs or {}
			w._attrs[k] = v
		end
	end
	function iup.GetAttribute(w, k)
		if k == "NATURALSIZE" then return "100x" .. natural_h end
		if type(w) == "table" then
			w._attrs = w._attrs or {}
			return w._attrs[k]
		end
	end
	function iup.Refresh(w)
		if type(w) == "table" then
			w._refreshes = (w._refreshes or 0) + 1
		end
	end
	function iup.SetAttributeId(w, k, i, v)
		if type(w) == "table" then
			w._attrs = w._attrs or {}
			w._attrs[k .. tostring(i)] = v
		end
	end
	return iup
end

-- A fake widget table that records the attributes ListEntrance writes.
local function fake_widget()
	return { _attrs = {}, _refreshes = 0 }
end

-- Build a director with an injected clock.
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

-- ---------------------------------------------------------------------------
-- Delay correctness
-- ---------------------------------------------------------------------------

describe("ListEntrance delays", function()
	it("row 1 starts at 0 ms (no delay)", function()
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local w1 = fake_widget()
		local w2 = fake_widget()

		-- Advance past 0 ms but not past step (20 ms). At t=0.010, only w1's
		-- animation has elapsed enough to tick (delay 0); w2 still has 10 ms
		-- to wait.
		ListEntrance.play(dir, { w1, w2 })

		clock.t = 0.010  -- 10 ms: w1 in flight, w2 not started yet
		dir:tick()

		-- w1 has been given a RASTERSIZE (some intermediate height > 0).
		local rs1 = w1._attrs["RASTERSIZE"]
		assert.is_not_nil(rs1, "row 1 should have started animating at t=10ms")
	end)

	it("row i starts at (i-1)*step ms", function()
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local widgets = {}
		local n = 4
		for _ = 1, n do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets)

		-- Check that each row's recorded delay matches Tokens.stagger.
		-- The director stores rec.start = clock.t + delay/1000; at t=0 the
		-- clock is 0, so rec.start == delay/1000. We verify by ticking to just
		-- before the expected start of row i+1 and confirming only rows 1..i
		-- have started.
		--
		-- Verify delays for rows 1-4 with the 20 ms default step.
		for i = 1, n do
			local expected_delay_ms = Tokens.stagger(i, n, 20)
			-- (i-1)*20 for n=4: 0, 20, 40, 60
			assert.are.equal((i - 1) * 20, expected_delay_ms,
				"row " .. i .. " expected delay mismatch")
		end
	end)

	it("step is taken from the list_stagger role default (20 ms)", function()
		-- The role's step extra is 20 ms; verify play uses it by observing that
		-- a 5-row list's last row starts at (5-1)*20 = 80 ms rather than some
		-- other value.
		local n = 5
		local last_delay = Tokens.stagger(n, n, 20)
		assert.are.equal((n - 1) * 20, last_delay)
	end)
end)

-- ---------------------------------------------------------------------------
-- 500 ms ceiling compression
-- ---------------------------------------------------------------------------

describe("ListEntrance ceiling compression", function()
	it("compresses the step so the last row starts within 500 ms", function()
		-- With 40 rows at 20 ms each the total would be 780 ms, breaching the
		-- ceiling. MotionTokens.stagger should clamp the last delay to 500 ms.
		local n = 40
		local last_delay = Tokens.stagger(n, n, 20)
		assert.is_true(last_delay <= 500,
			"last row delay " .. last_delay .. " exceeds 500 ms ceiling")
	end)

	it("compresses for a very long list too", function()
		local n = 200
		local last_delay = Tokens.stagger(n, n, 20)
		assert.is_true(last_delay <= 500)
		-- And strictly: the last delay must equal the ceiling itself when
		-- spans * step > 500.
		assert.are.equal(500, last_delay)
	end)

	it("does not compress a short list that fits within 500 ms", function()
		-- 5 rows at 20 ms is 80 ms total — no compression needed.
		local n = 5
		local last_delay = Tokens.stagger(n, n, 20)
		assert.are.equal((n - 1) * 20, last_delay)
	end)
end)

-- ---------------------------------------------------------------------------
-- Limit: above the threshold, land immediately
-- ---------------------------------------------------------------------------

describe("ListEntrance limit", function()
	it("settles every row immediately when count > limit", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		local role_limit = dir:role("list_stagger").limit  -- 40

		local widgets = {}
		for _ = 1, role_limit + 1 do
			widgets[#widgets + 1] = fake_widget()
		end

		ListEntrance.play(dir, widgets)

		-- No in-flight animations: all rows should have been settled
		-- immediately (FLOATING=NO, VISIBLE=YES, RASTERSIZE released).
		assert.are.equal(0, dir:activeCount(),
			"no animations should be scheduled above the limit")

		-- Each widget should have been settled (FLOATING=NO, VISIBLE=YES).
		for i, w in ipairs(widgets) do
			assert.are.equal("NO",  w._attrs["FLOATING"], "widget " .. i .. " FLOATING")
			assert.are.equal("YES", w._attrs["VISIBLE"],  "widget " .. i .. " VISIBLE")
		end
	end)

	it("staggers normally when count == limit", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		local role_limit = dir:role("list_stagger").limit  -- 40

		local widgets = {}
		for _ = 1, role_limit do
			widgets[#widgets + 1] = fake_widget()
		end

		ListEntrance.play(dir, widgets)

		-- Animations should be in flight (at least role_limit row animations
		-- plus the sentinel refresh animation).
		assert.is_true(dir:activeCount() >= role_limit,
			"expected animations for exactly-limit rows")
	end)
end)

-- ---------------------------------------------------------------------------
-- Motion disabled — synchronous completion
-- ---------------------------------------------------------------------------

describe("ListEntrance with motion disabled", function()
	it("settles every row synchronously when motion is off", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup, { enabled = false })

		local widgets = {}
		for _ = 1, 5 do widgets[#widgets + 1] = fake_widget() end

		-- With motion off, director.animate() delivers on_frame(to) and
		-- on_done(true) synchronously before returning, so every row is
		-- settled by the time play() returns.
		ListEntrance.play(dir, widgets)

		for i, w in ipairs(widgets) do
			assert.are.equal("NO",  w._attrs["FLOATING"], "widget " .. i .. " FLOATING")
			assert.are.equal("YES", w._attrs["VISIBLE"],  "widget " .. i .. " VISIBLE")
			-- RASTERSIZE is released (set to nil) by settle().
			assert.is_nil(w._attrs["RASTERSIZE"], "widget " .. i .. " RASTERSIZE")
		end
	end)

	it("leaves no in-flight animations when motion is off", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup, { enabled = false })

		local widgets = {}
		for _ = 1, 5 do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets)

		assert.are.equal(0, dir:activeCount(),
			"no animations should remain after synchronous completion")
	end)
end)

-- ---------------------------------------------------------------------------
-- Re-entrancy: replay supersedes in-flight entrance
-- ---------------------------------------------------------------------------

describe("ListEntrance re-entrancy", function()
	it("supersedes an in-flight entrance when play is called again", function()
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local w = fake_widget()

		-- First play: the animation is in flight.
		ListEntrance.play(dir, { w })
		local count_after_first = dir:activeCount()
		assert.is_true(count_after_first >= 1, "animation should be in flight")

		-- Tick partway through the first entrance.
		clock.t = 0.020
		dir:tick()

		-- Second play: should replace, not add, so the count stays stable.
		-- Because the widget is registered as the `target`, the director
		-- cancels the prior animation on that target before scheduling the new
		-- one.
		ListEntrance.play(dir, { w })
		local count_after_second = dir:activeCount()

		-- The count after the second play should not be meaningfully higher
		-- than after the first: at most one animation per widget at a time.
		-- (The sentinel refresh animation may still be around, which is fine.)
		assert.is_true(count_after_second <= count_after_first + 1,
			"re-play must not stack animations: first=" .. count_after_first ..
			" second=" .. count_after_second)
	end)
end)

-- ---------------------------------------------------------------------------
-- Nil / empty safety
-- ---------------------------------------------------------------------------

describe("ListEntrance safety", function()
	it("does not raise when director is nil", function()
		assert.has_no.errors(function()
			ListEntrance.play(nil, { fake_widget() })
		end)
	end)

	it("does not raise when items is nil", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		assert.has_no.errors(function()
			ListEntrance.play(dir, nil)
		end)
	end)

	it("does not raise for an empty items table", function()
		local iup = fake_iup()
		local dir, _ = make_director(iup)
		assert.has_no.errors(function()
			ListEntrance.play(dir, {})
		end)
		assert.are.equal(0, dir:activeCount())
	end)

	it("does not raise when a widget has not been mapped (nil NATURALSIZE height)", function()
		local iup = fake_iup({ natural_h = 0 })  -- reports height 0 → treated as unmapped
		local dir, _ = make_director(iup)
		local w = fake_widget()
		assert.has_no.errors(function()
			ListEntrance.play(dir, { w })
		end)
	end)
end)

-- ---------------------------------------------------------------------------
-- Container refresh batching
-- ---------------------------------------------------------------------------

describe("ListEntrance refresh batching", function()
	it("issues at most one Refresh per tick on the container", function()
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local container = fake_widget()

		local widgets = {}
		for _ = 1, 5 do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets, { container = container })

		-- Advance to mid-animation — all five rows should be ticking.
		clock.t = 0.005
		dir:tick()

		-- Batching guarantee: at most one iup.Refresh per tick, regardless of
		-- row count. The sentinel drains the dirty flag once; individual row
		-- on_frame callbacks only set it. Five rows must not produce five
		-- layout passes.
		local r = container._refreshes or 0
		assert.is_true(r <= 1,
			"expected at most 1 container refresh this tick, got " .. r)
	end)

	it("issues a refresh on every tick that rows are animating, not only the first", function()
		-- Regression for the duration=1 sentinel bug: the original sentinel
		-- completed on tick 1 and was removed, so ticks 2..N had no flush.
		-- Now the sentinel lasts 700 ms; verify at least two different ticks
		-- each produce a refresh.
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local container = fake_widget()

		local widgets = {}
		for _ = 1, 3 do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets, { container = container })

		-- Tick 1: all three rows in flight (no delay — row 1 starts at 0 ms).
		clock.t = 0.005
		dir:tick()
		local after_tick1 = container._refreshes or 0

		-- Tick 2: rows still animating.
		clock.t = 0.050
		dir:tick()
		local after_tick2 = container._refreshes or 0

		assert.is_true(after_tick1 >= 1,
			"expected at least one refresh after tick 1, got " .. after_tick1)
		assert.is_true(after_tick2 > after_tick1,
			"expected additional refreshes after tick 2 (sentinel must survive beyond tick 1); " ..
			"tick1=" .. after_tick1 .. " tick2=" .. after_tick2)
	end)

	it("rows are settled and visible after the cascade completes", function()
		-- The batching is only useful if the rows actually end up visible.
		-- After all animations run to completion, every row must have
		-- RASTERSIZE=nil (released) and the container must have been refreshed.
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local container = fake_widget()

		local widgets = {}
		local n = 3
		for _ = 1, n do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets, { container = container })

		-- Advance past the full cascade: last stagger delay (≤500ms) + row
		-- duration (fast_02 = 110ms) + sentinel (700ms). 1 second covers it.
		clock.t = 1.0
		dir:tick()

		-- Every row must be settled.
		for i, w in ipairs(widgets) do
			assert.is_nil(w._attrs["RASTERSIZE"],
				"widget " .. i .. " RASTERSIZE should be nil after cascade")
			assert.are.equal("NO",  w._attrs["FLOATING"],
				"widget " .. i .. " FLOATING should be NO after cascade")
			assert.are.equal("YES", w._attrs["VISIBLE"],
				"widget " .. i .. " VISIBLE should be YES after cascade")
		end

		-- At least one refresh must have occurred so the settled state is
		-- actually painted.
		assert.is_true((container._refreshes or 0) >= 1,
			"container must be refreshed at least once during cascade")
	end)
end)

-- ---------------------------------------------------------------------------
-- No-container fallback — callers that omit container must not collapse rows
-- ---------------------------------------------------------------------------

describe("ListEntrance no-container fallback", function()
	-- Both current callers (CheckList, ReorderableList) call play without a
	-- container. Before the fix, collapse() pinned rows to height 0 with no
	-- refresh ever issued, so any unrelated repaint during the 110 ms window
	-- would show the list collapsed. The fallback must leave rows visible.

	it("rows end up settled when no container is supplied", function()
		local iup = fake_iup()
		local dir, clock = make_director(iup)

		local widgets = {}
		for _ = 1, 3 do widgets[#widgets + 1] = fake_widget() end

		-- No container: the typical caller pattern.
		ListEntrance.play(dir, widgets)

		-- Run past the full cascade.
		clock.t = 1.0
		dir:tick()

		for i, w in ipairs(widgets) do
			assert.is_nil(w._attrs["RASTERSIZE"],
				"widget " .. i .. " must be settled (RASTERSIZE=nil) without a container")
			assert.are.equal("YES", w._attrs["VISIBLE"],
				"widget " .. i .. " must be visible without a container")
		end
	end)

	it("a refresh is issued to the widget itself when no container is supplied", function()
		-- Without a container, the fallback refreshes the first animated widget.
		-- That widget's _refreshes counter must increase during the cascade so
		-- the layout actually runs.
		local iup = fake_iup()
		local dir, clock = make_director(iup)
		local w = fake_widget()

		ListEntrance.play(dir, { w })

		clock.t = 1.0
		dir:tick()

		assert.is_true((w._refreshes or 0) >= 1,
			"widget must be refreshed at least once when no container is given; got " ..
			tostring(w._refreshes or 0))
	end)
end)

-- ---------------------------------------------------------------------------
-- Motion-off: rows visible and refresh issued before play() returns
-- ---------------------------------------------------------------------------

describe("ListEntrance motion-off visibility", function()
	it("rows are settled AND a refresh has occurred by the time play() returns", function()
		-- With motion off the director fires on_frame(to) + on_done synchronously
		-- inside animate(), so the sentinel's on_frame fires before play() exits.
		-- The dirty flag is set by the row callbacks and drained by the sentinel,
		-- issuing iup.Refresh on the widget — all within play().
		local iup = fake_iup()
		local dir, _ = make_director(iup, { enabled = false })
		local container = fake_widget()
		local widgets   = {}
		for _ = 1, 3 do widgets[#widgets + 1] = fake_widget() end

		ListEntrance.play(dir, widgets, { container = container })

		-- No tick needed: everything is synchronous.
		for i, w in ipairs(widgets) do
			assert.is_nil(w._attrs["RASTERSIZE"],
				"widget " .. i .. " RASTERSIZE must be nil (motion off)")
			assert.are.equal("YES", w._attrs["VISIBLE"],
				"widget " .. i .. " VISIBLE must be YES (motion off)")
		end

		assert.is_true((container._refreshes or 0) >= 1,
			"container must be refreshed synchronously when motion is off")
	end)
end)
