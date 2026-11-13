local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local iup = require("core.imgui.iup")
local Draw = require("core.imgui.Draw")

local function setup()
	Fonts.backend = Null.new(); Fonts.reset()
	Element.globals.DEFAULTFONT = "Segoe UI, 10"
	Element.globals.DLGBGCOLOR = "30 30 30"
	Element.globals.DLGFGCOLOR = "240 240 240"
	local backend = Null.new()
	local dc = Draw.new(backend); dc:begin(640, 480)
	return backend, dc
end
local function layout(tab)
	local c = Classes.get("flattabs")
	local L = {
		natural = function() return 70, 30 end,
		place = function(child, x, y, w, h)
			local s = Element.state(child); s.x, s.y, s.w, s.h = x, y, w, h
		end,
	}
	L.set = L.place -- pages get the client rect as is (iFlatTabsSetChildrenCurrentSizeMethod)
	local s = Element.state(tab); s.x, s.y, s.w, s.h = 0, 0, 240, 100
	c.place(tab, s, L)
	return c, s
end

describe("imgui flattabs", function()
	it("places follow buttons after visible tabs in either orientation", function()
		for _, side in ipairs({ "TOP", "LEFT" }) do
			setup()
			local tabs = iup.flattabs{ iup.user{}, TABTITLE0 = "One", TABTYPE = side, TABSBREADTH = "42",
				EXTRABUTTONS = "2", EXTRATITLE1 = "+", EXTRATITLE2 = "<", EXTRAFOLLOW1 = "YES" }
			local cls, st = layout(tabs)
			local id
			tabs.extrabutton_cb = function(_, n) id = n end
			local rt = { redraw = function() end }
			local last = 0
			for at = 0, (side == "TOP" and st.w or st.h) - 1 do
				if iup.ConvertXYToPos(tabs, side == "TOP" and at or 8, side == "TOP" and 8 or at) == 0 then last = at end
			end
			cls.event(tabs, st, { type = "press", button = 1, x = side == "TOP" and last + 2 or 8, y = side == "TOP" and 8 or last + 2 }, rt)
			assert.equal(1, id)
			iup.SetAttribute(tabs, "TABVISIBLE0", "NO")
			id = nil
			cls.event(tabs, st, { type = "press", button = 1, x = 8, y = 8 }, rt)
			assert.equal(1, id)
		end
	end)
	it("lays every page into the client rect and exposes IUP values", function()
		setup()
		local a, b = iup.user{ NAME = "a" }, iup.user{ NAME = "b" }
		local tabs = iup.flattabs{ a, b, TABTITLE0 = "One", TABTITLE1 = "Two", TABSPADDING = "8x4" }
		local c, s = layout(tabs)
		assert.are.equal("2", iup.GetAttribute(tabs, "COUNT"))
		-- VALUE is IupGetName of the child (an automatic name when it has none), not NAME
		assert.are.equal(a, iup.GetHandle(iup.GetAttribute(tabs, "VALUE")))
		assert.matches("^_IUP_NAME%(", iup.GetAttribute(tabs, "VALUE"))
		iup.SetHandle("tab_a", a)
		assert.are.equal("tab_a", iup.GetAttribute(tabs, "VALUE"))
		assert.are.equal("0", iup.GetAttribute(tabs, "VALUEPOS"))
		assert.are.equal(a, iup.GetAttributeHandle(tabs, "VALUE_HANDLE"))
		assert.is_true(Element.state(a).y > s.y)
		assert.are.equal(Element.state(a).x, Element.state(b).x)
		assert.are.equal(Element.state(a).w, Element.state(b).w)
		assert.is_true(c.natural(tabs, s, { natural = function() return 70, 30 end }) >= 70)
	end)

	it("supports hidden strips, hidden tabs, side strips and active lines", function()
		local backend, dc = setup()
		local a, b, cpage = iup.user{ NAME = "a" }, iup.user{ NAME = "b" }, iup.user{ NAME = "c" }
		local tabs = iup.flattabs{ a, b, cpage, SHOWTABS = "NO", TABTYPE = "LEFT", TABSBREADTH = "42",
			TABSACTIVELINE = "255 0 0", TABVISIBLE1 = "NO" }
		local cls, st = layout(tabs)
		cls.draw(tabs, st, dc, { redraw = function() end })
		assert.are.equal("0", iup.GetAttribute(tabs, "VALUEPOS"))
		iup.SetAttribute(tabs, "SHOWTABS", "YES")
		iup.SetAttribute(tabs, "TABVISIBLE0", "NO")
		layout(tabs)
		assert.are.equal("2", iup.GetAttribute(tabs, "VALUEPOS"))
		local x, y, w = Element.state(cpage).x, Element.state(cpage).y, Element.state(cpage).w
		assert.are.equal(43, x)
		assert.are.equal(197, w)
		assert.is_true(y >= 0)
		assert.is_true(#backend:lastFrame() >= 0)
	end)

	it("fires tab change and flat callbacks with IUP arguments", function()
		setup()
		local seen = {}
		local a, b = iup.user{ NAME = "a" }, iup.user{ NAME = "b" }
		local tabs = iup.flattabs{ a, b, TABTITLE0 = "One", TABTITLE1 = "Two" }
		tabs.tabchangepos_cb = function(_, newpos, oldpos) seen.change = { newpos, oldpos } end
		tabs.flat_button_cb = function(_, button, pressed, x, y, status) seen.button = { button, pressed, x, y, status } end
		local cls, st = layout(tabs)
		cls.event(tabs, st, { type = "press", button = 1, x = 35, y = 8, status = iup._status({ b1 = true }) }, { redraw = function() end })
		cls.event(tabs, st, { type = "release", button = 1, x = 35, y = 8, status = iup._status() }, { redraw = function() end })
		assert.are.same({ 1, 0 }, seen.change)
		assert.are.equal(iup.BUTTON1, seen.button[1]) -- IUP's '1', which TabOrder checks
		assert.are.equal(0, seen.button[2])
		assert.are.equal(35 - st.x, seen.button[3])  -- x inside the strip
		assert.are.equal(8 - st.y, seen.button[4])
		assert.are.equal("          ", seen.button[5])
	end)

	it("handles close buttons, extra buttons and current-tab fallback", function()
		setup()
		local closed, extra = {}, {}
		local a, b, cpage = iup.user{ NAME = "a" }, iup.user{ NAME = "b" }, iup.user{ NAME = "c" }
		local tabs = iup.flattabs{ a, b, cpage, SHOWCLOSE = "YES", EXTRABUTTONS = "1", EXTRATITLE1 = "+" }
		tabs.tabclose_cb = function(_, pos) closed[#closed + 1] = pos; return iup.DEFAULT end
		tabs.extrabutton_cb = function(_, id, pressed) extra[#extra + 1] = { id, pressed } end
		local cls, st = layout(tabs)
		local rt = { redraw = function() end }
		-- The first tab's close region is at the right edge of its title cell.
		cls.event(tabs, st, { type = "press", button = 1, x = 28, y = 8 }, rt)
		cls.event(tabs, st, { type = "release", button = 1, x = 28, y = 8 }, rt)
		assert.are.same({ 0 }, closed)
		assert.are.equal("1", iup.GetAttribute(tabs, "VALUEPOS"))
		iup.SetAttribute(tabs, "VALUEPOS", "2")
		Element.detach(cpage)
		assert.are.equal("1", iup.GetAttribute(tabs, "VALUEPOS"))
		cls.event(tabs, st, { type = "press", button = 1, x = 228, y = 8 }, rt)
		cls.event(tabs, st, { type = "release", button = 1, x = 228, y = 8 }, rt)
		assert.are.same({ 1, 1 }, extra[1])
		assert.are.same({ 1, 0 }, extra[2])
	end)

	it("moves between tabs with arrows and keeps VALUEPOS round-trippable", function()
		setup()
		local a, b, cpage = iup.user{ NAME = "a" }, iup.user{ NAME = "b" }, iup.user{ NAME = "c" }
		local tabs = iup.flattabs{ a, b, cpage }
		local cls, st = layout(tabs)
		local rt = { redraw = function() end }
		cls.event(tabs, st, { type = "key", key = iup.K_RIGHT }, rt)
		assert.are.equal("1", iup.GetAttribute(tabs, "VALUEPOS"))
		iup.SetAttribute(tabs, "VALUE", "c")
		assert.are.equal("2", iup.GetAttribute(tabs, "VALUEPOS"))
		iup.SetAttribute(tabs, "TABVISIBLE2", "NO")
		layout(tabs)
		assert.are.equal("1", iup.GetAttribute(tabs, "VALUEPOS"))
	end)
end)
