local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

describe("ImGui menus", function()
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
