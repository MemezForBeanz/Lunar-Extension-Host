local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("ImGui menus", function()
	it("uses the live theme for detached popup text, surface, hover and separators", function()
		local Reactor = require("core.ui.ThemeReactor")
		local original, manager = Reactor.palette, Reactor.themeManager
		Reactor.themeManager = function() return nil end
		local p = { surface = "20 21 22", text = "230 231 232", surface2 = "40 41 42", border = "60 61 62", accent = "220 10 20", textMuted = "130 131 132" }
		Reactor.palette = function() return p end
		local ok, err = pcall(function()
			local B = Null.new(); Fonts.backend = B; Fonts.reset()
			local menu = iup.menu{ iup.item{ TITLE = "Show icon only" }, iup.separator{}, iup.item{ TITLE = "Disabled", ACTIVE = "NO" } }
			local opened
			require("core.imgui.widgets.menu").popupMenu(menu, 0, 0, { overlay = function(o) opened = o; return { close = function() end } end })
			opened.event{ type = "move", x = 5, y = 8 }
			local function check()
				local dc = Draw.new(B); dc:begin(400, 200); opened.draw(dc)
				local colors, fills = {}, {}
				for _, call in ipairs(B.frame_calls) do
					if call[1] == "text" then colors[call[7]] = call[6] end
					if call[1] == "rect_filled" then fills[call[2]] = call[6] end
				end
				local Color = require("core.imgui.Color")
				assert.equal(Color.parse(p.surface), fills[0])
				assert.equal(Color.parse(p.surface2), fills[3])
				assert.equal(Color.parse(p.accent), fills[5])
				assert.equal(Color.parse(p.text), colors["Show icon only"])
				assert.equal(Color.parse(p.textMuted), colors.Disabled)
			end
			check()
			p.surface, p.text, p.textMuted = "250 251 252", "20 21 22", "100 101 102"
			check() -- the same open popup, after a light-theme switch
		end)
		Reactor.palette = original
		Reactor.themeManager = manager
		if not ok then error(err) end
	end)
	it("uses popup rule overrides rather than generic palette colours", function()
		local Reactor = require("core.ui.ThemeReactor")
		local original = Reactor.themeManager
		local rule = { bg = "11 22 33", fg = "211 222 233", selbg = "44 55 66", seltext = "255 100 90", border = "77 88 99", font = "Segoe UI, 12", radius = 7 }
		local theme = { palette = function() return { surface = "1 2 3", text = "4 5 6" } end,
			rules = function() return { dropdown_list = rule } end }
		Reactor.themeManager = function() return { activeTheme = function() return theme end } end
		local ok, err = pcall(function()
			local B = Null.new(); Fonts.backend = B; Fonts.reset()
			local opened
			local menu = iup.menu{ iup.item{ TITLE = "Selected" }, iup.item{ TITLE = "Normal" } }
			require("core.imgui.widgets.menu").popupMenu(menu, 0, 0, { overlay = function(o) opened = o; return { close = function() end } end })
			opened.event{ type = "move", x = 10, y = 8 }
			local dc = Draw.new(B); dc:begin(400, 200); opened.draw(dc)
			local fills, text = {}, {}
			for _, call in ipairs(B.frame_calls) do
				if call[1] == "rect_filled" then fills[call[2]] = call[6] end
				if call[1] == "text" then text[call[7]] = call end
			end
			local Color = require("core.imgui.Color")
			assert.equal(Color.parse(rule.bg), fills[0])
			assert.equal(Color.parse(rule.selbg), fills[3])
			assert.equal(Color.parse(rule.seltext), text.Selected[6])
			assert.equal(Color.parse(rule.fg), text.Normal[6])
			assert.equal(Fonts.get(rule.font).px, text.Normal[3])
		end)
		Reactor.themeManager = original
		if not ok then error(err) end
	end)
	it("parses menu labels and draws a menubar", function()
		local B = Null.new(); Fonts.backend = B; Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		local menu = iup.menu{ iup.item{ TITLE = "&File\tCtrl+F", VALUE = "ON" }, iup.separator{}, iup.item{ TITLE = "Exit", ACTIVE = "NO" } }
		local cls = require("core.imgui.widgets.menu")
		local dc = Draw.new(B); dc:begin(800, 600)
		cls.drawMenubar(menu, dc, 0, 0, 300, {})
		assert.is_true(#B.frame_calls > 0)
		assert.equals(3, #Element.children(menu))
	end)

	it("fires item actions after selection", function()
		local fired = false
		local item = iup.item{ TITLE = "Run", ACTION = function() fired = true end }
		local menu = iup.menu{ item }
		local opened
		local rt = { overlay = function(opts) opened = opts; return { close = function() end } end }
		require("core.imgui.widgets.menu").popupMenu(menu, 10, 10, rt)
		opened.event({ type = "press", button = 1, x = 20, y = 20 })
		assert.is_true(fired)
	end)

	it("draws the selected-row accent marker", function()
		local B = Null.new(); Fonts.backend = B; Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		local menu = iup.menu{ iup.item{ TITLE = "Run" } }
		local opened
		local rt = { overlay = function(opts) opened = opts; return { close = function() end } end }
		require("core.imgui.widgets.menu").popupMenu(menu, 0, 0, rt)
		opened.event({ type = "move", x = 4, y = 5 })
		local dc = Draw.new(B); dc:begin(200, 100)
		opened.draw(dc)
		local marker = false
		for _, call in ipairs(B.frame_calls) do
			if call[1] == "rect_filled" and call[2] == 5 and call[3] == 9 and call[4] == 7 and call[5] == 23 then
				marker = true
			end
		end
		assert.is_true(marker)
	end)

	it("does not fail when keyboard navigation is sent to an empty menu", function()
		local opened
		local rt = { overlay = function(opts) opened = opts; return { close = function() end } end }
		require("core.imgui.widgets.menu").popupMenu(iup.menu{}, 0, 0, rt)
		assert.is_true(opened.event({ type = "key", key = iup.K_DOWN }))
	end)
end)
