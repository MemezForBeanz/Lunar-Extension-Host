-- Palettes: a light and a dark theme are one choice, and the mode is a toggle.
local SystemTheme = require("core.lib.SystemTheme")
local ThemeTransition = require("core.ui.ThemeTransition")
local ModeIcon = require("core.ui.ModeIcon")
local ThemeManager = require("core.classes.ThemeManager")

local function theme(id, family, label, dark)
	return {
		id = function() return id end, family = function() return family end,
		familyLabel = function() return label end, isDark = function() return dark end,
	}
end

local function manager(themes)
	local mgr = setmetatable({ _themes = themes, _theme_by_id = {} }, { __index = ThemeManager.__instanceDict })
	for _, t in ipairs(themes) do mgr._theme_by_id[t:id()] = t end
	mgr.applied = {}
	mgr._current = themes[1]:id()
	function mgr:apply(id) self.applied[#self.applied + 1] = id; self._current = id end
	return mgr
end

local function sample()
	return manager({
		theme("lunar_dark", "lunar", "Lunar", true),
		theme("lunar_light", "lunar", "Lunar", false),
		theme("solo", "solo", "Solo", true),
	})
end

describe("ThemeManager palettes", function()
	it("collapses a pair into one entry", function()
		local palettes = sample():palettes()
		assert.equal(2, #palettes)
		assert.same({ id = "lunar", label = "Lunar", dark = "lunar_dark", light = "lunar_light" }, palettes[1])
		assert.same({ id = "solo", label = "Solo", dark = "solo" }, palettes[2])
	end)

	it("finds the other mode, and none for a single-mode palette", function()
		local mgr = sample()
		assert.equal("lunar_light", mgr:counterpart("lunar_dark"))
		assert.equal("lunar_dark", mgr:counterpart("lunar_light"))
		assert.is_nil(mgr:counterpart("solo"))
		assert.is_nil(mgr:counterpart("missing"))
	end)

	it("toggles to the other mode", function()
		local mgr = sample()
		assert.is_true(mgr:toggleMode())
		assert.same({ "lunar_light" }, mgr.applied)
	end)

	it("reports a palette with nowhere to toggle to", function()
		local mgr = sample()
		mgr._current = "solo"
		assert.is_false(mgr:toggleMode())
		assert.same({}, mgr.applied)
	end)

	it("keeps the mode on screen when picking a palette", function()
		local mgr = manager({
			theme("a_dark", "a", "A", true), theme("a_light", "a", "A", false),
			theme("b_dark", "b", "B", true), theme("b_light", "b", "B", false),
		})
		mgr._current = "a_light"
		mgr:_choosePalette(mgr:palettes()[2])
		assert.same({ "b_light" }, mgr.applied)
	end)

	it("lands on the only mode a palette has", function()
		local mgr = sample()
		mgr._current = "lunar_light"
		mgr:_choosePalette(mgr:palettes()[2])
		assert.same({ "solo" }, mgr.applied)
	end)
end)

describe("every built-in palette", function()
	local Themes = { "Classic", "ClassicDark", "LunarDark", "LunarLight", "OneDarkPro", "OneLight" }
	it("has both modes", function()
		local list = {}
		for i, name in ipairs(Themes) do list[i] = require("core.classes.Themes." .. name .. "Theme"):new() end
		local palettes = manager(list):palettes()
		assert.equal(3, #palettes)
		for _, palette in ipairs(palettes) do
			assert.is_string(palette.dark)
			assert.is_string(palette.light)
		end
	end)
end)

describe("SystemTheme with palettes", function()
	local function settings(values, locked)
		return {
			values = values, saved = 0,
			get = function(self, key) return self.values[key] end,
			set = function(self, key, value) self.values[key] = value; return true end,
			save = function(self) self.saved = self.saved + 1; return true end,
			isLocked = function(_, key) return locked and locked[key] == true end,
		}
	end

	it("sets both modes when a palette is chosen while matching", function()
		local s = settings({ theme_follow_system = true })
		local mgr = sample()
		local system = SystemTheme.new({ settings = s, theme_manager = mgr, system_dark = function() return true end })
		system:choose("lunar_dark")
		assert.equal("lunar_dark", s.values.theme_dark)
		assert.equal("lunar_light", s.values.theme_light)
	end)

	it("leaves a locked other mode alone", function()
		local s = settings({ theme_follow_system = true, theme_light = "org_light" }, { theme_light = true })
		local system = SystemTheme.new({ settings = s, theme_manager = sample(), system_dark = function() return true end })
		system:choose("lunar_dark")
		assert.equal("org_light", s.values.theme_light)
	end)

	it("stops matching when the mode is flipped by hand", function()
		local s = settings({ theme_follow_system = true })
		local mgr = sample()
		local system = SystemTheme.new({ settings = s, theme_manager = mgr, system_dark = function() return true end })
		assert.is_true(system:switchMode("lunar_light"))
		assert.is_false(s.values.theme_follow_system)
		assert.same({ "lunar_light" }, mgr.applied)
	end)

	it("refuses a manual flip when the org locks the theme", function()
		local s = settings({}, { theme = true })
		local mgr = sample()
		local system = SystemTheme.new({ settings = s, theme_manager = mgr, system_dark = function() return true end })
		assert.is_false(system:switchMode("lunar_light"))
		assert.same({}, mgr.applied)
	end)
end)

describe("ThemeTransition", function()
	local function fixture(opts)
		opts = opts or {}
		local log = {}
		local snaps = 0
		local comp = {
			on = function() end,
			snapshot = function()
				if opts.no_capture then return nil, "no" end
				snaps = snaps + 1
				local snap = { w = 10, h = 10, id = snaps }
				function snap.release() log[#log + 1] = "release" .. snap.id end
				return snap
			end,
			set = function(_, _, group) log[#log + 1] = "cover" .. #group.sprites end,
			commit = function() log[#log + 1] = "commit" end,
			remove = function() log[#log + 1] = "remove" end,
			setOpacity = function(_, _, value) log[#log + 1] = "opacity" .. value end,
			schedule = function() end,
		}
		local run
		local motion = {
			enabled = function() return opts.motion ~= false end,
			animate = function(_, spec)
				local handle = { cancel = function() run = nil end }
				run = spec
				return handle
			end,
		}
		local fade = ThemeTransition.new({ compositor = function() return comp end, motion = motion })
		return fade, log, function() return run end
	end

	it("covers the window before painting, then fades the cover away", function()
		local fade, log, run = fixture()
		fade:run(function() log[#log + 1] = "paint" end)
		assert.same({ "cover1", "commit", "paint" }, log)
		run().on_frame(0.5)
		assert.equal("opacity0.5", log[#log])
		run().on_done(true)
		assert.is_false(fade:busy())
		assert.same({ "remove", "commit", "release1" }, { log[#log - 2], log[#log - 1], log[#log] })
	end)

	it("just paints with motion off", function()
		local fade, log = fixture({ motion = false })
		local painted = 0
		fade:run(function() painted = painted + 1 end)
		assert.equal(1, painted)
		assert.same({}, log)
	end)

	it("just paints when the window can't be captured", function()
		local fade, log = fixture({ no_capture = true })
		local painted = 0
		fade:run(function() painted = painted + 1 end)
		assert.equal(1, painted)
		assert.same({}, log)
	end)

	it("keeps the half-faded picture when pressed again", function()
		local fade, log, run = fixture()
		fade:run(function() end)
		run().on_frame(0.5)
		fade:run(function() end)
		assert.equal("cover2", log[#log - 1])
		run().on_done(true)
		assert.is_false(fade:busy())
		local released = {}
		for _, entry in ipairs(log) do if entry:match("^release") then released[#released + 1] = entry end end
		assert.equal(2, #released)
	end)

	it("takes the cover down when the paint fails", function()
		local fade, log = fixture()
		assert.has_error(function() fade:run(function() error("bad theme", 0) end) end, "bad theme")
		assert.is_false(fade:busy())
		assert.equal("release1", log[#log])
	end)
end)

describe("ModeIcon", function()
	local function bounds(shape)
		local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
		for _, point in ipairs(shape) do
			left, top = math.min(left, point[1]), math.min(top, point[2])
			right, bottom = math.max(right, point[1]), math.max(bottom, point[2])
		end
		return left, top, right, bottom
	end

	it("starts on the tips of lunar-mark's crescent", function()
		local crescent = ModeIcon.shapes(0)
		assert.equal(1, #crescent)
		local found = 0
		for _, point in ipairs(crescent[1]) do
			if math.abs(point[1] - 27.5) < 0.2 and math.abs(point[2] - 20.2) < 0.2 then found = found + 1 end
			if math.abs(point[1] - 11.8) < 0.2 and math.abs(point[2] - 4.5) < 0.2 then found = found + 1 end
		end
		assert.is_true(found >= 2)
	end)

	it("ends on the sun: a ring and eight rays", function()
		local shapes = ModeIcon.shapes(1)
		assert.equal(10, #shapes)
		local left, _, right = bounds(shapes[1])
		assert.is_near(10, left, 0.05)
		assert.is_near(22, right, 0.05)
	end)

	it("stays inside the icon's square at every frame", function()
		for step = 0, ModeIcon.FRAMES do
			for _, shape in ipairs(ModeIcon.shapes(step / ModeIcon.FRAMES)) do
				local left, top, right, bottom = bounds(shape)
				assert.is_true(left >= 0 and top >= 0 and right <= 32 and bottom <= 32, "frame " .. step)
			end
		end
	end)

	it("never writes a number SVG can't read", function()
		for step = 0, ModeIcon.FRAMES do
			local svg = ModeIcon.svg(step / ModeIcon.FRAMES)
			assert.is_nil(svg:find("nan", 1, true))
			assert.is_nil(svg:find("inf", 1, true))
		end
	end)
end)
