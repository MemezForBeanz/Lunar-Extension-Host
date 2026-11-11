-- Scroll bars on the ImGui host: IupFlatScrollBox's flat bars and the native bars of
-- IupScrollBox, multiline IupText and IupList (iupwin_canvas.c, the Windows scroll bar).
local Null = require("core.imgui.backend.Null")

local function host(opts)
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new(opts)
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

describe("imgui scroll bars: flat scroll box", function()
	-- iupFlatScrollBarCreate makes each bar a canvas with ZORDER=TOP: it sits above the
	-- scrolled child. Commit fefe0ca folded `visibleChildren` into a comment, so the bars
	-- (inserted first) were painted under the content and every click on them hit the child.
	it("paints and hits the bars above the content", function()
		local iup, R, B, Element = host()
		local child = iup.vbox({ iup.canvas({ RASTERSIZE = "100x600", BGCOLOR = "10 20 30", EXPAND = "HORIZONTAL" }) })
		local box = iup.flatscrollbox({ child })
		local d = iup.dialog({ box, RASTERSIZE = "300x200" })
		iup.Show(d); R.frame(); R.relayout(d); R.frame()
		local vbar
		for _, c in ipairs(Element.state(box).children) do
			if Element.state(c).internal and Element.state(c).data.vertical then vbar = c end
		end
		assert.is_true(R.isVisible(vbar))
		local vs = Element.state(vbar)
		assert.equal(vbar, R.hitTest(d, vs.x + 5, vs.y + 40))
		local shown = R.childrenShown(box, Element.state(box))
		assert.equal(child, shown[1])
		assert.equal(vbar, shown[#shown] == vbar and vbar or shown[#shown - 1])
	end)
end)
