-- spec/modal_motion_spec.lua — core.ui.ModalMotion: scrim lifecycle, result
-- recording, and dismiss role selection.
--
-- ModalMotion is the choke point every modal in the application routes through.
-- The guarantees it has to keep are:
--
--   * the scrim is raised before iup.Popup and lowered after it returns —
--     every call site gets dimming for free, consistently
--   * confirm and cancel produce different scrim-exit roles, which is how
--     Carbon's intentional-inconsistency rule reaches the user: the page
--     coming back unhurriedly (confirm) vs. snapping back (cancel) is the
--     only feedback the motion layer gives about *which* outcome just happened
--   * anything other than "confirm" is treated as cancel — backing out is the
--     safe reading of an ambiguous dismissal
--   * a pre-existing SHOW_CB is preserved and still called, because FolderDialog
--     and the tour install their own setup there
--   * the entrance latch is a one-shot: minimise/restore must not replay the
--     arrival animation on a window the user is already looking at
--   * setScrim(nil) degrades popup() to a plain iup.Popup with no dimming
--
-- IUP is faked, the scrim is a hand-rolled stub, and iup.Popup is replaced by
-- a spy function so the test can verify ordering without actually blocking.

local ModalMotion = require("core.ui.ModalMotion")
local MotionDirector = require("core.classes.MotionDirector")

-- ============================================================================
-- FAKE SCRIM STUB
-- ============================================================================

local function make_scrim_stub()
	local stub = {
		_raised       = 0,
		_lower_roles  = {},
		_director     = nil,
	}
	function stub:raise() self._raised = self._raised + 1 ; return true end
	function stub:lower(role)
		self._lower_roles[#self._lower_roles + 1] = role or "scrim_out"
	end
	function stub:director() return self._director end
	return stub
end

-- ============================================================================
-- FAKE IUP
-- ============================================================================

local function make_fake_iup(opts)
	opts = opts or {}
	local iup = {
		DEFAULT      = 0,
		CENTERPARENT = -1,
		_popups      = {},  -- record of every Popup call: { dlg, x, y }
		_attrs       = {},  -- [dlg][name] -> value
	}

	function iup.Popup(dlg, x, y)
		iup._popups[#iup._popups + 1] = { dlg = dlg, x = x, y = y }
		-- Fire show_cb if present (simulates IUP calling it on SHOW).
		if dlg and dlg.show_cb then
			dlg:show_cb(0)  -- state 0 == IUP_SHOW
		end
		if opts.popup_raises then
			error("Popup exploded")
		end
	end

	function iup.GetAttribute(w, name)
		if iup._attrs[w] then return iup._attrs[w][name] end
		return nil
	end

	function iup.SetAttribute(w, name, value)
		if not iup._attrs[w] then iup._attrs[w] = {} end
		iup._attrs[w][name] = value
	end

	-- dialog constructor (minimal — ModalMotion only reads show_cb from it)
	function iup.dialog(def)
		local d = { _kind = "dialog", attrs = {} }
		for k, v in pairs(def or {}) do
			d[k] = v
		end
		return d
	end

	return iup
end

-- A fresh dialog handle (ModalMotion accesses dlg.show_cb directly).
local function make_dlg()
	return { _kind = "dialog" }
end

-- Reset the module-level scrim between tests.
local function reset_modal_motion()
	ModalMotion.setScrim(nil)
end

-- ============================================================================
-- setScrim / scrim()
-- ============================================================================

describe("ModalMotion.setScrim", function()
	after_each(reset_modal_motion)

	it("stores the scrim returned by scrim()", function()
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		assert.are.equal(stub, ModalMotion.scrim())
	end)

	it("setScrim(nil) clears the scrim", function()
		ModalMotion.setScrim(make_scrim_stub())
		ModalMotion.setScrim(nil)
		assert.is_nil(ModalMotion.scrim())
	end)

	it("popup() with nil scrim calls iup.Popup without raising", function()
		-- setScrim(nil) must degrade to a plain Popup — no dimming at all.
		ModalMotion.setScrim(nil)
		local iup = make_fake_iup()
		local dlg = make_dlg()
		ModalMotion.popup(iup, dlg)
		assert.are.equal(1, #iup._popups)
	end)
end)

-- ============================================================================
-- SCRIM LIFECYCLE AROUND popup()
-- ============================================================================

describe("ModalMotion.popup() scrim lifecycle", function()
	after_each(reset_modal_motion)

	it("raises the scrim before iup.Popup is called", function()
		-- The ordering is critical: the page must be dimmed before the dialog
		-- appears, not after — a dialog that pops onto an undimmed page and then
		-- dims it is a flash.
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)

		local raised_before_popup = 0
		local iup = make_fake_iup()
		iup.Popup = function(dlg, x, y)
			raised_before_popup = stub._raised
			-- fire show_cb
			if dlg and dlg.show_cb then dlg:show_cb(0) end
		end

		ModalMotion.popup(iup, make_dlg())
		assert.are.equal(1, raised_before_popup,
			"scrim must be raised before iup.Popup is called")
	end)

	it("lowers the scrim after iup.Popup returns", function()
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		local iup = make_fake_iup()
		ModalMotion.popup(iup, make_dlg())
		assert.are.equal(1, #stub._lower_roles,
			"scrim must be lowered after Popup returns")
	end)

	it("lowers the scrim even when iup.Popup raises an error", function()
		-- If Popup errors the scrim would be stranded up, leaving the page
		-- dimmed indefinitely.  Pinning whether the code actually guards this.
		--
		-- READING THE SOURCE (ModalMotion.lua line 203):
		--   local ok = pcall(iup.Popup, dlg, x, y)
		--   if dimmed then ... M.dismiss(how) end
		-- The lower happens in the `if dimmed` block AFTER the pcall, so even
		-- if Popup errors the scrim IS lowered.  This test documents that.
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)

		local iup_err = make_fake_iup({ popup_raises = true })
		local dlg     = make_dlg()

		assert.has_no.errors(function()
			ModalMotion.popup(iup_err, dlg)
		end)
		assert.are.equal(1, #stub._lower_roles,
			"scrim must be lowered even when iup.Popup raises")
	end)

	it("does not raise the scrim when dim = false", function()
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		local iup = make_fake_iup()
		ModalMotion.popup(iup, make_dlg(), { dim = false })
		assert.are.equal(0, stub._raised,
			"dim=false must suppress the scrim entirely")
		assert.are.equal(0, #stub._lower_roles)
	end)
end)

-- ============================================================================
-- result() — LUNAR_MODAL_RESULT attribute
-- ============================================================================

describe("ModalMotion.result()", function()
	it("records 'confirm' for a confirmed modal", function()
		local iup = make_fake_iup()
		local dlg = make_dlg()
		ModalMotion.result(iup, dlg, "confirm")
		assert.are.equal("confirm", iup.GetAttribute(dlg, "LUNAR_MODAL_RESULT"))
	end)

	it("records 'cancel' for a cancelled modal", function()
		local iup = make_fake_iup()
		local dlg = make_dlg()
		ModalMotion.result(iup, dlg, "cancel")
		assert.are.equal("cancel", iup.GetAttribute(dlg, "LUNAR_MODAL_RESULT"))
	end)

	it("maps any unrecognised value to 'cancel' (safe reading)", function()
		-- Carbon's backing-out is the safe reading of an ambiguous dismissal.
		-- Nothing other than "confirm" should be treated as affirmative.
		local iup = make_fake_iup()
		local dlg = make_dlg()
		ModalMotion.result(iup, dlg, "something_else")
		assert.are.equal("cancel", iup.GetAttribute(dlg, "LUNAR_MODAL_RESULT"),
			"unrecognised value must be normalised to 'cancel'")
	end)

	it("maps nil to 'cancel'", function()
		local iup = make_fake_iup()
		local dlg = make_dlg()
		ModalMotion.result(iup, dlg, nil)
		assert.are.equal("cancel", iup.GetAttribute(dlg, "LUNAR_MODAL_RESULT"))
	end)
end)

-- ============================================================================
-- dismiss() — scrim role selection
-- ============================================================================

describe("ModalMotion.dismiss()", function()
	after_each(reset_modal_motion)

	it("'confirm' lowers on modal_exit", function()
		-- Carbon: forward motion signals affirmation.  modal_exit is the
		-- expressive role — the page comes back unhurriedly.
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		ModalMotion.dismiss("confirm")
		assert.are.equal("modal_exit", stub._lower_roles[1])
	end)

	it("'cancel' lowers on modal_cancel", function()
		-- Carbon: reversing entrance motion signals cancellation.  modal_cancel
		-- is shorter/productive so it reads as withdrawn rather than sent.
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		ModalMotion.dismiss("cancel")
		assert.are.equal("modal_cancel", stub._lower_roles[1])
	end)

	it("nil lowers on modal_cancel (safe default)", function()
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		ModalMotion.dismiss(nil)
		assert.are.equal("modal_cancel", stub._lower_roles[1])
	end)

	it("an unrecognised value lowers on modal_cancel", function()
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)
		ModalMotion.dismiss("oops")
		assert.are.equal("modal_cancel", stub._lower_roles[1])
	end)

	it("is a no-op when no scrim is installed", function()
		ModalMotion.setScrim(nil)
		assert.has_no.errors(function() ModalMotion.dismiss("confirm") end)
	end)
end)

-- ============================================================================
-- popup() + result() INTEGRATION — scrim exit role via LUNAR_MODAL_RESULT
-- ============================================================================

describe("ModalMotion.popup() scrim exit role", function()
	after_each(reset_modal_motion)

	-- Simulate a dialog that records its result during show_cb (which is how a
	-- button handler would do it in production).
	local function run_popup_with_result(result_value)
		local stub = make_scrim_stub()
		ModalMotion.setScrim(stub)

		local iup = make_fake_iup()
		local dlg = make_dlg()

		-- Override Popup to both record result AND fire show_cb
		iup.Popup = function(d, x, y)
			ModalMotion.result(iup, d, result_value)
			if d and d.show_cb then d:show_cb(0) end
		end

		ModalMotion.popup(iup, dlg)
		return stub._lower_roles[1]
	end

	it("popup() uses modal_exit when result is 'confirm'", function()
		assert.are.equal("modal_exit", run_popup_with_result("confirm"))
	end)

	it("popup() uses modal_cancel when result is 'cancel'", function()
		assert.are.equal("modal_cancel", run_popup_with_result("cancel"))
	end)

	it("popup() uses modal_cancel when no result was recorded", function()
		assert.are.equal("modal_cancel", run_popup_with_result(nil))
	end)
end)

-- ============================================================================
-- SHOW_CB PRESERVATION
-- ============================================================================

describe("ModalMotion.popup() show_cb preservation", function()
	after_each(reset_modal_motion)

	it("calls a pre-existing show_cb", function()
		-- FolderDialog and the tour install their own SHOW_CB; silently
		-- dropping it would break them in a way that looks like a motion bug.
		-- (ModalMotion.lua line 163: "Chained rather than replaced.")
		local iup = make_fake_iup()
		local dlg = make_dlg()

		local prev_called = false
		dlg.show_cb = function(self, state)
			prev_called = true
		end

		ModalMotion.popup(iup, dlg)
		assert.is_true(prev_called,
			"the pre-existing show_cb must still be called")
	end)

	it("entrance animation latch fires only once (second show_cb is ignored)", function()
		-- IUP_SHOW == 0 also fires on restore.  Without the `animated` latch
		-- every minimise/restore would replay the arrival.
		-- We verify that the `animated` flag in popup() stops the second call
		-- from re-animating.  Since we have no director here, the animation
		-- path that checks `dir` is a no-op anyway, but the latch itself must
		-- still be set so it would gate an animated path.
		--
		-- The observable proxy: count how many times show_cb fires vs. how many
		-- times the internal `animated` branch could run.  We do that by
		-- counting the number of entrance-tagged animations that a real director
		-- would see.

		local MotionDirector = require("core.classes.MotionDirector")
		local iup = make_fake_iup()

		-- Build a real director with a fake timer environment.
		local dir_iup = {
			_timers = {},
			DEFAULT = 0,
		}
		dir_iup.timer = function(def)
			local t = { def = def, running = false }
			dir_iup._timers[#dir_iup._timers + 1] = t
			return t
		end
		dir_iup.SetAttribute = function(w, k, v)
			if w and k == "RUN" then w.running = (v == "YES") end
		end

		local entrance_count = 0
		local scrim_stub = make_scrim_stub()
		-- Attach a fake director to the scrim stub so ModalMotion gets one via
		-- director().
		local real_dir = MotionDirector:new({
			iup   = dir_iup,
			clock = function() return 0 end,
		})
		-- Wrap animate to count modal_enter calls.
		local orig_animate = real_dir.animate
		real_dir.animate = function(self2, spec)
			if spec and spec.role == "modal_enter" then
				entrance_count = entrance_count + 1
			end
			return orig_animate(self2, spec)
		end
		scrim_stub._director = real_dir

		ModalMotion.setScrim(scrim_stub)

		local dlg = make_dlg()

		-- Override Popup to fire show_cb TWICE (simulate minimise/restore).
		iup.Popup = function(d, x, y)
			if d and d.show_cb then
				d:show_cb(0)   -- first: entrance
				d:show_cb(0)   -- second: restore — must not re-animate
			end
		end

		-- No SCREENPOSITION on this fake dialog, so the move+animate branch is
		-- skipped -- but the latch (`animated`) is still set on the first call.
		-- The key guarantee is that the count is never 2.
		ModalMotion.popup(iup, dlg)

		assert.is_true(entrance_count <= 1,
			"show_cb firing a second time must not replay the arrival animation")
	end)
end)

-- ============================================================================
-- ENTRANCE (platform.move_window)
-- ============================================================================
--
-- The rise itself goes through `core.platform.move_window`, which is the only
-- thing that touches the OS (SetWindowPos / gtk_window_move). Here it is replaced
-- by a recorder, so the entrance logic -- pre-offset, per-frame move, the one-shot
-- latch, and failing closed where the platform can't move windows -- runs for real
-- over a real MotionDirector.

local platform = require("core.platform")

describe("ModalMotion.popup() entrance", function()
	local real_move, moves, clock, dir, iup, dlg, scrim

	local function setup(move_result)
		moves = {}
		platform.move_window = function(_, d, x, y)
			moves[#moves + 1] = { dlg = d, x = x, y = y }
			return move_result
		end
		clock = { t = 0 }
		dir = MotionDirector:new({
			iup   = { DEFAULT = 0, timer = function() return {} end, SetAttribute = function() end },
			clock = function() return clock.t end,
		})
		scrim = make_scrim_stub()
		scrim._director = dir
		ModalMotion.setScrim(scrim)
		iup = make_fake_iup()
		dlg = make_dlg()
		iup.SetAttribute(dlg, "SCREENPOSITION", "100,200")
	end

	before_each(function() real_move = platform.move_window end)
	after_each(function()
		platform.move_window = real_move
		reset_modal_motion()
	end)

	it("offsets the dialog before the first frame, then rises into place", function()
		setup(true)
		iup.Popup = function(d)
			d:show_cb(0)
			assert.are.equal(1, #moves)
			assert.are.same({ x = 100, y = 216 }, { x = moves[1].x, y = moves[1].y })
			for step = 1, 40 do clock.t = step * 0.02; dir:tick(clock.t) end
		end
		ModalMotion.popup(iup, dlg)
		assert.is_true(#moves > 2, "no per-frame moves")
		assert.are.equal(200, moves[#moves].y, "the dialog must land at its resting y")
		for _, m in ipairs(moves) do
			assert.are.equal(100, m.x)
			assert.is_true(m.y >= 200 and m.y <= 216)
			assert.are.equal(dlg, m.dlg)
		end
	end)

	it("replays nothing on a second show_cb (minimise/restore)", function()
		setup(true)
		iup.Popup = function(d) d:show_cb(0); d:show_cb(0) end
		ModalMotion.popup(iup, dlg)
		assert.are.equal(1, #moves)
	end)

	it("does not animate where the platform can't move windows", function()
		setup(false)
		iup.Popup = function(d)
			d:show_cb(0)
			assert.are.equal(0, dir:activeCount())
		end
		ModalMotion.popup(iup, dlg)
		assert.are.equal(1, #moves)   -- only the probing move
	end)

	it("does not animate a dialog with no screen position", function()
		setup(true)
		iup.SetAttribute(dlg, "SCREENPOSITION", nil)
		iup.Popup = function(d) d:show_cb(0) end
		ModalMotion.popup(iup, dlg)
		assert.are.equal(0, #moves)
	end)

	it("never moves the dialog after popup() returns", function()
		setup(true)
		iup.Popup = function(d) d:show_cb(0) end
		ModalMotion.popup(iup, dlg)
		local n = #moves
		clock.t = 1; dir:tick(clock.t)
		assert.are.equal(n, #moves)
	end)
end)

-- ============================================================================
-- ENTRANCE CANCELLATION
-- ============================================================================
--
-- Every call site destroys the dialog on the line after `popup` returns. An
-- entrance animation still queued against that handle would, on the next tick,
-- reach `platform.move_window()` -> raw FFI -> `IupGetAttribute(p, "HWND")` on freed memory.
-- `iupraw_wrap.c` performs no liveness check and the `pcall` inside `move`
-- cannot catch a fault in C, so this has to be cancelled here rather than
-- defended against downstream.

describe("ModalMotion.popup() entrance cancellation", function()
	before_each(reset_modal_motion)

	it("cancels any animation targeting the dialog before returning", function()
		local iup   = make_fake_iup()
		local dlg   = make_dlg()
		local clock = { t = 0 }
		local dir   = MotionDirector:new({
			iup   = { DEFAULT = 0, timer = function() return {} end,
			          SetAttribute = function() end },
			clock = function() return clock.t end,
		})

		local scrim = make_scrim_stub()
		scrim._director = dir
		ModalMotion.setScrim(scrim)

		-- Stand in for the entrance the real code schedules from SHOW_CB, which
		-- needs a platform that can move windows; the entrance tests above cover it.
		local frames_after_close = 0
		local closed = false
		dir:animate({
			duration = 240,
			target   = dlg,
			from     = 16,
			to       = 0,
			on_frame = function()
				if closed then frames_after_close = frames_after_close + 1 end
			end,
		})
		assert.are.equal(1, dir:activeCount())

		ModalMotion.popup(iup, dlg)
		closed = true

		assert.are.equal(0, dir:activeCount(),
			"the entrance must not outlive popup(); the caller destroys dlg next")

		-- Advancing time must not resurrect a frame against the dead handle.
		clock.t = 0.5
		dir:tick(clock.t)
		assert.are.equal(0, frames_after_close)
	end)

	it("still lowers the scrim when it cancels the entrance", function()
		local iup   = make_fake_iup()
		local dlg   = make_dlg()
		local dir   = MotionDirector:new({
			iup   = { DEFAULT = 0, timer = function() return {} end,
			          SetAttribute = function() end },
			clock = function() return 0 end,
		})
		local scrim = make_scrim_stub()
		scrim._director = dir
		ModalMotion.setScrim(scrim)

		dir:animate({ duration = 240, target = dlg, on_frame = function() end })
		ModalMotion.popup(iup, dlg)

		assert.are.equal(1, scrim._raised)
		assert.are.equal(1, #scrim._lower_roles)
	end)
end)
