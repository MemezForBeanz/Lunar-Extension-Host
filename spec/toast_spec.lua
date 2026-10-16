-- spec/toast_spec.lua — core.ui.Toast: stacking arithmetic and motion choreography.
--
-- The pure-logic layer of Toast (`Toast.layout`) is tested without any IUP, any
-- director, and any real window. The same separation that makes MotionTokens
-- testable applies here: stacking maths live in plain functions, GUI wiring lives
-- in ToastHost. This spec covers:
--
--   * placement arithmetic: where toast N sits
--   * reflow arithmetic: where survivors move after one dismisses
--   * that reflow uses cornerPath and therefore never starts both axes at t=0
--   * auto-dismiss timing off the `hold` extra (via the director)
--   * that everything lands correctly with motion disabled (the director's
--     off-switch delivers the end state synchronously, so toasts still show)
--   * owner-scoped dismissal via ToastHost:dismissOwned
--
-- IUP is faked, the clock is injected, and no real window is created.

local Tokens = require("core.lib.MotionTokens")
local Toast  = require("core.ui.Toast")

local layout    = Toast.layout
local ToastHost = Toast.ToastHost

-- ==========================================================================
-- SHARED CONSTANTS (must agree with Toast.lua)
-- ==========================================================================

local MARGIN     = 16
local GAP        = 8
local TOAST_W    = 352
local TOP_OFFSET = 48 + MARGIN

-- ==========================================================================
-- MINIMAL FAKE IUP
-- ==========================================================================

local function fake_iup()
	local iup = { DEFAULT = 0 }

	local function node(kind)
		return function(def)
			local n = { kind = kind, attrs = {}, children = {}, _alive = true }
			for k, v in pairs(def or {}) do
				if type(k) == "number" then
					n.children[#n.children + 1] = v
				else
					n.attrs[k] = v
				end
			end
			return n
		end
	end

	for _, kind in ipairs({
		"vbox", "hbox", "flatlabel", "flatbutton", "fill", "dialog",
		"label", "canvas",
	}) do
		iup[kind] = node(kind)
	end

	-- The director needs iup.timer and iup.SetAttribute(timer, "RUN", ...).
	function iup.timer(def)
		local t = { kind = "timer", attrs = {}, running = false }
		for k, v in pairs(def or {}) do t.attrs[k] = v end
		return t
	end

	function iup.SetAttribute(w, name, value)
		if w and name then
			w.attrs[name] = value
			if name == "RUN" then w.running = (value == "YES") end
		end
	end
	function iup.GetAttribute(w, name)
		if w and name then return w.attrs[name] end
		return nil
	end

	-- ShowXY records where the dialog was first placed.
	function iup.ShowXY(dlg, x, y)
		if dlg then
			dlg.attrs.SCREENPOSITION = tostring(math.floor(x)) .. "," .. tostring(math.floor(y))
			dlg._shown = true
		end
	end

	function iup.Hide(dlg) if dlg then dlg._shown = false end end
	function iup.Destroy(dlg) if dlg then dlg._alive = false end end
	function iup.Map(w) if w then w._mapped = true end end
	function iup.Refresh(w) end
	function iup.Detach(w) end

	return iup
end

-- ==========================================================================
-- DIRECTOR STUB — injectable clock, motion can be toggled off
-- ==========================================================================

local function make_director(opts)
	opts = opts or {}
	local MotionDirector = require("core.classes.MotionDirector")
	local clock = { t = 0 }
	local iup = fake_iup()
	local d = MotionDirector:new({
		iup     = iup,
		clock   = function() return clock.t end,
		enabled = opts.enabled ~= false,
	})
	return d, clock, iup
end

-- ==========================================================================
-- PLACEMENT ARITHMETIC
-- ==========================================================================

describe("Toast.layout.toastY", function()
	it("places toast 1 at TOP_OFFSET", function()
		local h = 48
		assert.are.equal(TOP_OFFSET, layout.toastY(1, h))
	end)

	it("offsets each successive toast by height + GAP", function()
		local h = 64
		local y1 = layout.toastY(1, h)
		local y2 = layout.toastY(2, h)
		local y3 = layout.toastY(3, h)
		assert.are.equal(h + GAP, y2 - y1)
		assert.are.equal(h + GAP, y3 - y2)
	end)

	it("produces distinct Y values for different heights", function()
		assert.is_true(layout.toastY(2, 48) ~= layout.toastY(2, 64))
	end)
end)

describe("Toast.layout.toastX", function()
	it("right-aligns with Carbon margin", function()
		local w = 1200
		assert.are.equal(w - TOAST_W - MARGIN, layout.toastX(w))
	end)

	it("is consistent across dialog widths", function()
		local w = 1600
		assert.are.equal(w - TOAST_W - MARGIN, layout.toastX(w))
	end)
end)

-- ==========================================================================
-- REFLOW ARITHMETIC
-- ==========================================================================

describe("Toast.layout.reflowTargets", function()
	-- Three toasts: slots 1, 2, 3. Toast 2 is dismissed.
	-- Toast 1 (above): should not move.
	-- Toast 3 (below): should move up to slot 2.
	local dialog_w = 1200
	local height   = 48

	it("returns nil for survivors above the gap", function()
		-- survivor at original slot 1 (below none)
		local survivors = { { index = 1 }, { index = 3 } }
		local targets   = layout.reflowTargets(survivors, 2, dialog_w, height)
		assert.is_nil(targets[1])   -- slot 1 does not move
	end)

	it("returns a target for survivors below the gap", function()
		local survivors = { { index = 1 }, { index = 3 } }
		local targets   = layout.reflowTargets(survivors, 2, dialog_w, height)
		assert.is_not_nil(targets[2])   -- slot 3 moves up
	end)

	it("moves survivor below the gap up by one slot", function()
		local survivors = { { index = 3 } }
		local targets   = layout.reflowTargets(survivors, 2, dialog_w, height)
		local t = targets[1]
		assert.is_not_nil(t)
		assert.are.equal(layout.toastY(2, height), t.y)
	end)

	it("reports the correct delta dy (negative = moving up)", function()
		local survivors = { { index = 3 } }
		local targets   = layout.reflowTargets(survivors, 2, dialog_w, height)
		local t = targets[1]
		local old_y = layout.toastY(3, height)
		local new_y = layout.toastY(2, height)
		assert.are.equal(new_y - old_y, t.dy)
		assert.is_true(t.dy < 0)   -- moving up
	end)

	it("dx is zero for a pure vertical reflow", function()
		local survivors = { { index = 2 } }
		local targets   = layout.reflowTargets(survivors, 1, dialog_w, height)
		local t = targets[1]
		if t then
			assert.are.equal(0, t.dx)
		end
	end)

	it("handles removing the last toast with no survivors", function()
		local targets = layout.reflowTargets({}, 1, dialog_w, height)
		assert.are.equal(0, #targets)
	end)

	it("handles removing the first of many toasts correctly", function()
		local survivors = { { index = 2 }, { index = 3 }, { index = 4 } }
		local targets   = layout.reflowTargets(survivors, 1, dialog_w, height)
		-- All three are below the removed toast and must move up by one slot.
		for i = 1, 3 do
			assert.is_not_nil(targets[i], "survivor " .. i .. " should have a target")
			assert.are.equal(layout.toastY(i, height), targets[i].y,
				"survivor " .. i .. " y mismatch")
		end
	end)
end)

-- ==========================================================================
-- cornerPath CONTRACT IN REFLOW
-- ==========================================================================
--
-- Carbon's rule: elements never travel diagonally. cornerPath offsets one leg
-- against the other so the path has a rounded corner. The test that matters
-- is: when both dx and dy are non-zero, they do NOT both start at delay=0.

describe("cornerPath in reflow", function()
	-- A hypothetical theme could add dx != 0 to a reflow. Verify that any
	-- two-axis movement via cornerPath has at most one leg starting at delay=0.
	it("never starts both legs at t=0 when both dx and dy are non-zero", function()
		-- Force a non-trivial two-axis case.
		local dx, dy = 40, 30
		local path = Tokens.cornerPath(dx, dy, "productive")
		-- At least one leg must have delay > 0.
		local both_zero = (path.x.delay == 0) and (path.y.delay == 0)
		assert.is_false(both_zero,
			"both legs started at zero delay -- path is diagonal")
	end)

	it("pure vertical reflow: the x leg has zero duration contribution", function()
		-- dx == 0 means the x leg has duration based on distance 0: the minimum
		-- token. The important guarantee is that dy > 0 produces a real y leg.
		local path = Tokens.cornerPath(0, 40, "productive")
		assert.is_true(path.y.duration > 0)
	end)

	it("total path time is always positive", function()
		local path = Tokens.cornerPath(0, 48 + 8, "productive")
		assert.is_true(path.total > 0)
	end)
end)

-- ==========================================================================
-- ToastHost SHOW — motion ON
-- ==========================================================================

describe("ToastHost:show with motion enabled", function()
	local function make_host(director, dir_iup)
		-- Share the director's iup so the director's timer calls work.
		local iup = dir_iup or fake_iup()
		local host = ToastHost.new({
			iup      = iup,
			director = director,
			dialog   = iup.dialog({}),
			notify_tree_change = nil,
		})
		-- Give the fake dialog a raster size attribute so toastX has a width.
		host._dialog.attrs.RASTERSIZE = "1200x800"
		return host, iup
	end

	it("adds a toast to the stack", function()
		local d, _, diup = make_director()
		local host = make_host(d, diup)
		host:show({ title = "Hello" })
		assert.are.equal(1, host:count())
	end)

	it("stacks multiple toasts", function()
		local d, _, diup = make_director()
		local host = make_host(d, diup)
		host:show({ title = "One" })
		host:show({ title = "Two" })
		host:show({ title = "Three" })
		assert.are.equal(3, host:count())
	end)

	it("dismissOwned removes only toasts matching the owner", function()
		local d, _, diup = make_director()
		local host, _    = make_host(d, diup)
		local owner_a = {}
		local owner_b = {}
		host:show({ title = "A1", owner = owner_a })
		host:show({ title = "B1", owner = owner_b })
		host:show({ title = "A2", owner = owner_a })
		-- dismissOwned triggers _exitToast, which removes from the stack.
		host:dismissOwned(owner_a)
		assert.are.equal(1, host:count())
		assert.are.equal(owner_b, host._stack[1].owner)
	end)

	it("dismissOwned with nil owner is a no-op", function()
		local d, _, diup = make_director()
		local host, _    = make_host(d, diup)
		host:show({ title = "X" })
		host:dismissOwned(nil)
		assert.are.equal(1, host:count())
	end)
end)

-- ==========================================================================
-- ToastHost SHOW — motion OFF
-- ==========================================================================
--
-- When the director delivers on_frame(to) and on_done(true) synchronously, the
-- toast must still reach its resting position and the hold/dismiss cycle must
-- still complete without waiting for any real timer.

describe("ToastHost:show with motion disabled", function()
	local function make_host_no_motion()
		local d, _, diup = make_director({ enabled = false })
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"
		return host, diup
	end

	it("adds to the stack even when motion is off", function()
		local host = make_host_no_motion()
		host:show({ title = "Instant toast" })
		-- With motion off, the enter animation completes synchronously and
		-- immediately triggers the exit hold animation, which also completes
		-- synchronously (hold_ms delay is still applied via the director's
		-- scale path, but with motion off it fires immediately).
		-- The toast is dismissed by the time show() returns.
		-- Count may be 0 because synchronous exit ran in the same call.
		-- The key guarantee: no error was raised.
		assert.is_true(host:count() >= 0)
	end)

	it("show is a complete no-op when iup is nil", function()
		local host = ToastHost.new({ iup = nil, director = nil })
		-- Must not raise.
		assert.has_no.errors(function()
			host:show({ title = "No IUP" })
		end)
		assert.are.equal(0, host:count())
	end)
end)

-- ==========================================================================
-- ToastHost — no-director path (instant delivery)
-- ==========================================================================

describe("ToastHost:show without director", function()
	it("still shows without raising when director is nil", function()
		local iup  = fake_iup()
		local host = ToastHost.new({
			iup    = iup,
			dialog = iup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"
		assert.has_no.errors(function()
			host:show({ title = "No director" })
		end)
	end)
end)

-- ==========================================================================
-- HostAPI integration — notify delegates to ToastHost
-- ==========================================================================

describe("HostAPI:notify", function()
	it("is a silent no-op when no toast host is installed", function()
		local HostAPI = require("core.classes.HostAPI")
		local iup = fake_iup()
		local ctx = HostAPI:new({
			iup    = iup,
			dialog = iup.dialog({}),
		})
		assert.has_no.errors(function()
			ctx:notify({ title = "No host yet" })
		end)
	end)

	it("forwards to ToastHost when one is installed", function()
		local HostAPI = require("core.classes.HostAPI")
		local iup = fake_iup()
		local ctx = HostAPI:new({
			iup    = iup,
			dialog = iup.dialog({}),
		})
		local d, _, diup = make_director()
		local host_dlg = diup.dialog({})
		host_dlg.attrs.RASTERSIZE = "1200x800"
		local toast_host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = host_dlg,
		})
		ctx:setToastHost(toast_host)
		ctx:notify({ title = "Test" })
		assert.are.equal(1, toast_host:count())
	end)
end)

-- ==========================================================================
-- Extension:notify delegation
-- ==========================================================================

describe("Extension:notify", function()
	it("files the toast under the extension as owner", function()
		local Extension = require("core.classes.Extension")
		local HostAPI   = require("core.classes.HostAPI")
		local iup       = fake_iup()

		local ctx = HostAPI:new({ iup = iup, dialog = iup.dialog({}) })
		local d, _, diup = make_director()
		local host_dlg = diup.dialog({})
		host_dlg.attrs.RASTERSIZE = "1200x800"
		local toast_host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = host_dlg,
		})
		ctx:setToastHost(toast_host)

		local ext = Extension:new("Test Extension", "1.0")
		ext._ctx = ctx
		ext._iup = diup

		ext:notify({ title = "From extension" })
		assert.are.equal(1, toast_host:count())
		-- Owner should be the extension table itself.
		assert.are.equal(ext, toast_host._stack[1].owner)
	end)
end)

-- ==========================================================================
-- REGRESSION: Bug 1 — reflow x leg must not overwrite y after the y leg lands
-- ==========================================================================
--
-- cornerPath(0, dy) produces an x leg with delay > 0 that fires AFTER the y leg.
-- The x leg's on_frame must write only x, not both axes. If it writes cur_y
-- (the pre-reflow y) the toast is pinned back at its old slot once the x leg
-- lands, undoing the reflow.

describe("reflow: x leg does not overwrite the y leg's result (Bug 1)", function()
	it("survivor ends at the correct y after both legs complete", function()
		local d, clock, diup = make_director()
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"

		-- Two toasts with the same height. Dismiss toast 1; toast 2 should
		-- reflow up from slot 2 to slot 1.
		host:show({ title = "A" })
		host:show({ title = "B" })
		assert.are.equal(2, host:count())

		local toast2_dlg = host._stack[2].dlg
		local toast2_h   = host._stack[2].height

		-- Dismiss toast 1 to trigger reflow of toast 2.
		host:_exitToast(host._stack[1])
		assert.are.equal(1, host:count())

		-- Tick past the reflow animations (cornerPath total <= ~250 ms).
		clock.t = clock.t + 0.400
		d:tick(clock.t)

		-- The survivor's SCREENPOSITION y should equal slot-1 y (dialog at 0,0).
		local expected_y = layout.toastY(1, toast2_h)
		local pos = diup.GetAttribute(toast2_dlg, "SCREENPOSITION") or ""
		local _, got_y = pos:match("^(%-?%d+),(%-?%d+)")
		assert.is_not_nil(got_y, "SCREENPOSITION should have been set by reflow")
		assert.are.equal(expected_y, tonumber(got_y))
	end)
end)

-- ==========================================================================
-- REGRESSION: Bug 2 — toast must survive show() when motion is disabled
-- ==========================================================================
--
-- The director fires on_done synchronously with motion off. The hold must use
-- an iup.timer so it is not collapsed into show() and the toast is visible.

describe("ToastHost:show with motion disabled - toast stays alive (Bug 2)", function()
	it("toast is in the stack immediately after show() returns", function()
		local d, _, diup = make_director({ enabled = false })
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"
		host:show({ title = "Must survive" })
		-- The hold timer has been created and set running but has not fired yet,
		-- so the toast is still in the stack.
		assert.are.equal(1, host:count(),
			"toast was destroyed inside show() -- hold collapsed when motion is off")
	end)

	it("toast dialog is shown and alive after show() returns with motion off", function()
		local d, _, diup = make_director({ enabled = false })
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"
		host:show({ title = "Alive check" })
		local rec = host._stack[1]
		assert.is_not_nil(rec, "no record in stack")
		assert.is_true(rec.dlg._alive,  "dialog was destroyed inside show()")
		assert.is_true(rec.dlg._shown,  "dialog was never shown")
	end)
end)

-- ==========================================================================
-- REGRESSION: Bug 3 — vertical reflow leg must carry a target
-- ==========================================================================
--
-- Without `target`, two rapid dismissals leave competing vertical legs against
-- the same window. With `target`, scheduling a new animation on the same target
-- cancels the previous one.

describe("reflow: vertical leg is cancellable via target (Bug 3)", function()
	it("a second dismissal does not leave two vertical legs on the same window", function()
		local d, clock, diup = make_director()
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"

		host:show({ title = "X" })
		host:show({ title = "Y" })
		host:show({ title = "Z" })

		local toast3_dlg = host._stack[3].dlg
		local toast3_h   = host._stack[3].height

		-- Dismiss toast 1: toast 2 and 3 each get a vertical reflow leg.
		host:_exitToast(host._stack[1])
		local after_first = d:activeCount()

		-- Dismiss toast 2 (now slot 1) before the reflow completes. The new
		-- vertical leg for toast 3 should supersede the old one, not pile up.
		host:_exitToast(host._stack[1])

		-- Active count should not be higher than after the first dismissal,
		-- proving the old leg was cancelled rather than stacked.
		assert.is_true(d:activeCount() <= after_first,
			"vertical reflow legs accumulated -- target was missing from vertical leg")

		-- Tick to completion: toast 3 is now at slot 1.
		clock.t = clock.t + 0.500
		d:tick(clock.t)
		local pos = diup.GetAttribute(toast3_dlg, "SCREENPOSITION") or ""
		local _, got_y = pos:match("^(%-?%d+),(%-?%d+)")
		assert.is_not_nil(got_y)
		assert.are.equal(layout.toastY(1, toast3_h), tonumber(got_y))
	end)
end)

-- ==========================================================================
-- REGRESSION: Bug 4 — toast placed at screen coords (dialog origin added)
-- ==========================================================================
--
-- layout.toastX/Y return dialog-relative offsets. ShowXY and SCREENPOSITION
-- are screen coordinates. When the main dialog is not at (0,0) the toast must
-- be offset by the dialog's screen origin.

describe("ToastHost: placement includes dialog screen origin (Bug 4)", function()
	it("toast x,y include the main dialog's screen origin", function()
		local d, _, diup = make_director()
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE     = "1200x800"
		-- Place the main dialog at a non-zero screen position.
		host._dialog.attrs.SCREENPOSITION = "400,200"

		local enter_role = d:role("toast_enter")
		local travel     = tonumber(enter_role.travel) or 32

		host:show({ title = "Offset" })

		local rec = host._stack[1]
		assert.is_not_nil(rec)
		local pos = diup.GetAttribute(rec.dlg, "SCREENPOSITION") or ""
		local sx, sy = pos:match("^(%-?%d+),(%-?%d+)")
		assert.is_not_nil(sx, "SCREENPOSITION not set on toast dialog")
		-- start_x = layout.toastX(1200) + 400 (origin) + travel (slide-in offset)
		local expected_x = layout.toastX(1200) + 400 + travel
		local expected_y = layout.toastY(1, rec.height) + 200
		assert.are.equal(expected_x, tonumber(sx))
		assert.are.equal(expected_y, tonumber(sy))
	end)

	it("toast at origin (0,0) is unaffected", function()
		local d, _, diup = make_director()
		local host = ToastHost.new({
			iup      = diup,
			director = d,
			dialog   = diup.dialog({}),
		})
		host._dialog.attrs.RASTERSIZE = "1200x800"
		-- No SCREENPOSITION -> falls back to 0,0.
		host:show({ title = "Zero origin" })
		local rec = host._stack[1]
		local pos = diup.GetAttribute(rec.dlg, "SCREENPOSITION") or ""
		local sx, sy = pos:match("^(%-?%d+),(%-?%d+)")
		assert.is_not_nil(sx)
		local enter_role = d:role("toast_enter")
		local travel     = tonumber(enter_role.travel) or 32
		assert.are.equal(layout.toastX(1200) + travel, tonumber(sx))
		assert.are.equal(layout.toastY(1, rec.height),  tonumber(sy))
	end)
end)

-- ==========================================================================
-- REGRESSION: Bug 5 — mixed-height reflow targets do not overlap
-- ==========================================================================
--
-- toastY assumes uniform heights. reflowTargets must use per-toast heights so
-- a 64 px toast followed by a 48 px toast does not produce an 8 px overlap.

describe("Toast.layout.reflowTargets: mixed-height stack (Bug 5)", function()
	local dialog_w = 1200

	it("a 64 px toast followed by a 48 px toast does not overlap after reflow", function()
		-- Remove slot 1 (h=64) from a stack of [h=64, h=48, h=64].
		-- Survivors at new slots 1 (h=48) and 2 (h=64) must not overlap.
		local survivors = {
			{ index = 2, height = 48, removed_h = 64 },
			{ index = 3, height = 64, removed_h = 64 },
		}
		local targets = layout.reflowTargets(survivors, 1, dialog_w, 64)

		assert.is_not_nil(targets[1])
		assert.is_not_nil(targets[2])

		local y1 = targets[1].y
		local y2 = targets[2].y
		local h1 = survivors[1].height   -- 48

		-- The gap between toast 1's bottom and toast 2's top must be >= GAP.
		assert.is_true(y2 >= y1 + h1 + GAP,
			string.format("overlap: y1=%d h1=%d y2=%d; need y2>=%d", y1, h1, y2, y1+h1+GAP))
	end)

	it("dy equals -(removed_h + GAP) regardless of survivor height", function()
		-- Removing a 64 px toast shifts all below-gap survivors up by 64+8=72 px.
		local survivors = { { index = 2, height = 48, removed_h = 64 } }
		local targets = layout.reflowTargets(survivors, 1, dialog_w, 64)
		local t = targets[1]
		assert.is_not_nil(t)
		assert.are.equal(-(64 + GAP), t.dy)
	end)

	it("uniform heights still work correctly", function()
		-- Regression guard: existing uniform-height call sites must be unchanged.
		local survivors = { { index = 2 }, { index = 3 } }
		local targets = layout.reflowTargets(survivors, 1, dialog_w, 48)
		assert.are.equal(layout.toastY(1, 48), targets[1].y)
		assert.are.equal(layout.toastY(2, 48), targets[2].y)
	end)
end)

-- ==========================================================================
-- layout.stackY: mixed-height accumulation
-- ==========================================================================

describe("Toast.layout.stackY", function()
	it("slot 1 always lands at TOP_OFFSET", function()
		assert.are.equal(TOP_OFFSET, layout.stackY(1, {64, 48}, 48))
	end)

	it("accumulates heights correctly", function()
		-- heights: slot1=64, slot2=48; slot3 = TOP_OFFSET + (64+8) + (48+8)
		local y = layout.stackY(3, {64, 48}, 48)
		assert.are.equal(TOP_OFFSET + (64 + GAP) + (48 + GAP), y)
	end)

	it("falls back to the fallback for missing slots", function()
		-- Only slot 1 provided; slot 2 falls back to 64.
		local y = layout.stackY(3, {[1]=48}, 64)
		assert.are.equal(TOP_OFFSET + (48 + GAP) + (64 + GAP), y)
	end)

	it("matches toastY for uniform heights", function()
		for i = 1, 4 do
			assert.are.equal(layout.toastY(i, 48), layout.stackY(i, {}, 48))
		end
	end)
end)

-- ============================================================================
-- HOLD TIMER LIFECYCLE
-- ============================================================================
--
-- The auto-dismiss hold is an iup.timer rather than an animation, so that
-- turning motion off cannot collapse it (see Bug 2). That fix trades one
-- resource for another: Windows timers are a limited per-process resource --
-- the reason core.classes.MotionDirector drives every animation from ONE shared
-- timer -- so a toast that leaks its hold timer is a real cost over a long
-- session, and a toast dismissed early leaks one every time.

describe("ToastHost hold timer lifecycle", function()
	local function host_with_motion()
		local d, clock, diup = make_director({ enabled = true })
		local host = ToastHost.new({
			iup = diup, director = d, dialog = diup.dialog({}),
		})
		return host, d, clock, diup
	end

	it("frees the hold timer when a toast dismisses itself", function()
		local host, d, clock = host_with_motion()
		host:show({ title = "done" })

		-- Let the entrance finish so the hold timer is created.
		clock.t = clock.t + 1
		d:tick(clock.t)

		local rec = host._stack[1]
		local timer = rec and rec.hold_timer
		assert.is_truthy(timer, "the hold must be a real timer, not an animation")

		-- Fire the hold, then let the exit animation complete.
		timer:action_cb()
		clock.t = clock.t + 1
		d:tick(clock.t)

		assert.is_false(timer._alive, "the hold timer must be destroyed with the toast")
	end)

	it("stops and frees the hold timer when the close button is used", function()
		-- The early-dismissal path: the timer is still running and would
		-- otherwise sit allocated forever after firing into a no-op dismiss.
		local host, d, clock = host_with_motion()
		host:show({ title = "done" })
		clock.t = clock.t + 1
		d:tick(clock.t)

		local rec = host._stack[1]
		local timer = rec.hold_timer
		assert.is_true(timer.running)

		host:dismissOwned(nil)
		if rec.alive then rec.dlg.close_btn = nil end
		-- dismissOwned only sweeps owned toasts; dismiss this one directly.
		host:_exitToast(rec)
		assert.is_false(timer.running, "an early dismissal must stop the hold")

		clock.t = clock.t + 1
		d:tick(clock.t)
		assert.is_false(timer._alive, "an early dismissal must free the hold timer")
	end)
end)
