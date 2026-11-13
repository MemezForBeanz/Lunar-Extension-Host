-- spec/imgui_syscolors_spec.lua -- the emulated native controls follow the theme.
--
-- A native scroll bar or a combo box's edges have no IUP attribute: they are Windows'
-- system colours, light grey under any theme. This host draws them from
-- core.imgui.syscolors, which ThemeManager derives from the theme's palette.

local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Color = require("core.imgui.Color")
local iup = require("core.imgui.iup")
local Sys = require("core.imgui.syscolors")

local DARK = {
	bg = "27 29 35", layer01 = "34 36 44", layer02 = "47 51 64", borderSubtle01 = "48 51 62",
	fieldBorder = "109 114 134", text = "214 217 224", textMuted = "167 172 186",
	accent = "108 92 231", accentText = "255 255 255", well = "27 29 35",
}

local function lum(c)
	local r, g, b = Color.unpack(Color.parse(c))
	return 0.299 * r + 0.587 * g + 0.114 * b
end

describe("core.imgui.syscolors", function()
	after_each(function() Sys.fromPalette(nil) end)

	it("starts as Windows' light system colours", function()
		assert.equal("240 240 240", Sys.current.scroll_track)
		assert.equal("255 255 255", Sys.current.window)
	end)

	it("derives every part from a dark palette: no light surface left", function()
		Sys.fromPalette(DARK)
		for _, k in ipairs({ "scroll_track", "scroll_edge", "face", "window", "light", "highlight", "frame" }) do
			assert.is_true(lum(Sys.current[k]) < 100, k .. " is light: " .. Sys.current[k])
		end
		-- and what must stand out still does
		assert.is_true(lum(Sys.current.scroll_thumb) > lum(Sys.current.scroll_track) + 40)
		assert.is_true(lum(Sys.current.text) > 180)
		assert.equal(DARK.accent, Sys.current.sel)
	end)

	it("restores Windows' colours for the classic theme (no palette)", function()
		Sys.fromPalette(DARK)
		Sys.fromPalette(nil)
		assert.same(Sys.LIGHT, Sys.current)
	end)

	it("falls back sensibly on a palette with only the legacy six keys", function()
		Sys.fromPalette({ bg = "20 20 20", surface = "30 30 30", surface2 = "40 40 40", border = "60 60 60",
			text = "220 220 220", accent = "0 120 200" })
		for k, v in pairs(Sys.current) do assert.is_not_nil(Color.parse(v), k) end
		assert.is_true(lum(Sys.current.scroll_track) < 100)
	end)
end)

describe("native control parts drawn in the theme's colours", function()
	local B
	before_each(function()
		B = Null.new({ w = 400, h = 300 })
		R.init(B)
	end)
	after_each(function() Sys.fromPalette(nil) end)

	local function fills(color)
		local want, n = Color.parse(color), 0
		for _, c in ipairs(B.lastFrame()) do if c[1] == "rect_filled" and c[6] == want then n = n + 1 end end
		return n
	end

	it("draws a multiline's native scroll bar in the theme's surface, not Windows' grey", function()
		local lines = {}
		for i = 1, 60 do lines[i] = "line " .. i end
		local t = iup.multiline{ VALUE = table.concat(lines, "\n"), RASTERSIZE = "300x120", SCROLLBAR = "YES" }
		iup.Show(iup.dialog{ iup.vbox{ t }, RASTERSIZE = "400x300", BGCOLOR = DARK.bg }) -- a theme sets this
		R.frame()
		assert.is_true(fills("240 240 240") > 0) -- classic: Windows' track
		Sys.fromPalette(DARK)
		R.redraw(); R.frame()
		assert.equal(0, fills("240 240 240"))
		assert.is_true(fills(Sys.current.scroll_track) > 0)
	end)

	it("draws a drop-down list's button face in the theme's raised surface", function()
		local l = iup.list{ "One", "Two", DROPDOWN = "YES", VALUE = "1" }
		iup.Show(iup.dialog{ iup.vbox{ l }, RASTERSIZE = "400x300", BGCOLOR = DARK.bg }) -- a theme sets this
		R.frame()
		assert.is_true(fills("240 240 240") > 0)
		Sys.fromPalette(DARK)
		R.redraw(); R.frame()
		assert.equal(0, fills("240 240 240"))
		assert.is_true(fills(Sys.current.face) > 0)
	end)
end)
