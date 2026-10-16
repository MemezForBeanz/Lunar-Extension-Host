-- spec/motion_roles_spec.lua — theme-defined motion.
--
-- A theme can restyle any named moment in the UI (`tab_transition`,
-- `settings_expand`, ...) without knowing which module implements it. Three
-- properties make that safe, and all three are load-bearing:
--
--   * a theme states only what it CHANGES — every field it omits keeps the
--     Carbon default, so a one-line override cannot accidentally blank a curve
--   * an explicit spec field beats the role — call sites that genuinely need a
--     specific duration must not be silently retimed by a theme
--   * a role a theme names but the host does not recognise degrades to defaults
--     rather than raising, so renaming a role here cannot break a theme switch
--
-- The resolution itself is pure, and the director is driven with a fake IUP and
-- an injected clock, so none of this needs a GUI.

local Tokens = require("core.lib.MotionTokens")
local MotionDirector = require("core.classes.MotionDirector")

local function fake_iup()
	local iup = { DEFAULT = 0 }
	function iup.timer(def) return { def = def, running = false } end
	function iup.SetAttribute(w, name, value)
		if name == "RUN" then w.running = (value == "YES") end
	end
	return iup
end

local function make(roles)
	local clock = { t = 0 }
	local dir = MotionDirector:new({
		iup = fake_iup(),
		clock = function() return clock.t end,
		roles = roles,
	})
	return dir, clock
end

describe("MotionTokens.role", function()
	it("returns the Carbon default when a theme overrides nothing", function()
		local spec = Tokens.role("tab_transition")
		assert.are.equal(Tokens.DURATION.moderate_02, spec.duration)
		assert.are.equal("standard", spec.curve)
		assert.are.equal("productive", spec.style)
	end)

	it("merges per field, keeping everything the theme left out", function()
		local spec = Tokens.role("tab_transition", {
			tab_transition = { style = "expressive" },
		})
		assert.are.equal("expressive", spec.style)
		-- Untouched by the override, so still Carbon.
		assert.are.equal(Tokens.DURATION.moderate_02, spec.duration)
		assert.are.equal("standard", spec.curve)
	end)

	it("passes role-specific extras through", function()
		local spec = Tokens.role("tab_transition", {
			tab_transition = { travel = 0.5, fade = false },
		})
		assert.are.equal(0.5, spec.travel)
		assert.is_false(spec.fade)
	end)

	it("ignores overrides aimed at other roles", function()
		local spec = Tokens.role("tab_drag_caret", {
			tab_transition = { duration = 9999 },
		})
		assert.are.equal(Tokens.DURATION.fast_02, spec.duration)
	end)

	it("falls back to defaults for a role name it does not know", function()
		-- A theme naming a role the host has since renamed must not take the
		-- theme switch down with it.
		assert.has_no.errors(function() Tokens.role("no_such_role") end)
		assert.are.same({}, Tokens.role("no_such_role"))
	end)

	it("returns a fresh table so callers can mutate it", function()
		local a = Tokens.role("tab_transition")
		a.duration = 1
		assert.are.equal(Tokens.DURATION.moderate_02,
			Tokens.role("tab_transition").duration)
	end)

	it("keeps every default role on a published Carbon duration token", function()
		local published = {}
		for _, ms in pairs(Tokens.DURATION) do published[ms] = true end
		for name, spec in pairs(Tokens.ROLES) do
			if spec.duration then
				assert(published[spec.duration],
					"role " .. name .. " uses an off-scale duration")
			end
		end
	end)

	it("dims the background on the token Carbon reserves for it", function()
		-- slow_02 is published as "background dimming" and this is its only
		-- consumer. A scrim retimed onto a shorter token stops reading as the
		-- page receding and starts reading as a flash.
		assert.are.equal(Tokens.DURATION.slow_02, Tokens.ROLES.scrim_in.duration)
	end)

	it("lifts the dim faster than it raises it", function()
		-- Asymmetric on purpose: raising the dim is scene-setting, lowering it is
		-- the user getting control back. Holding a page dim for the full 700 ms
		-- after a dismissal reads as the app being slow to respond.
		assert.is_true(Tokens.ROLES.scrim_out.duration < Tokens.ROLES.scrim_in.duration)
	end)

	it("gives confirming and cancelling a modal different motion", function()
		-- Carbon's intentional inconsistency: the same dialog leaving two
		-- different ways must not look identical, because the outcomes differ.
		local confirm = Tokens.ROLES.modal_exit
		local cancel  = Tokens.ROLES.modal_cancel
		assert.is_true(cancel.duration < confirm.duration)
		assert.are.equal("expressive", confirm.style)
		assert.are.equal("productive", cancel.style)
	end)

	it("makes notifications expressive", function()
		-- Carbon names notification boxes as a case for expressive motion.
		assert.are.equal("expressive", Tokens.ROLES.toast_enter.style)
		assert.are.equal("entrance", Tokens.ROLES.toast_enter.curve)
	end)

	it("staggers list rows at Carbon's 20 ms", function()
		assert.are.equal(20, Tokens.ROLES.list_stagger.step)
	end)
end)

describe("MotionTokens.sequence", function()
	it("orders content the way Carbon publishes it", function()
		-- Static shell first, primary action last. The order is the whole point:
		-- whatever arrives last is what the eye is left on.
		local shell   = Tokens.sequence("shell")
		local body    = Tokens.sequence("body")
		local dynamic = Tokens.sequence("dynamic")
		local primary = Tokens.sequence("primary")

		assert.are.equal(0, shell)
		assert.is_true(body < dynamic)
		assert.is_true(dynamic < primary)
	end)

	it("keeps the whole sequence inside the 500 ms ceiling", function()
		-- The ceiling is what stops sequencing turning into waiting.
		for name in pairs(Tokens.SEQUENCE) do
			if name ~= "total" then
				assert.is_true(Tokens.sequence(name) <= 500,
					"category " .. name .. " starts after the ceiling")
			end
		end
	end)

	it("delays an unknown category to the end rather than raising", function()
		-- A typo should cost a widget some latency, not break the page.
		assert.has_no.errors(function() Tokens.sequence("no_such_category") end)
		assert.are.equal(Tokens.sequence("visual"), Tokens.sequence("no_such_category"))
	end)
end)

describe("MotionDirector role resolution", function()
	it("reports Carbon defaults before any theme is applied", function()
		local dir = make()
		assert.are.equal("standard", dir:role("tab_transition").curve)
	end)

	it("picks up a theme's overrides", function()
		local dir = make()
		dir:setRoles({ tab_transition = { travel = 1, fade = false } })
		local spec = dir:role("tab_transition")
		assert.are.equal(1, spec.travel)
		assert.is_false(spec.fade)
	end)

	it("clears back to Carbon defaults for a theme with no motion table", function()
		local dir = make({ tab_transition = { style = "expressive" } })
		assert.are.equal("expressive", dir:role("tab_transition").style)
		dir:setRoles(nil)
		assert.are.equal("productive", dir:role("tab_transition").style)
	end)
end)

describe("MotionDirector:animate with a role", function()
	it("takes its duration from the role", function()
		local dir, clock = make({ settings_expand = { duration = 200 } })
		local done = false
		dir:animate({
			role = "settings_expand", from = 0, to = 1,
			on_done = function() done = true end,
		})

		clock.t = 0.199
		dir:tick(clock.t)
		assert.is_false(done)

		clock.t = 0.201
		dir:tick(clock.t)
		assert.is_true(done)
	end)

	it("lets an explicit duration beat the role", function()
		local dir, clock = make()
		local done = false
		dir:animate({
			role = "tab_transition",   -- role default is 240 ms
			duration = 50,
			on_done = function() done = true end,
		})

		clock.t = 0.051
		dir:tick(clock.t)
		assert.is_true(done)
	end)

	it("derives the duration from distance when the caller supplies one", function()
		-- A role carrying a fixed duration must not override a call site that
		-- explicitly asked for Carbon's dynamic, distance-scaled duration.
		local dir, clock = make()
		local done = false
		dir:animate({
			role = "settings_expand", distance = 40,
			on_done = function() done = true end,
		})

		local expected = Tokens.duration(40, "productive")
		clock.t = (expected / 1000) * 0.9
		dir:tick(clock.t)
		assert.is_false(done)

		clock.t = (expected / 1000) * 1.1
		dir:tick(clock.t)
		assert.is_true(done)
	end)

	it("does not write the resolved role back into the caller's spec", function()
		-- Call sites legitimately reuse a spec table; rewriting it would mean the
		-- first theme to override a role permanently retimed that call site.
		local dir = make({ tab_transition = { duration = 999 } })
		local spec = { role = "tab_transition", from = 0, to = 1 }
		dir:animate(spec)
		assert.is_nil(spec.duration)
		assert.is_nil(spec.curve)
	end)

	it("still completes instantly when motion is disabled", function()
		-- The off-switch is a choke point in animate(); adding role resolution
		-- ahead of it must not create a path around it.
		local dir = make()
		dir:configure({ enabled = false })

		local frames, completed = {}, nil
		local handle = dir:animate({
			role = "settings_expand", from = 0, to = 42,
			on_frame = function(v) frames[#frames + 1] = v end,
			on_done = function(ok) completed = ok end,
		})

		assert.are.same({ 42 }, frames)
		assert.is_true(completed)
		assert.is_true(handle:done())
		assert.are.equal(0, dir:activeCount())
	end)
end)
