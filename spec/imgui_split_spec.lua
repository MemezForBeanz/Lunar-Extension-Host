local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local Layout = require("core.imgui.Layout")
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local B = Null.new()
Fonts.backend = B
Fonts.reset()
Element.globals.DEFAULTFONT = "Segoe UI, 10"
Element.globals.DLGBGCOLOR = "240 240 240"
Element.globals.DLGFGCOLOR = "0 0 0"

local function state(e) return Element.state(e) end
-- A pane that expands both ways from a natural size of 0x0. An IupFill does not do: it
-- expands only along an hbox or vbox, and iSplitSetChildrenCurrentSizeMethod gives each
-- child its size through iupBaseSetCurrentSize, so a child that does not expand keeps its
-- natural size.
local function pane(attrs)
	local p = iup.hbox{ iup.vbox{ iup.fill{} }, iup.fill{} }
	for k, v in pairs(attrs or {}) do iup.SetAttribute(p, k, v) end
	return p
end
local function layout(split, w, h)
	Layout.natural(split)
	local s = state(split)
	s.x, s.y, s.w, s.h = 0, 0, w, h
	Classes.get("split").place(split, s, Layout.L)
	return state(iup.GetChild(split, 1)), state(iup.GetChild(split, 2)), state(iup.GetChild(split, 0))
end

describe("imgui split", function()
	it("keeps its internal sash as the first child", function()
		local a, b = iup.fill{}, iup.fill{}
		local split = iup.split{a, b}
		assert.are.equal(3, iup.GetChildCount(split))
		assert.are.equal(split, iup.GetParent(iup.GetChild(split, 0)))
		assert.are.equal(a, iup.GetChild(split, 1))
		assert.are.equal(b, iup.GetChild(split, 2))
		assert.are.equal(0, iup.GetChildPos(split, iup.GetChild(split, 0)))
	end)

	it("places the sash and panes at VALUE 0, 500, and 1000", function()
		local split = iup.split{pane(), pane(), VALUE = "0", BARSIZE = "4"}
		local a, b, bar = layout(split, 104, 20)
		assert.are.equal(0, a.w); assert.are.equal(100, b.w); assert.are.equal(4, bar.w)
		for _, value in ipairs({"500", "1000"}) do
			iup.SetAttribute(split, "VALUE", value)
			a, b, bar = layout(split, 104, 20)
			local first = value == "500" and 50 or 100
			assert.are.equal(first, a.w)
			assert.are.equal(104 - 4 - first, b.w)
			assert.are.equal(first, bar.x)
		end
	end)

	it("computes VALUE -1 from the first pane's natural size", function()
		-- iSplitCreateMethod starts VALUE at -1; VALUE="-1" from the application would be
		-- clamped to MINMAX by iSplitAdjustVal, only NULL resets it
		local split = iup.split{iup.fill{RASTERSIZE = "20x10"}, iup.fill{RASTERSIZE = "30x10"}, BARSIZE = "5"}
		local a, b, bar = layout(split, 200, 20)
		assert.are.equal("400", iup.GetAttribute(split, "VALUE"))
		-- the fills do not expand here: they keep their natural sizes, the bar sits at
		-- ceil(195 * 400 / 1000)
		assert.are.equal(20, a.w)
		assert.are.equal(30, b.w)
		assert.are.equal(78, bar.x)
		assert.are.equal(83, b.x)
	end)

	it("clamps VALUE to MINMAX", function()
		local split = iup.split{pane(), pane(), VALUE = "900", MINMAX = "250:750", BARSIZE = "4"}
		local a, b = layout(split, 104, 20)
		assert.are.equal("750", iup.GetAttribute(split, "VALUE"))
		assert.are.equal(75, a.w)
		assert.are.equal(25, b.w)
	end)

	it("uses BARSIZE and supports horizontal orientation", function()
		local split = iup.split{pane(), pane(), VALUE = "250", BARSIZE = "6", ORIENTATION = "HORIZONTAL"}
		local a, b, bar = layout(split, 40, 106)
		assert.are.equal("HORIZONTAL", iup.GetAttribute(split, "ORIENTATION"))
		assert.are.equal(25, a.h)
		assert.are.equal(75, b.h)
		assert.are.equal(6, bar.h)
		assert.are.equal(25, bar.y)
	end)

	it("keeps a VISIBLE=NO pane in the split layout like IUP", function()
		local second = pane({ VISIBLE = "NO" })
		local split = iup.split{pane(), second, VALUE = "500", BARSIZE = "4"}
		local a, b = layout(split, 104, 20)
		assert.are.equal("NO", iup.GetAttribute(second, "VISIBLE"))
		assert.are.equal(50, a.w)
		assert.are.equal(50, b.w)
	end)

	it("fires VALUECHANGED_CB while dragging the sash", function()
		local split = iup.split{pane(), pane(), VALUE = "500", BARSIZE = "4"}
		local _, _, bar = layout(split, 104, 20)
		local changed, captured, released = 0, false, false
		split.valuechanged_cb = function() changed = changed + 1 end
		local rt = {
			capture = function() captured = true end,
			release = function() released = true end,
			relayout = function() end,
		}
		local c = Classes.get("flatseparator")
		local bst = state(iup.GetChild(split, 0))
		c.event(iup.GetChild(split, 0), bst, {type = "press", button = 1, x = bar.x + 1, y = 1, lx = 1, ly = 1}, rt)
		c.event(iup.GetChild(split, 0), bst, {type = "move", x = bar.x + 11, y = 1, lx = 11, ly = 1}, rt)
		c.event(iup.GetChild(split, 0), bst, {type = "release", button = 1, x = bar.x + 11, y = 1, lx = 11, ly = 1}, rt)
		assert.is_true(captured)
		assert.is_true(released)
		assert.is_true(changed > 0)
		assert.are.equal("600", iup.GetAttribute(split, "VALUE"))
	end)

	it("reports natural size including the sash", function()
		local split = iup.split{iup.fill{RASTERSIZE = "20x8"}, iup.fill{RASTERSIZE = "30x12"}, BARSIZE = "5"}
		local w, h = Layout.natural(split)
		assert.are.equal(55, w)
		assert.are.equal(12, h)
	end)
end)
