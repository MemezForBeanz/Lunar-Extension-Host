-- Rules of IUP's C sources that measured differences between the IUP build and the
-- ImGui host traced back to. Each case names the C function it follows.
local Null = require("core.imgui.backend.Null")

local function host(opts)
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new(opts)
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

describe("imgui parity: flattoggle natural size", function()
	-- iFlatToggleComputeNaturalSizeMethod: iupFlatDrawGetIconSize (text + padding, +4 for
	-- the focus feedback of a focusable control), then CHECKSIZE + CHECKSPACING (5 by
	-- default) across, at least CHECKSIZE down, then the border on both sides. Measured on
	-- the IUP build: "Weekdays only" with CHECKSIZE=16 is 114x23 where the host made 105x17.
	it("adds the focus room, the check spacing default and the border", function()
		local iup, R = host()
		local Fonts = require("core.imgui.Fonts")
		local t = iup.flattoggle({ TITLE = "Weekdays only", CHECKSIZE = "16" })
		local d = iup.dialog({ iup.vbox({ t }), RASTERSIZE = "300x100" })
		iup.Show(d)
		R.frame()
		local tw, th = Fonts.forElement(t):measure("Weekdays only")
		assert.equal(string.format("%dx%d", tw + 4 + 16 + 5 + 2, math.max(th + 4, 16) + 2),
			iup.GetAttribute(t, "RASTERSIZE"))
	end)

	it("defaults CHECKSIZE to 16 and drops the check with CHECKSIZE=0", function()
		local iup, R = host()
		local Fonts = require("core.imgui.Fonts")
		local a = iup.flattoggle({ TITLE = "On" })
		local b = iup.flattoggle({ TITLE = "On", CHECKSIZE = "0", CANFOCUS = "NO" })
		local d = iup.dialog({ iup.vbox({ a, b }), RASTERSIZE = "300x100" })
		iup.Show(d)
		R.frame()
		local tw, th = Fonts.forElement(a):measure("On")
		assert.equal(string.format("%dx%d", tw + 4 + 16 + 5 + 2, math.max(th + 4, 16) + 2), iup.GetAttribute(a, "RASTERSIZE"))
		assert.equal(string.format("%dx%d", tw + 2, th + 2), iup.GetAttribute(b, "RASTERSIZE"))
	end)
end)

describe("imgui parity: split", function()
	-- iSplitGetWidth1: iupRoundUp(total * VALUE / 1000.0). Measured with the panes split
	-- at VALUE=350 over a 1336 px grid (BARSIZE 7): IUP's left pane is 466, the host's
	-- was 465 (it rounded), and the iLO toolbar inside it lost 3 px to patch 0008's shrink.
	it("gives the first child ceil(total * VALUE / 1000)", function()
		local iup, R = host()
		local function expanding() return iup.hbox({ iup.vbox({ iup.fill({}) }), iup.fill({}) }) end
		local a, b = expanding(), expanding()
		local split = iup.split({ a, b, VALUE = "350", BARSIZE = "7" })
		local d = iup.dialog({ split, RASTERSIZE = "1336x200", MARGIN = "0x0" })
		iup.Show(d)
		R.frame()
		local Element = require("core.imgui.Element")
		assert.equal(466, Element.state(a).w)  -- ceil(1329 * 0.35) = ceil(465.15)
		assert.equal(1336 - 7 - 466, Element.state(b).w)
		assert.equal(466 + 7, Element.state(b).x)
	end)

	-- iSplitSetChildrenCurrentSizeMethod sizes each child with iupBaseSetCurrentSize: a child
	-- that does not expand keeps its natural size; the host used to stretch it to the pane.
	it("keeps a child that does not expand at its natural size", function()
		local iup, R = host()
		local a = iup.label({ TITLE = "left" })
		local split = iup.split({ a, iup.hbox({ iup.vbox({ iup.fill({}) }), iup.fill({}) }), VALUE = "500" })
		local d = iup.dialog({ split, RASTERSIZE = "400x100" })
		iup.Show(d)
		R.frame()
		local nw, nh = require("core.imgui.Layout").natural(a)
		assert.equal(nw .. "x" .. nh, iup.GetAttribute(a, "RASTERSIZE"))
	end)
end)

describe("imgui parity: inheritable attributes reach the class setters below", function()
	-- iAttribNotifyChildren: IupSetAttribute(page, "VISIBLE", "YES"), as IupFlatTabs does
	-- when it shows a tab, calls the VISIBLE setter of every descendant without its own
	-- value. The fork's iSplitSetVisibleAttrib then clears the bar's own VISIBLE, so a sash
	-- an application hid comes back with its tab. Measured: Build Queue's output sash (hidden
	-- by Adaptive.setSecondPane while the output pane is closed) shows on the IUP build at
	-- 64,837 1304x7 and stayed hidden on the host.
	it("lets a page's VISIBLE reach the split's setter, which clears the bar's own VISIBLE", function()
		local iup, R, B, Element = host()
		local split = iup.split({ iup.label({ TITLE = "a" }), iup.label({ TITLE = "b" }) })
		local page = iup.vbox({ split })
		local d = iup.dialog({ page, RASTERSIZE = "300x200" })
		iup.Show(d)
		local bar = iup.GetChild(split, 0)
		iup.SetAttribute(bar, "VISIBLE", "NO")
		assert.is_false(R.isVisible(bar))
		iup.SetAttribute(page, "VISIBLE", "YES")
		assert.is_nil(Element.own(bar, "VISIBLE"))
		assert.is_true(R.isVisible(bar))
	end)

	it("stops at a descendant that has its own value", function()
		local iup, R, B, Element = host()
		local split = iup.split({ iup.label({ TITLE = "a" }), iup.label({ TITLE = "b" }) })
		local inner = iup.vbox({ split, VISIBLE = "NO" })
		local page = iup.vbox({ inner })
		local d = iup.dialog({ page, RASTERSIZE = "300x200" })
		iup.Show(d)
		local bar = iup.GetChild(split, 0)
		iup.SetAttribute(bar, "VISIBLE", "NO")
		iup.SetAttribute(page, "VISIBLE", "YES")
		assert.equal("NO", Element.own(bar, "VISIBLE"))
	end)
end)

describe("imgui parity: flat scroll bars", function()
	-- iupFlatScrollBarCreate: the two bars are IupCanvas children (IUP_INTERNAL). The probe
	-- listed them as canvas on the IUP build and as flatscrollbar on the host.
	it("reports its internal bars as canvas", function()
		local iup = host()
		local box = iup.flatscrollbox({ iup.vbox({ iup.label({ TITLE = "x" }) }) })
		assert.equal("canvas", iup.GetClassName(iup.GetChild(box, 0)))
		assert.equal("canvas", iup.GetClassName(iup.GetChild(box, 1)))
	end)
end)

describe("imgui parity: box user size", function()
	-- iHboxSetRasterSizeAttrib: "second value will be ignored, can NOT set height". The
	-- terminal's header is iup.hbox{ ..., RASTERSIZE = "x32" } around 28 px buttons: 28 px
	-- tall on the IUP build, 32 on the host, and the code view below sat 4 px lower.
	local function box_in_dialog(iup, R, box)
		local d = iup.dialog({ iup.vbox({ box, iup.fill({}) }), RASTERSIZE = "400x300" })
		iup.Show(d)
		R.frame()
		return box
	end

	it("ignores an hbox's height", function()
		local iup, R = host()
		local b = iup.flatbutton({ TITLE = "", RASTERSIZE = "28x28" })
		local box = box_in_dialog(iup, R, iup.hbox({ b, RASTERSIZE = "x32", ALIGNMENT = "ACENTER" }))
		local w, h = iup.GetAttribute(box, "RASTERSIZE"):match("(%d+)x(%d+)")
		assert.equal("28", h)
		local Element = require("core.imgui.Element")
		assert.equal(Element.state(box).y, Element.state(b).y) -- centred in 28, not in 32
	end)

	it("keeps an hbox's width and drops its height from RASTERSIZE", function()
		local iup, R = host()
		local box = box_in_dialog(iup, R, iup.hbox({ iup.label({ TITLE = "x" }), RASTERSIZE = "120x80" }))
		local w, h = iup.GetAttribute(box, "RASTERSIZE"):match("(%d+)x(%d+)")
		assert.equal("120", w)
		assert.is_true(tonumber(h) < 80)
	end)

	it("takes a vbox's single number as its height (iVboxSetRasterSizeAttrib)", function()
		local iup, R = host()
		local box = box_in_dialog(iup, R, iup.vbox({ iup.label({ TITLE = "x" }), RASTERSIZE = "90" }))
		local w, h = iup.GetAttribute(box, "RASTERSIZE"):match("(%d+)x(%d+)")
		assert.equal("90", h)
		assert.is_true(tonumber(w) < 90)
	end)

	it("leaves the user size alone when the box's own axis is missing", function()
		local iup, R = host()
		local box = iup.hbox({ iup.label({ TITLE = "x" }), RASTERSIZE = "150x" })
		iup.SetAttribute(box, "RASTERSIZE", "x40")
		box_in_dialog(iup, R, box)
		local w = iup.GetAttribute(box, "RASTERSIZE"):match("(%d+)x")
		assert.equal("150", w)
	end)
end)

describe("imgui parity: flattabs pages", function()
	-- iFlatTabsSetChildrenCurrentSizeMethod sets each page's current size to the client area
	-- directly, without iupBaseSetCurrentSize's MAXSIZE crop. Lunar caps every page's
	-- natural height with MAXSIZE (host/Layout.lua); maximised at 1920x1080 the Build Queue
	-- group's strip has MAXSIZE 65535x950 and fills its 988 px page on the IUP build, where
	-- the host cropped it to 950.
	it("gives a page the whole client area whatever its MAXSIZE", function()
		local iup, R, B, Element = host()
		local page = iup.vbox({ iup.fill({}), MAXSIZE = "65535x50" })
		local tabs = iup.flattabs({ page, SHOWTABS = "NO", SHOWLINES = "NO" })
		local d = iup.dialog({ tabs, RASTERSIZE = "300x200" })
		iup.Show(d)
		R.frame()
		assert.equal(Element.state(tabs).h, Element.state(page).h)
		assert.is_true(Element.state(page).h > 50)
	end)
end)

describe("imgui parity: flat scroll box", function()
	-- iFlatScrollBoxSetChildrenCurrentSizeMethod: a child taller than the box keeps its
	-- natural height and loses the vertical bar's width (SCROLLBARSIZE) from the width it
	-- expands to. The Settings panel at 700x500 was 588 px wide on the IUP build and 603 on
	-- the host.
	local function settings_like(iup, R, w, h, child)
		local box = iup.flatscrollbox({ child })
		local d = iup.dialog({ box, RASTERSIZE = w .. "x" .. h })
		iup.Show(d)
		R.frame()
		-- the first layout starts the box at the child's natural size (currentwidth == 0 in
		-- iFlatScrollBoxComputeNaturalSizeMethod); from the second on it is free of the child
		R.relayout(d)
		R.frame()
		return box
	end

	it("takes the vertical bar's width from an expanding child", function()
		local iup, R, B, Element = host()
		local child = iup.vbox({ iup.label({ TITLE = "x", RASTERSIZE = "50x400", EXPAND = "HORIZONTAL" }) })
		local box = settings_like(iup, R, 300, 200, child)
		assert.equal(Element.state(box).w - 15, Element.state(child).w)
		assert.equal("400", iup.GetAttribute(box, "YMAX"))
	end)

	-- FLATSCROLLBAR (default YES) decides both bars; SCROLLBAR is read-only NO there. With
	-- the panes split narrow, IUP shows Settings' horizontal bar (49,837 465x15); the host
	-- read SCROLLBAR, defaulted it to VERTICAL and never showed it.
	it("shows the horizontal bar when the child is wider than the box", function()
		local iup, R, B, Element = host()
		local child = iup.vbox({ iup.label({ TITLE = "x", RASTERSIZE = "500x50" }) })
		local box = settings_like(iup, R, 300, 200, child)
		assert.equal("500", iup.GetAttribute(box, "XMAX"))
		assert.is_true(R.isVisible(iup.GetChild(box, 1)))
	end)
end)

describe("imgui parity: zbox", function()
	-- iZboxComputeNaturalSizeMethod with CHILDSIZEALL, registered "Yes": the zbox is as large
	-- as its largest child, hidden or not. At 700x500 Build Queue's work zbox measured
	-- 373x368 on the IUP build and 315x149 on the host, which only measured the current
	-- child, and the split under it gave the page 42 px less.
	it("measures every child by default", function()
		local iup, R, B, Element = host()
		local small = iup.label({ TITLE = "", RASTERSIZE = "20x10" })
		local big = iup.label({ TITLE = "", RASTERSIZE = "80x60" })
		local z = iup.zbox({ small, big })
		local Layout = require("core.imgui.Layout")
		local w, h = Layout.natural(z)
		assert.same({ 80, 60 }, { w, h })
		iup.SetAttribute(z, "CHILDSIZEALL", "NO")
		w, h = Layout.natural(z)
		assert.same({ 20, 10 }, { w, h })
	end)
end)

describe("imgui parity: IupShow", function()
	-- iDialogAfterShow (iup_dialog.c) calls IupFlush before SHOW_CB, so a timer that is
	-- due when the dialog is shown runs inside IupShow. Lunar's theme manager queues its
	-- startup re-theme on such a timer; run later, the theme pass met a different tree.
	it("runs a due timer before SHOW_CB (iDialogAfterShow: IupFlush)", function()
		local iup, R, B = host()
		local order = {}
		local t = iup.timer({ time = 16 })
		function t:action_cb() order[#order + 1] = "timer"; self.run = "NO"; return iup.DEFAULT end
		t.run = "YES"
		B.advance(0.05)
		local d = iup.dialog({ iup.vbox({ iup.label({ TITLE = "x" }) }), RASTERSIZE = "200x100" })
		function d:show_cb(state) order[#order + 1] = "show" .. state; return iup.DEFAULT end
		iup.Show(d)
		assert.same({ "timer", "show0" }, order)
	end)

	it("does not flush with NOFLUSH=YES", function()
		local iup, R, B = host()
		local order = {}
		local t = iup.timer({ time = 16 })
		function t:action_cb() order[#order + 1] = "timer"; self.run = "NO"; return iup.DEFAULT end
		t.run = "YES"
		B.advance(0.05)
		local d = iup.dialog({ iup.vbox({ iup.label({ TITLE = "x" }) }), RASTERSIZE = "200x100", NOFLUSH = "YES" })
		function d:show_cb(state) order[#order + 1] = "show" .. state; return iup.DEFAULT end
		iup.Show(d)
		assert.same({ "show0" }, order)
	end)

	it("gives the start focus only when SHOW_CB did not move the focus", function()
		local iup, R = host()
		local a = iup.flatbutton({ TITLE = "a" })
		local b = iup.flatbutton({ TITLE = "b" })
		local d = iup.dialog({ iup.vbox({ a, b }), RASTERSIZE = "200x100" })
		function d:show_cb() iup.SetFocus(b); return iup.DEFAULT end
		iup.Show(d)
		assert.equal(b, iup.GetFocus())
	end)
end)
