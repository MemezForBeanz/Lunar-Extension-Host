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
-- The scrim draws through `core.lib.Compositor`. These tests run the real
-- manager over a fake backend that records what reached the "screen", so the
-- depth counting, role selection, the layer-fade path and the failure paths are
-- all observable here. Only the native layered window is left to
-- `scripts/win32_overlay_probe.lua` and a live run.

local MotionDirector = require("core.classes.MotionDirector")
local Compositor = require("core.lib.Compositor")
local Scrim = require("core.ui.Scrim")

-- A backend that records presents, fades and hides.
local function fake_backend()
	local b = { presents = {}, fades = {}, hides = 0, opacity = nil, shown = false,
		cover = { 10, 20, 300, 200 } }
	function b:geometry() return { w = 400, h = 300, scale = 1 } end
	function b:present(scene, regions, opacity)
		self.presents[#self.presents + 1] = { scene = scene, regions = regions, opacity = opacity }
		self.opacity, self.shown = opacity, true
	end
	function b:fade(opacity)
		self.fades[#self.fades + 1] = opacity
		self.opacity = opacity
	end
	function b:hide() self.hides = self.hides + 1; self.shown = false end
	function b:rect() return (table.unpack or unpack)(self.cover) end
	return b
end

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

-- Build a Scrim over a fake compositor (or none, with `available = false`).
-- Returns scrim, backend.
local function make_scrim(opts)
	opts = opts or {}
	local backend = fake_backend()
	local comp = Compositor.new(backend)
	local s = Scrim:new({
		iup      = opts.iup or fake_iup(),
		director = opts.director,
		compositor = function()
			if opts.available == false then return nil, "none here" end
			return comp
		end,
		log = opts.log,
	})
	return s, backend, comp
end

-- ============================================================================
-- UNAVAILABLE OVERLAY  (failing-closed path)
-- ============================================================================

describe("Scrim without a compositor", function()
	it("raise() returns false when there is no compositor", function()
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

	it("logs why once, and prepare() reports false", function()
		local lines = {}
		local s = make_scrim({ available = false, log = function(m) lines[#lines + 1] = m end })
		assert.is_false(s:prepare())
		s:raise(); s:raise()
		assert.are.equal(1, #lines)
		assert.truthy(lines[1]:find("none here", 1, true))
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
-- PRESENT FAILURE: depth not incremented
-- ============================================================================

describe("Scrim present failure path", function()
	it("depth is zero and nothing is left on screen if presenting throws", function()
		local s, backend = make_scrim({ available = true })
		function backend:present() error("UpdateLayeredWindow failed") end
		assert.is_false(s:raise())
		assert.are.equal(0, s:depth())
		assert.is_false(backend.shown)
	end)
end)

describe("Scrim present that reports failure", function()
	it("rolls back when present returns false (native failures don't throw)", function()
		local s, backend = make_scrim({ available = true })
		local tries = 0
		function backend:present() tries = tries + 1; return false, "UpdateLayeredWindow failed" end
		assert.is_false(s:raise())
		assert.are.equal(0, s:depth())
		assert.is_false(s:raise())                         -- tried again, not taken as nested
		assert.are.equal(2, tries)
	end)
end)

describe("Scrim lift coalescing", function()
	it("takes the layer down in the director's frame, sharing its one commit", function()
		local dir, clock = make_director()
		local s, backend, comp = make_scrim({ available = true, director = dir })
		s:raise()
		clock.t = 1.0; dir:tick()
		s:lower()
		-- Another effect on the same dialog animates past the lift's end.
		dir:animate({ role = "scrim_in", target = "other", from = 0, to = 1, on_frame = function(v)
			comp:set("other", { z = 10, sprites = { { kind = "fill", x = 0, y = 0, w = 2, h = 2,
				color = 0, alpha = v } }, regions = {} })
			comp:schedule(dir)
		end })
		local before = #backend.presents + backend.hides
		clock.t = 1.6; dir:tick()                           -- lift ends this tick
		assert.are.equal(before + 1, #backend.presents + backend.hides)
	end)
end)

-- ============================================================================
-- WHAT REACHES THE SCREEN
-- ============================================================================

describe("Scrim drawing", function()
	it("is one passive black fill over the cover, faded as a layer", function()
		local dir, clock = make_director()
		local s, backend = make_scrim({ available = true, director = dir })
		s:raise()
		assert.are.equal(1, #backend.presents)
		local first = backend.presents[1]
		assert.are.equal(0, first.opacity)           -- never a full-strength first frame
		assert.are.same({ kind = "fill", x = 10, y = 20, w = 300, h = 200, color = 0, alpha = 1 },
			first.scene[1])
		assert.are.equal(1, #first.scene)
		assert.are.equal("pass", first.regions[1].mode)
		for t = 1, 20 do clock.t = t * 0.05; dir:tick() end
		-- The whole entrance is layer fades: no further renders.
		assert.are.equal(1, #backend.presents)
		assert.is_true(#backend.fades > 1)
		assert.is_true(math.abs(backend.opacity - 128 / 255) < 1e-9)
	end)

	it("lifts by fading, then takes the layer down", function()
		local dir, clock = make_director()
		local s, backend = make_scrim({ available = true, director = dir })
		s:raise()
		clock.t = 1.0; dir:tick()
		s:lower()
		assert.is_true(backend.shown)                 -- not cut on the way out
		clock.t = 2.0; dir:tick()
		assert.are.equal(1, backend.hides)
		assert.is_false(backend.shown)
	end)

	it("a reopen during the lift carries on from the dim on screen", function()
		local dir, clock = make_director()
		local s, backend = make_scrim({ available = true, director = dir })
		s:raise()
		clock.t = 1.0; dir:tick()
		s:lower()
		clock.t = 1.1; dir:tick()
		local mid = backend.opacity
		assert.is_true(mid > 0 and mid < 128 / 255)
		s:raise()
		assert.is_true(backend.shown)
		assert.are.equal(0, backend.hides)
		clock.t = 3.0; dir:tick()
		assert.is_true(math.abs(backend.opacity - 128 / 255) < 1e-9)
		assert.is_true(backend.shown)
	end)

	it("follows a resize of the dialog", function()
		local s, backend, comp = make_scrim({ available = true })
		s:raise()
		backend.cover = { 0, 0, 500, 400 }
		function backend:events() self.events = nil; return { { type = "resize" } } end
		comp:commit()
		local last = backend.presents[#backend.presents]
		assert.are.equal(500, last.scene[1].w)
		assert.is_true(math.abs(last.opacity - 128 / 255) < 1e-9)
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
		local s, backend = make_scrim({ available = true, director = nil })
		local ok = s:raise()
		assert.is_true(ok)
		-- The rest alpha (128 by default when no director role is available).
		assert.is_true(math.abs(backend.opacity - 128 / 255) < 1e-9)
	end)

	it("lower() with no director hides the overlay synchronously", function()
		local s, backend = make_scrim({ available = true, director = nil })
		s:raise()
		s:lower()
		-- After the synchronous fade-to-zero the group goes and the layer hides.
		assert.are.equal(1, backend.hides)
	end)

	it("reset() does not raise even without a director", function()
		local s = make_scrim({ available = true, director = nil })
		assert.has_no.errors(function() s:reset() end)
	end)
end)
