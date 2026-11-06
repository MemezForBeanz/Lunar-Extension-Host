-- Designed by LongCat 2.5 of the Lunar council; adjusted with the module in review.

local AnimatedIcon = require("core.ui.AnimatedIcon")

local function point_count(svg)
	local n = 0
	for _ in svg:gmatch("[ML]") do n = n + 1 end
	return n
end

describe("AnimatedIcon points", function()
	it("keeps a shape that already has the right count", function()
		local square = { { 0, 0 }, { 0, 10 }, { 10, 10 }, { 10, 0 } }
		assert.are.same(square, AnimatedIcon.resample(square, 4))
	end)

	it("resamples the same way every time", function()
		local tri = { { 0, 0 }, { 0, 10 }, { 8, 5 } }
		assert.are.same(AnimatedIcon.resample(tri, 8), AnimatedIcon.resample(tri, 8))
		assert.equals(8, #AnimatedIcon.resample(tri, 8))
	end)

	it("handles the small cases", function()
		assert.are.same({ { 1, 2 } }, AnimatedIcon.resample({ { 1, 2 }, { 3, 4 } }, 1))
		assert.are.same({}, AnimatedIcon.resample({}, 4))
	end)

	it("interpolates between point lists", function()
		local a, b = { { 0, 0 }, { 0, 10 } }, { { 10, 0 }, { 10, 10 } }
		assert.are.same({ { 5, 0 }, { 5, 10 } }, AnimatedIcon.lerpPoints(a, b, 0.5))
	end)

	it("morphs shapes with different point counts", function()
		local a = { { 0, 0 }, { 0, 10 }, { 8, 5 } }
		local b = { { 0, 0 }, { 0, 10 }, { 10, 10 }, { 10, 0 }, { 3, 0 }, { 3, 10 }, { 7, 10 }, { 7, 0 } }
		assert.equals(8, #AnimatedIcon.morphPoints(a, b, 0.5))
		assert.are.same(AnimatedIcon.resample(a, 8), AnimatedIcon.morphPoints(a, b, 0))
		assert.are.same(AnimatedIcon.resample(b, 8), AnimatedIcon.morphPoints(a, b, 1))
	end)

	it("ends the glyph on play and on two pause bars", function()
		assert.are.same(AnimatedIcon.PLAY, AnimatedIcon.glyphShapes(0))
		assert.are.same(AnimatedIcon.PAUSE, AnimatedIcon.glyphShapes(1))
		assert.equals(2, #AnimatedIcon.glyphShapes(0.5))
	end)

	it("moves three bars by height only", function()
		local a, b = AnimatedIcon.barHeights(0), AnimatedIcon.barHeights(0.25)
		assert.equals(3, #a)
		assert.is_not.same(a, b)
		assert.equals(12, point_count(AnimatedIcon.barsSVG(0.25)))
		assert.is_nil(AnimatedIcon.barsSVG(0.25):find("rotate"))
	end)
end)

describe("AnimatedIcon", function()
	local frames, painted, runs

	local function animate(spec)
		runs[#runs + 1] = spec
		spec.cancel = function() spec.cancelled = true end
		return spec
	end

	local function icon(opts)
		opts = opts or {}
		opts.frame = function(name, svg)
			frames[name] = svg
			return name
		end
		opts.paint = function(path) painted[#painted + 1] = path end
		return AnimatedIcon.new(nil, opts)
	end

	before_each(function()
		frames, painted, runs = {}, {}, {}
	end)

	it("shows play until something is playing", function()
		icon()
		assert.equals("morph-0", painted[#painted])
	end)

	it("shows pause while playing, the action a press offers", function()
		assert.equals("morph-8", (function()
			icon({ playing = true })
			return painted[#painted]
		end)())
	end)

	it("lands on the end state with no director", function()
		local i = icon()
		i:setPlaying(true)
		assert.equals("morph-8", painted[#painted])
	end)

	it("morphs through the director and lands where it should", function()
		local i = icon({ animate = animate })
		i:setPlaying(true)
		assert.equals(1, #runs)
		assert.equals(0, runs[1].from)
		assert.equals(1, runs[1].to)
		runs[1].on_frame(0.5)
		assert.equals("morph-4", painted[#painted])
		runs[1].on_frame(1)
		assert.equals("morph-8", painted[#painted])
	end)

	it("reverses from wherever it is", function()
		local i = icon({ animate = animate })
		i:setPlaying(true)
		runs[1].on_frame(0.5)
		i:setPlaying(false)
		assert.is_true(runs[1].cancelled)
		assert.equals(0.5, runs[2].from)
		assert.equals(0, runs[2].to)
	end)

	it("reuses frames instead of writing a new one per paint", function()
		local i = icon({ animate = animate })
		i:setPlaying(true)
		for step = 0, 100 do runs[1].on_frame(step / 100) end
		local count = 0
		for _ in pairs(frames) do count = count + 1 end
		assert.is_true(count <= AnimatedIcon.FRAMES + 1)
	end)

	it("cycles the equalizer until it is turned off", function()
		local i = icon({ animate = animate })
		i:setEqualizer(true)
		assert.equals(1, #runs)
		runs[1].on_frame(0.5)
		assert.matches("^bars%-", painted[#painted])
		runs[1].on_done(true)
		assert.equals(2, #runs)
		i:setEqualizer(false)
		runs[2].on_done(false)
		assert.equals(2, #runs)
		assert.matches("^morph%-", painted[#painted])
	end)

	it("holds one still equalizer frame without motion", function()
		local i = icon()
		i:setEqualizer(true)
		assert.equals(0, #runs)
		assert.matches("^bars%-", painted[#painted])
	end)
end)

describe("Grids sharing a poster cache", function()
	it("each hear about their own finished art, whichever drains first", function()
		local CellGrid = require("core.ui.CellGrid")
		local finished = {}
		local cache = {
			get = function() return nil end,
			request = function() end,
			drain = function()
				local out = finished
				finished = {}
				return out
			end,
		}
		local function fake_grid()
			return { refreshed = {}, refreshCell = function(self, pos) self.refreshed[#self.refreshed + 1] = pos end }
		end
		local a, b = fake_grid(), fake_grid()
		local drain_a = CellGrid.posters(a, cache, function(pos) return "a" .. pos end)
		local drain_b = CellGrid.posters(b, cache, function(pos) return "b" .. pos end)
		a.bits(1, 10, 15)
		b.bits(2, 10, 15)
		finished = { "a1@10x15", "b2@10x15" }
		drain_a()
		drain_b()
		assert.are.same({ 1 }, a.refreshed)
		assert.are.same({ 2 }, b.refreshed)
	end)
end)

describe("Host timers", function()
	it("get their interval before they start, or IUP never runs them", function()
		local HostAPI = require("core.classes.HostAPI")
		local order = {}
		local fake = {}
		function fake.timer(attrs)
			for name in pairs(attrs) do order[#order + 1] = name end
			return {}
		end
		function fake.SetAttribute(_, name) order[#order + 1] = name end
		local host = setmetatable({ iup = fake, _owners = {} }, { __index = HostAPI })
		host:addTimer({ time = 30, run = true, action = function() end }, {})
		assert.are.same({ "TIME", "RUN" }, order)
	end)
end)
