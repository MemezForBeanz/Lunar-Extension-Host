-- spec/scrim_spec.lua — core.ui.Scrim: depth counting, role selection, and
-- degraded-mode guarantees.
--
-- The scrim is what tells the user that a modal surface is on a *higher layer*
-- rather than beside them in the same one. That contract only holds when the
-- depth accounting is exactly right: one `lower()` for every `raise()`, no more,
-- no less. A scrim that lifts while a modal is still on screen (or that stays
-- down when nothing is up) breaks the spatial model Carbon builds the whole
-- layering story around.
--
-- Because `core.ui.MotionOverlay` requires FFI + a real HWND, it latches
-- `available()` to false in the busted suite.  We inject a fake overlay into
-- `package.loaded` before requiring Scrim so that tests can toggle availability
-- and observe every branch of the depth-counting, role-selection and failure
-- paths.  The one thing that genuinely cannot be covered without a live window
-- is the GDI alpha path inside MotionOverlay itself — that is documented at the
-- bottom of this file.

local MotionDirector = require("core.classes.MotionDirector")

-- ============================================================================
-- FAKE OVERLAY
-- ============================================================================
-- Injects a controllable stand-in for core.ui.MotionOverlay into the require
-- cache before Scrim is loaded.  Scrim calls MotionOverlay:new(), so our fake
-- returns a new instance table each time.

local fake_overlay_meta  -- forward ref, defined below

local function make_fake_overlay(avail)
	local inst = {
		_available = avail,
		_alpha     = nil,
		_shown     = false,
		_hidden    = 0,
		_set_alpha_calls = 0,
		_show_cb   = nil,  -- the callback Scrim passes to show()
		_show_result = true,  -- what show() will return
	}
	setmetatable(inst, fake_overlay_meta)
	return inst
end

fake_overlay_meta = {
	__index = {
		available = function(self) return self._available end,
		prepare   = function(self) return self._available end,
		setAlpha  = function(self, v)
			self._set_alpha_calls = self._set_alpha_calls + 1
			self._alpha = v
		end,
		show      = function(self, cover, cb)
			self._show_cb   = cb
			if not self._show_result then return false end
			self._shown = true
			return true
		end,
		hide      = function(self)
			self._hidden = self._hidden + 1
			self._shown  = false
		end,
		destroy   = function(self) end,
	}
}

-- The fake class table that Scrim requires as "core.ui.MotionOverlay".
local FakeOverlayClass = {
	_last = nil,  -- the most-recently constructed instance
	_avail = false,
}
FakeOverlayClass.__index = FakeOverlayClass
function FakeOverlayClass:new(opts)
	local inst = make_fake_overlay(self._avail)
	self._last = inst
	return inst
end

-- Install the fake *before* Scrim is loaded so its require("core.ui.MotionOverlay")
-- picks it up.
package.loaded["core.ui.MotionOverlay"] = FakeOverlayClass

local Scrim = require("core.ui.Scrim")

-- ============================================================================
-- HELPERS
-- ============================================================================

local function fake_iup()
	local iup = { DEFAULT = 0, _timers = {} }
	function iup.timer(def)
		local t = { def = def, running = false }
		iup._timers[#iup._timers + 1] = t
		return t
	end
	function iup.SetAttribute(w, name, value)
		if w and name == "RUN" then w.running = (value == "YES") end
	end
	return iup
end

-- Director with an injectable clock.
local function make_director(opts)
	opts = opts or {}
	local iup   = fake_iup()
	local clock = { t = 0 }
	local dir   = MotionDirector:new({
		iup     = iup,
		clock   = function() return clock.t end,
		enabled = opts.enabled ~= false,
	})
	return dir, clock, iup
end

-- Build a Scrim whose overlay has controllable availability.
-- Returns scrim, fake_overlay_instance.
local function make_scrim(opts)
	opts = opts or {}
	-- Toggle the class-level flag so the next :new() builds with this value.
	FakeOverlayClass._avail = (opts.available ~= false)

	local dir = opts.director  -- may be nil

	local s = Scrim:new({
		iup      = opts.iup or fake_iup(),
		director = dir,
	})
	-- The overlay instance Scrim just constructed is in FakeOverlayClass._last.
	local ov = FakeOverlayClass._last
	return s, ov
end

-- ============================================================================
-- UNAVAILABLE OVERLAY  (failing-closed path)
-- ============================================================================

describe("Scrim with unavailable overlay", function()
	it("raise() returns false when the overlay is not available", function()
		-- Carbon rule: everything here is decoration around a modal that works
		-- without it.  Scrim must report failure without side-effects.
		local s = make_scrim({ available = false })
		assert.is_false(s:raise())
	end)

	it("raise() does NOT leave the depth counter incremented on failure", function()
		-- Pinning the explicit decrement-on-failure path at Scrim.lua line 177.
		-- If the depth leaked, a second raise() (after the overlay recovered)
		-- would appear to be a nested raise and skip the entrance animation,
		-- silently breaking the first-raise guarantee.
		local s = make_scrim({ available = false })
		s:raise()
		assert.are.equal(0, s:depth())
	end)

	it("visible() is false after a failed raise", function()
		local s = make_scrim({ available = false })
		s:raise()
		assert.is_false(s:visible())
	end)
end)

-- ============================================================================
-- DEPTH COUNTING  (the nested-modal case)
-- ============================================================================

describe("Scrim depth counting", function()
	-- overlay show() will succeed; director is nil so fades land synchronously.

	it("depth is 1 after one raise()", function()
		local s = make_scrim({ available = true })
		s:raise()
		assert.are.equal(1, s:depth())
	end)

	it("depth is 2 after two raise() calls", function()
		-- FolderDialog raises the scrim, then opens a name-prompt modal that
		-- raises it again.  The page must stay dimmed until both are closed.
		local s = make_scrim({ available = true })
		s:raise()
		s:raise()
		assert.are.equal(2, s:depth())
	end)

	it("two raise() then one lower() leaves the page still dimmed", function()
		-- The inner modal (name prompt) has been dismissed but the outer one
		-- (FolderDialog) is still on screen.  The scrim must not lift yet.
		local s = make_scrim({ available = true })
		s:raise()
		s:raise()
		s:lower()
		assert.is_true(s:visible())
		assert.are.equal(1, s:depth())
	end)

	it("two raise() then two lower() lifts the scrim", function()
		-- Both modals dismissed: the page comes back.
		local s = make_scrim({ available = true })
		s:raise()
		s:raise()
		s:lower()
		s:lower()
		assert.is_false(s:visible())
		assert.are.equal(0, s:depth())
	end)

	it("lower() below zero depth is harmless", function()
		-- Extra lower() calls from error paths must not underflow the counter.
		local s = make_scrim({ available = true })
		assert.has_no.errors(function()
			s:lower()
			s:lower()
		end)
		assert.are.equal(0, s:depth())
	end)

	it("visible() reflects depth correctly", function()
		local s = make_scrim({ available = true })
		assert.is_false(s:visible())
		s:raise()
		assert.is_true(s:visible())
		s:lower()
		assert.is_false(s:visible())
	end)
end)

-- ============================================================================
-- NESTED RAISE DOES NOT RE-ANIMATE
-- ============================================================================

describe("Scrim nested raise animation latch", function()
	it("a nested raise() does not start a new fade animation", function()
		-- The scrim is already at rest at full opacity when the inner modal
		-- opens.  Re-running the entrance would pulse the page darker and back
		-- for a change the user did not make.  Pinning Scrim.lua lines 159-163.
		local dir, clock = make_director()
		local s = make_scrim({ available = true, director = dir })

		s:raise()  -- first raise: depth becomes 1, fade is scheduled
		local count_after_first = dir:activeCount()

		-- Advance past the first fade to settle it.
		clock.t = 1.0
		dir:tick()
		local count_settled = dir:activeCount()
		assert.are.equal(0, count_settled)

		s:raise()  -- nested raise: depth becomes 2, must NOT schedule another fade
		local count_after_nested = dir:activeCount()
		assert.are.equal(0, count_after_nested,
			"nested raise must not schedule an entrance animation")
	end)
end)

-- ============================================================================
-- SHOW() FAILURE: depth not incremented
-- ============================================================================

describe("Scrim show() failure path", function()
	it("depth is zero if overlay:show() returns false", function()
		-- Scrim:raise() increments depth, calls show(), and decrements if show
		-- fails (Scrim.lua line 177).  Pin that the counter is clean afterwards.
		local s, ov = make_scrim({ available = true })
		ov._show_result = false  -- force show() to fail
		local ok = s:raise()
		assert.is_false(ok)
		assert.are.equal(0, s:depth())
	end)
end)

-- ============================================================================
-- lower() ROLE SELECTION
-- ============================================================================

describe("Scrim lower() role selection", function()
	-- Carbon's intentional-inconsistency rule: confirming and cancelling must
	-- feel different.  The scrim exit carries that distinction via the role.
	-- We verify by watching which animation role the director receives.

	local function roles_from_lower(how)
		local dir, clock = make_director()
		local s = make_scrim({ available = true, director = dir })

		-- Patch the director to record the role of every animate() call.
		local seen_roles = {}
		local orig_animate = dir.animate
		dir.animate = function(self2, spec)
			if spec and spec.role then
				seen_roles[#seen_roles + 1] = spec.role
			end
			return orig_animate(self2, spec)
		end

		s:raise()
		-- Advance past the entrance so depth == 1 and no animation is in flight.
		clock.t = 1.0 ; dir:tick()
		seen_roles = {}  -- reset; only care about the lower() role

		if how == nil then
			s:lower()
		else
			s:lower(how)
		end
		return seen_roles
	end

	it("lower() with no argument uses the scrim_out role", function()
		-- Default role is "scrim_out" (Scrim.lua line 206).
		local roles = roles_from_lower(nil)
		assert.are.equal(1, #roles)
		assert.are.equal("scrim_out", roles[1])
	end)

	it("lower('modal_cancel') passes that role to the director", function()
		-- ModalMotion.dismiss() calls lower('modal_cancel') for a cancelled
		-- dialog; the shorter productive timing makes the cancel read different
		-- from a confirm.
		local roles = roles_from_lower("modal_cancel")
		assert.are.equal(1, #roles)
		assert.are.equal("modal_cancel", roles[1])
	end)

	it("lower('modal_exit') passes that role to the director", function()
		local roles = roles_from_lower("modal_exit")
		assert.are.equal(1, #roles)
		assert.are.equal("modal_exit", roles[1])
	end)
end)

-- ============================================================================
-- reset()
-- ============================================================================

describe("Scrim reset()", function()
	it("drops depth to zero regardless of how many raises are outstanding", function()
		local dir, clock = make_director()
		local s = make_scrim({ available = true, director = dir })
		s:raise()
		s:raise()
		s:raise()
		assert.are.equal(3, s:depth())
		s:reset()
		assert.are.equal(0, s:depth())
	end)

	it("cancels an in-flight fade animation", function()
		local dir, clock = make_director()
		local s = make_scrim({ available = true, director = dir })
		s:raise()
		assert.is_true(dir:activeCount() >= 1, "entrance animation should be in flight")
		s:reset()
		assert.are.equal(0, dir:activeCount(),
			"reset() must cancel the in-flight animation")
	end)

	it("is harmless when depth is already zero", function()
		local s = make_scrim({ available = true })
		assert.has_no.errors(function() s:reset() end)
		assert.are.equal(0, s:depth())
	end)
end)

-- ============================================================================
-- NO DIRECTOR — synchronous fade
-- ============================================================================

describe("Scrim without a director", function()
	-- When there is no director, _fade() sets the alpha directly and calls
	-- on_done immediately (Scrim.lua lines 245-248).

	it("raise() completes without raising when no director is attached", function()
		-- The overlay is available but no director is wired up.  The fade lands
		-- synchronously — the bar is at its end value when raise() returns.
		local s, ov = make_scrim({ available = true, director = nil })
		local ok = s:raise()
		assert.is_true(ok)
		-- The overlay should have received setAlpha with the rest alpha (128 by
		-- default when no director role is available).
		assert.are.equal(128, ov._alpha)
	end)

	it("lower() with no director hides the overlay synchronously", function()
		local s, ov = make_scrim({ available = true, director = nil })
		s:raise()
		s:lower()
		-- After the synchronous fade-to-zero on_done is called, hide() is invoked.
		assert.are.equal(1, ov._hidden)
	end)

	it("reset() does not raise even without a director", function()
		local s = make_scrim({ available = true, director = nil })
		assert.has_no.errors(function() s:reset() end)
	end)
end)

-- ============================================================================
-- WHAT CANNOT BE COVERED IN BUSTED
-- ============================================================================
--
-- The following behaviours require `core.ui.MotionOverlay` to actually work —
-- which means FFI, a real HWND, and a valid WS_EX_LAYERED window:
--
--   1. The GDI/alpha path in MotionOverlay:setAlpha().  We verify that Scrim
--      *calls* setAlpha with the right value (via the fake), but whether that
--      value reaches the Win32 layer cannot be observed here.
--
--   2. MotionOverlay:show() geometry: the overlay is sized and positioned to
--      cover a real IUP widget whose HWND must exist.
--
--   3. The prepare() warm-up path: creating and mapping the overlay window
--      before any modal opens (the re-entrancy hazard described in the header).
--
-- These are exercised by scripts/motion_check.lua against the running host.
