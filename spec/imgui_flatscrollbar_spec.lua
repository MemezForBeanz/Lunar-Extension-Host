local iup = require("core.imgui.iup")
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")

Fonts.backend = Null.new()
Fonts.reset()

local function layout(el, w, h)
	local st = Element.state(el)
	st.x, st.y, st.w, st.h = 0, 0, w, h
	local L = {
		font = Fonts.forElement,
		charsize = function() return 5, 10 end,
		natural = function(c) return (Element.state(c).nat_w > 0 and Element.state(c).nat_w or 200), (Element.state(c).nat_h > 0 and Element.state(c).nat_h or 400) end,
		place = function(c, x, y, cw, ch)
			local s = Element.state(c); s.x, s.y, s.w, s.h = x, y, cw, ch
		end,
		size = function() return nil, nil end,
	}
	local place = Classes.get(Element.state(el).classname).place
	if place then place(el, st, L) end
	return st
end

describe("shared flat scrollbar", function()
	it("keeps IUP internal child order and hides a fitting bar", function()
		local child = iup.canvas{ RASTERSIZE = "80x40" }
		Element.state(child).nat_w, Element.state(child).nat_h = 80, 40
		local box = iup.flatscrollbox{ child }
		assert.are.equal(3, iup.GetChildCount(box))
		assert.are.equal(iup.GetChild(box, 0), Element.state(box).data.scrollbars[1])
		assert.are.equal(iup.GetChild(box, 1), Element.state(box).data.scrollbars[2])
		assert.are.equal(child, iup.GetChild(box, 2))
		layout(box, 100, 100)
		assert.are.equal("NO", iup.GetAttribute(iup.GetChild(box, 0), "VISIBLE"))
	end)

	it("calculates POSY, page clicks, dragging, wheel and callback arguments", function()
		local child = iup.canvas{ RASTERSIZE = "80x400" }
		local box = iup.flatscrollbox{ child }
		local seen = {}
		box.scroll_cb = function(_, op, x, y) seen[#seen + 1] = {op, x, y} end
		local st = layout(box, 100, 100)
		iup.SetAttribute(box, "POSY", "100")
		assert.are.equal("100", iup.GetAttribute(box, "POSY"))
		local sb = iup.GetChild(box, 0)
		local ss = Element.state(sb)
		assert.are.equal("YES", iup.GetAttribute(sb, "VISIBLE"))
		Classes.get("flatscrollbar").event(sb, ss, {type = "press", button = 1, lx = 2, ly = 0}, {capture = function() end})
		assert.is_true(tonumber(iup.GetAttribute(box, "POSY")) < 100)
		local before = tonumber(iup.GetAttribute(box, "POSY"))
		Classes.get("flatscrollbar").event(sb, ss, {type = "press", button = 1, lx = 5, ly = 25}, {capture = function() end})
		Classes.get("flatscrollbar").event(sb, ss, {type = "move", lx = 5, ly = 55}, {})
		Classes.get("flatscrollbar").event(sb, ss, {type = "release", button = 1}, {release = function() end})
		assert.is_true(tonumber(iup.GetAttribute(box, "POSY")) >= 0)
		assert.is_true(#seen > 0)
		assert.are.equal(tonumber(iup.GetAttribute(box, "POSY")), seen[#seen][3])
		Classes.get("flatscrollbox").event(box, st, {type = "wheel", dy = -1}, {})
		assert.is_true(tonumber(iup.GetAttribute(box, "POSY")) > 0)
	end)

	it("drives flatlist and flatrows through the same internal scrollbar", function()
		local list = iup.flatlist{"a", "b", "c", "d", "e", "f"}
		iup.SetAttribute(list, "FLATSCROLLBAR", "YES")
		local ls = layout(list, 100, 30)
		local dc = Draw.new(Fonts.backend); dc:begin(200, 200)
		Classes.get("flatlist").draw(list, ls, dc, {})
		assert.are.equal(2, iup.GetChildCount(list))
		assert.are.equal("YES", iup.GetAttribute(iup.GetChild(list, 0), "VISIBLE"))
		Classes.get("flatlist").event(list, ls, {type = "wheel", dy = -1}, {})
		assert.is_true(tonumber(iup.GetAttribute(list, "POSY")) > 0)

		local rows = iup.flatrows{ COUNT = "20", ROWHEIGHT = "24" }
		local rs = layout(rows, 100, 40)
		Classes.get("flatrows").draw(rows, rs, dc, {})
		assert.are.equal(2, iup.GetChildCount(rows))
		Classes.get("flatrows").event(rows, rs, {type = "wheel", dy = -1}, {})
		assert.is_true(tonumber(iup.GetAttribute(rows, "POSY")) > 0)
	end)
end)

describe("imgui flat scrollbar modes", function()
	it("shows the vertical bar of a list that asks for FLATSCROLLBAR=VERTICAL (the command palette's)", function()
		local Null = require("core.imgui.backend.Null")
		local R = require("core.imgui.Runtime")
		local B = Null.new()
		R.init(B)
		local iup = require("core.imgui.iup")
		local rows = require("core.imgui.native.iupraw").flatrows({ COUNT = "40", FLATSCROLLBAR = "VERTICAL" })
		iup.Show(iup.dialog({ iup.vbox({ rows }), RASTERSIZE = "400x300" }))
		R.frame(); R.frame()
		assert.equal("YES", iup.GetAttribute(iup.GetChild(rows, 0), "VISIBLE"))
		assert.equal("NO", iup.GetAttribute(iup.GetChild(rows, 1), "VISIBLE"))
		iup.SetAttribute(rows, "FLATSCROLLBAR", "NO")
		R.redraw(); R.frame(); R.frame()
		assert.equal("NO", iup.GetAttribute(iup.GetChild(rows, 0), "VISIBLE"))
	end)

	it("insets scrollbar children and paints the configured gradient thumb", function()
		local child = iup.canvas{ RASTERSIZE = "80x400" }
		local box = iup.flatscrollbox{ child, RASTERSIZE = "100x100", SB_INSET = "2",
			SB_GRADIENTCOLOR = "3 4 5", SB_CORNERRADIUS = "4" }
		local st = layout(box, 100, 100)
		local sb = iup.GetChild(box, 0)
		local ss = Element.state(sb)
		assert.are.equal(86, ss.x)
		assert.are.equal(2, ss.y)
		assert.are.equal(96, ss.h)
		local backend = Null.new()
		local dc = Draw.new(backend); dc:begin(120, 120)
		Classes.get("flatscrollbar").draw(sb, ss, dc, {})
		backend:frame_end()
		local thumb
		for _, cmd in ipairs(backend:lastFrame()) do
			if cmd[1] == "rect_filled" and cmd[2] >= ss.x + 2 then thumb = cmd; break end
		end
		assert.is_truthy(thumb)
	end)
end)
