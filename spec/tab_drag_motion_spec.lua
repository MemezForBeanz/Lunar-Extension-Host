-- spec/tab_drag_motion_spec.lua — core.ui.TabDragMotion over the real compositor.
--
-- The drag feedback is a few sprites in the dialog's compositor (band `Z_TAB`, its
-- own group): a caret between tabs for reorder, a scaled outline over the target
-- for combine, a countdown bar for spring-open and a contracting outline for the
-- group-creation flourish. No snapshots are involved. These tests run the real
-- manager over a fake backend, so what reached the "screen" can be read back, one
-- present per director tick can be asserted, and the failing-closed path (no
-- compositor) is covered.

local TabDragMotion = require("core.ui.TabDragMotion")
local Compositor = require("core.lib.Compositor")
local MotionDirector = require("core.classes.MotionDirector")

local STRIP_X, STRIP_Y = 20, 50

local function fake_backend(scale)
	local b = { presents = {}, hides = 0, shown = false, scale = scale or 1 }
	-- GTK-style: IUP coordinates are logical, so unit = scale (Windows reports unit 1).
	function b:geometry() return { w = 1000 * self.scale, h = 700 * self.scale, scale = self.scale, unit = self.scale } end
	function b:present(scene, regions, opacity)
		self.presents[#self.presents + 1] = { scene = scene, regions = regions, opacity = opacity }
		self.shown = true
	end
	function b:hide() self.hides = self.hides + 1; self.shown = false end
	function b:rect() return STRIP_X * self.scale, STRIP_Y * self.scale, 600 * self.scale, 300 * self.scale end
	return b
end

local function make_director()
	local clock = { t = 0 }
	local dir = MotionDirector:new({
		iup = { DEFAULT = 0, timer = function() return {} end, SetAttribute = function() end },
		clock = function() return clock.t end,
	})
	return dir, clock
end

local function make(opts)
	opts = opts or {}
	local backend = fake_backend(opts.scale)
	local comp = Compositor.new(backend)
	local dir, clock = make_director()
	if opts.enabled == false then dir:configure({ enabled = false }) end
	local lines = {}
	local m = TabDragMotion:new({
		iup = {}, director = dir, spring_ms = 500,
		compositor = function()
			if opts.available == false then return nil, "none here" end
			return comp
		end,
		log = function(l) lines[#lines + 1] = l end,
	})
	return m, backend, comp, dir, clock, lines
end

local function last_scene(backend)
	local p = backend.presents[#backend.presents]
	return p and p.scene
end

local STRIP = {}

describe("TabDragMotion sprites", function()
	it("scales strip-local caret and combine bounds at scale 2", function()
		local m, backend, _, dir, clock = make({ scale = 2 })
		m:showCaret(STRIP, 100, 28)
		local caret = last_scene(backend)[1]
		assert.are.same({ 238, 100, 4, 56 }, { caret.x, caret.y, caret.w, caret.h })
		m:showCaret(STRIP, 100.4, 28)
		clock.t = 1
		dir:tick(clock.t)
		assert.are.equal(239, last_scene(backend)[1].x)
		m:showCombine(STRIP, 100, 96, 28)
		clock.t = 10
		dir:tick(clock.t)
		local box = last_scene(backend)[1]
		assert.are.same({ 240, 100, 192, 56, 4 },
			{ box.x, box.y, box.w, box.h, box.thickness })
	end)
	it("doesn't rescale where IUP already works in device pixels (Windows: unit 1)", function()
		local m, backend = make({ scale = 1 })
		function backend:geometry() return { w = 1500, h = 1050, scale = 1.5, unit = 1 } end
		m:showCaret(STRIP, 100, 28)
		local unscaled = last_scene(backend)[1]
		local m2, backend2 = make({ scale = 1 })
		m2:showCaret(STRIP, 100, 28)
		local ref = last_scene(backend2)[1]
		assert.are.same({ ref.x, ref.y, ref.w, ref.h }, { unscaled.x, unscaled.y, unscaled.w, unscaled.h })
	end)
	it("draws the caret as a bar with end caps at the strip origin", function()
		local m, backend = make()
		m:showCaret(STRIP, 100, 28)
		local scene = last_scene(backend)
		assert.are.equal(3, #scene)
		for _, s in ipairs(scene) do
			assert.are.equal("fill", s.kind)
			assert.are.equal(1, s.alpha)
		end
		-- The stem: CARET_W wide, the band tall, centred on x, offset by the strip.
		assert.are.same({ 20 + 100 - 1, 50, 2, 28 }, { scene[1].x, scene[1].y, scene[1].w, scene[1].h })
		assert.are.same({ 20 + 100 - 3, 50, 6, 2 }, { scene[2].x, scene[2].y, scene[2].w, scene[2].h })
		assert.are.same({ 20 + 100 - 3, 50 + 28 - 2, 6, 2 }, { scene[3].x, scene[3].y, scene[3].w, scene[3].h })
	end)

	it("uses the palette accent as an integer RGB colour", function()
		local m, backend = make()
		m:showCaret(STRIP, 10, 28)
		local c = last_scene(backend)[1].color
		assert.are.equal("number", type(c))
		assert.is_true(c >= 0 and c <= 0xffffff)
	end)

	it("draws combine as a stroke that scales up about the target's centre", function()
		local m, backend, _, dir, clock = make()
		m:showCombine(STRIP, 100, 96, 28)
		local first = last_scene(backend)
		assert.are.equal(1, #first)
		assert.are.equal("stroke", first[1].kind)
		assert.are.equal(2, first[1].thickness)
		-- Starts at 0.8 scale: narrower than the target and centred on it.
		assert.is_true(first[1].w < 96)
		assert.are.equal(20 + 100 + math.floor((96 - first[1].w) / 2 + 0.5), first[1].x)

		clock.t = 10
		dir:tick(clock.t)
		local settled = last_scene(backend)[1]
		assert.are.same({ 120, 50, 96, 28 }, { settled.x, settled.y, settled.w, settled.h })
	end)

	it("draws the spring countdown as a bar that fills with time", function()
		local m, backend, _, dir, clock = make()
		m:showCaret(STRIP, 10, 28)
		m:showSpring(STRIP, 200, 80, 28)
		local function bar()
			local scene = last_scene(backend)
			return scene[#scene]
		end
		clock.t = 0.25
		dir:tick(clock.t)
		local half = bar()
		assert.are.equal(3, half.h)
		assert.are.equal(20 + 200, half.x)
		assert.are.equal(50 + 28 - 3, half.y)
		assert.is_true(half.w > 0 and half.w < 80)
		clock.t = 0.6
		dir:tick(clock.t)
		assert.are.equal(80, bar().w)
		m:clearSpring()
		assert.are.equal(3, #last_scene(backend))   -- caret only
	end)

	it("slides the caret to a new gap instead of jumping", function()
		local m, backend, _, dir, clock = make()
		m:showCaret(STRIP, 100, 28)
		m:showCaret(STRIP, 300, 28)
		assert.are.equal(20 + 100 - 1, last_scene(backend)[1].x)   -- not there yet
		clock.t = 0.05
		dir:tick(clock.t)
		local mid = last_scene(backend)[1].x
		assert.is_true(mid > 119 and mid < 319)
		clock.t = 5
		dir:tick(clock.t)
		assert.are.equal(20 + 300 - 1, last_scene(backend)[1].x)
	end)

	it("every sprite it emits passes scene validation", function()
		-- commit() raises on an invalid scene, so reaching the backend proves it.
		local m, backend, _, dir, clock = make()
		m:showCaret(STRIP, 100.4, 28)
		m:showCombine(STRIP, 100.6, 96.2, 28)
		m:showSpring(STRIP, 200, 80, 28)
		clock.t = 0.123
		dir:tick(clock.t)
		assert.is_true(#backend.presents > 0)
	end)
end)

describe("TabDragMotion merge flourish", function()
	it("contracts from the source span to the new tab and calls done once", function()
		local m, backend, comp, dir, clock = make()
		local done = 0
		m:playMerge(STRIP, { x = 0, w = 200 }, { x = 0, w = 100 }, 28, function() done = done + 1 end)
		local first = last_scene(backend)[1]
		assert.are.equal("stroke", first.kind)
		assert.are.equal(200, first.w)

		clock.t = 10
		dir:tick(clock.t)
		assert.are.equal(1, done)
		assert.is_nil(next(comp.groups), "the group must be removed at the end")
		assert.is_false(backend.shown)
	end)

	it("still calls done when motion is switched off", function()
		local m, backend = make({ enabled = false })
		local done = 0
		m:playMerge(STRIP, { x = 0, w = 200 }, { x = 0, w = 100 }, 28, function() done = done + 1 end)
		assert.are.equal(1, done)
		assert.are.equal(0, #backend.presents)
	end)
end)

describe("TabDragMotion on the compositor", function()
	it("presents one frame per director tick, shared with other effects", function()
		local m, backend, comp, dir, clock = make()
		m:showCaret(STRIP, 100, 28)
		m:showCaret(STRIP, 300, 28)           -- a slide in flight
		m:showSpring(STRIP, 200, 80, 28)      -- and a countdown
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

	it("keeps its own group, apart from the tab transition's", function()
		local m, _, comp = make()
		m:showCaret(STRIP, 100, 28)
		assert.is_not_nil(comp.groups["tab-drag"])
		assert.are.equal(Compositor.Z_TAB, comp.groups["tab-drag"].z)
		comp:set("tab-transition", { z = Compositor.Z_TAB, regions = {}, sprites = {} })
		m:clear()
		assert.is_nil(comp.groups["tab-drag"])
		assert.is_not_nil(comp.groups["tab-transition"])
	end)

	it("clear() cancels its animations, removes the group and hides the overlay", function()
		local m, backend, comp, dir = make()
		m:showCaret(STRIP, 100, 28)
		m:showCaret(STRIP, 300, 28)
		m:showSpring(STRIP, 200, 80, 28)
		assert.is_true(dir:activeCount() > 0)
		m:clear()
		assert.are.equal(0, dir:activeCount())
		assert.is_nil(next(comp.groups))
		assert.is_false(backend.shown)
	end)

	it("follows a resize by redrawing at the strip's new place", function()
		local m, backend, comp = make()
		m:showCaret(STRIP, 100, 28)
		local before = #backend.presents
		function backend:rect() return 70, 90, 600, 300 end
		comp:_event("resize", { w = 1200, h = 800 })
		comp:commit()
		assert.is_true(#backend.presents > before)
		assert.are.equal(70 + 100 - 1, last_scene(backend)[1].x)
		assert.are.equal(90, last_scene(backend)[1].y)
	end)

	it("clear() before anything was shown touches nothing", function()
		local m, backend = make()
		m:clear()
		m:clearSpring()
		assert.are.equal(0, #backend.presents)
		assert.are.equal(0, backend.hides)
	end)
end)

describe("TabDragMotion without a compositor", function()
	it("every feedback call is a no-op and the drag still works", function()
		local m, backend, _, dir, _, lines = make({ available = false })
		m:showCaret(STRIP, 100, 28)
		m:showCombine(STRIP, 100, 96, 28)
		m:showSpring(STRIP, 100, 96, 28)
		m:clearSpring()
		m:clear()
		assert.are.equal(0, #backend.presents)
		assert.are.equal(0, dir:activeCount())
		assert.are.equal(1, #lines)
	end)

	it("playMerge() still calls done exactly once", function()
		local m = make({ available = false })
		local done = 0
		m:playMerge(STRIP, { x = 0, w = 200 }, { x = 0, w = 100 }, 28, function() done = done + 1 end)
		assert.are.equal(1, done)
	end)

	it("does nothing when the strip has no rectangle", function()
		local m, backend = make()
		function backend:rect() return nil end
		m:showCaret(STRIP, 100, 28)
		assert.are.equal(0, #backend.presents)
	end)
end)
