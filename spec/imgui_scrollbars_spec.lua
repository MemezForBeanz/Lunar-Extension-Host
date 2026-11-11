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

describe("imgui scroll bars: IupScrollBox", function()
	-- The numbers are the IUP build's (scripts/ui_scroll.lua, box A): a 281x331 IupScrollBox
	-- with SCROLLBAR=VERTICAL holding a 232x968 column. Windows reports the bar at the box's
	-- right edge, 17x331, arrows 17, thumb 17..119; DY=331, DX=0, YMAX=968. The host had no
	-- bars at all: the class reused the flat bars, which read FLATSCROLLBAR (NO there).
	local function column(iup, n)
		local v = iup.vbox({ GAP = "4", MARGIN = "6x6" })
		for i = 1, n do iup.Append(v, iup.flatbutton({ TITLE = "row " .. i, RASTERSIZE = "220x28" })) end
		return v
	end
	local function box_a(opts)
		local iup, R, B, Element = host()
		local child = column(iup, 30)
		local box = iup.scrollbox({ child, SCROLLBAR = (opts and opts.sb) or "VERTICAL", RASTERSIZE = "281x331", EXPAND = "NO" })
		local updates = 0
		box.layoutupdate_cb = function() updates = updates + 1 end
		local d = iup.dialog({ iup.vbox({ box, MARGIN = "10x10" }), RASTERSIZE = "600x400" })
		iup.Show(d); R.frame(); R.relayout(d); R.frame()
		local W = require("core.imgui.widgets.winscrollbar")
		return { iup = iup, R = R, B = B, Element = Element, box = box, child = child, d = d, W = W,
			st = Element.state(box), updates = function() return updates end }
	end
	local function frame(t, input) if input then t.B.queue(input) end; t.R.frame() end
	local function click(t, x, y)
		frame(t, { mx = x, my = y }); frame(t, { mx = x, my = y, press = 1 }); frame(t, { mx = x, my = y, release = 1 }); frame(t)
	end

	it("lays out the range, the view and the bar as Windows reports them", function()
		local t = box_a()
		assert.equal("331", t.iup.GetAttribute(t.box, "DY"))
		assert.equal("0", t.iup.GetAttribute(t.box, "DX"))
		assert.equal("968", t.iup.GetAttribute(t.box, "YMAX"))
		local i = t.W.info(t.box, true)
		assert.same({ t.st.x + 281 - 17, t.st.y, 17, 331, 17, 17, 119 }, { i.x, i.y, i.w, i.h, i.line, i.thumb_top, i.thumb_bottom })
		assert.is_nil(t.W.info(t.box, false))
		-- the child lives in the client area: a point on the bar is the box's
		assert.equal(t.box, t.R.hitTest(t.d, i.x + 8, t.st.y + 200))
	end)

	it("scrolls a tenth of the page per wheel notch and arrow, a page per track click", function()
		local t = box_a()
		local i = t.W.info(t.box, true)
		frame(t, { mx = t.st.x + 60, my = t.st.y + 100 })
		frame(t, { mx = t.st.x + 60, my = t.st.y + 100, wheel = -1 }); frame(t)
		assert.near(33.1, tonumber(t.iup.GetAttribute(t.box, "POSY")), 1e-6)
		assert.equal(t.st.y - 33, t.Element.state(t.child).y)
		assert.equal(1, t.updates())
		assert.equal(27, t.W.info(t.box, true).thumb_top)
		click(t, i.x + 8, i.y + i.h - 8) -- the bottom arrow
		assert.near(66.2, tonumber(t.iup.GetAttribute(t.box, "POSY")), 1e-6)
		click(t, i.x + 8, i.y + i.h - 30) -- the track below the thumb
		assert.near(397.2, tonumber(t.iup.GetAttribute(t.box, "POSY")), 1e-6)
		local j = t.W.info(t.box, true)
		assert.equal(139, j.thumb_top)
	end)

	it("SCROLLTO moves the child; POSY moves only the thumb", function()
		local t = box_a()
		t.iup.SetAttribute(t.box, "SCROLLTO", "BOTTOM"); t.R.frame()
		assert.equal("637.000000000000000000", t.iup.GetAttribute(t.box, "POSY"))
		assert.equal(t.st.y - 637, t.Element.state(t.child).y)
		t.iup.SetAttribute(t.box, "POSY", "37"); t.R.frame()
		assert.equal("37.000000000000000000", t.iup.GetAttribute(t.box, "POSY"))
		assert.equal(t.st.y - 637, t.Element.state(t.child).y) -- winCanvasSetPosYAttrib
		assert.equal(17 + 11, t.W.info(t.box, true).thumb_top) -- MulDiv(37, 195, 637)
	end)

	it("drags the content with button 1 on the box itself", function()
		local t = box_a()
		local x, y = t.st.x + 3, t.st.y + 150
		frame(t, { mx = x, my = y }); frame(t, { mx = x, my = y, press = 1 })
		frame(t, { mx = x, my = y - 50 }); frame(t, { mx = x, my = y - 50, release = 1 }); frame(t)
		assert.equal("50.000000000000000000", t.iup.GetAttribute(t.box, "POSY"))
	end)

	it("drags the thumb: SB_THUMBTRACK then SB_THUMBPOSITION", function()
		local t = box_a()
		local ops = {}
		local i = t.W.info(t.box, true)
		frame(t, { mx = i.x + 8, my = i.y + 25 }); frame(t, { mx = i.x + 8, my = i.y + 25, press = 1 })
		frame(t, { mx = i.x + 8, my = i.y + 65 })
		assert.near(40 * (968 - 331) / (297 - 102), tonumber(t.iup.GetAttribute(t.box, "POSY")), 1e-6)
		t.box.scroll_cb = function(_, op) ops[#ops + 1] = op end
		frame(t, { mx = i.x + 8, my = i.y + 65, release = 1 }); frame(t)
		assert.same({ 4 }, ops) -- IUP_SBPOSV
	end)

	it("with both bars leaves the corner to neither and the view to the rest", function()
		local iup, R, B, Element = host()
		local wide = iup.vbox({ iup.flatbutton({ RASTERSIZE = "500x40" }), column(iup, 20), MARGIN = "6x6" })
		local box = iup.scrollbox({ wide, RASTERSIZE = "281x331", EXPAND = "NO" })
		local d = iup.dialog({ iup.vbox({ box }), RASTERSIZE = "600x400" })
		iup.Show(d); R.frame(); R.relayout(d); R.frame()
		local W = require("core.imgui.widgets.winscrollbar")
		assert.equal("264", iup.GetAttribute(box, "DX"))
		assert.equal("314", iup.GetAttribute(box, "DY"))
		local v, h = W.info(box, true), W.info(box, false)
		assert.same({ 17, 314, 17, 143 }, { v.w, v.h, v.thumb_top, v.thumb_bottom })
		assert.same({ 264, 17, 17, 136 }, { h.w, h.h, h.thumb_top, h.thumb_bottom })
	end)

	it("keeps an 8 px thumb for a huge range", function()
		local iup, R, B, Element = host()
		local box = iup.scrollbox({ iup.vbox({ iup.flatbutton({ RASTERSIZE = "100x30000" }) }), SCROLLBAR = "VERTICAL", RASTERSIZE = "130x120", EXPAND = "NO" })
		local d = iup.dialog({ iup.vbox({ box }), RASTERSIZE = "600x400" })
		iup.Show(d); R.frame(); R.relayout(d); R.frame()
		local v = require("core.imgui.widgets.winscrollbar").info(box, true)
		assert.same({ 17, 25 }, { v.thumb_top, v.thumb_bottom })
	end)

	it("hides the bar when the view holds the child, and the wheel goes to the parent", function()
		local iup, R, B, Element = host()
		local inner = iup.scrollbox({ column(iup, 2), SCROLLBAR = "HORIZONTAL", RASTERSIZE = "260x200", EXPAND = "NO" })
		local outer = iup.scrollbox({ iup.vbox({ inner, iup.flatbutton({ RASTERSIZE = "100x900" }) }), SCROLLBAR = "VERTICAL", RASTERSIZE = "300x300", EXPAND = "NO" })
		local d = iup.dialog({ iup.vbox({ outer }), RASTERSIZE = "600x400" })
		iup.Show(d); R.frame(); R.relayout(d); R.frame()
		local W = require("core.imgui.widgets.winscrollbar")
		assert.is_nil(W.info(inner, true)); assert.is_nil(W.info(inner, false))
		local st = Element.state(inner)
		B.queue({ mx = st.x + 2, my = st.y + 2 }); R.frame()
		B.queue({ mx = st.x + 2, my = st.y + 2, wheel = -1 }); R.frame()
		assert.near(30, tonumber(iup.GetAttribute(outer, "POSY")), 1e-6)
	end)
end)

describe("imgui scroll bars: first show", function()
	-- iupDialogShowXY then the window's first WM_SIZE (winDialogResize -> IupRefresh): the first
	-- layout is computed twice, so a scroll box ends at its own size, not its child's. On the
	-- IUP build a 260x300 IupScrollBox holding a 968 px column is 331 px tall at the first
	-- frame; the host kept it at 968 until something else asked for a layout.
	it("lays a new dialog out twice", function()
		local iup, R, B, Element = host()
		local col = iup.vbox({ iup.flatbutton({ RASTERSIZE = "220x968" }) })
		local box = iup.scrollbox({ col, SCROLLBAR = "VERTICAL", RASTERSIZE = "260x300" })
		local d = iup.dialog({ iup.vbox({ box }), RASTERSIZE = "600x400", MARGIN = "0x0" })
		iup.Show(d); R.frame()
		assert.equal(400, Element.state(box).h)
		assert.equal("400", iup.GetAttribute(box, "DY"))
	end)
end)

describe("imgui scroll bars: Windows 11 look", function()
	-- Captured on the IUP build: the bar is #F0F0F0 with a white line on the content side; the
	-- thumb is a 2 px #858585 line on columns 8-9 with #989898 ends; an 8 px thumb is painted
	-- 17 px long.
	it("paints the rest state and the minimum painted thumb", function()
		local iup, R, B, Element = host()
		local box = iup.scrollbox({ iup.vbox({ iup.flatbutton({ RASTERSIZE = "100x30000" }) }), SCROLLBAR = "VERTICAL", RASTERSIZE = "130x120", EXPAND = "NO" })
		local d = iup.dialog({ iup.vbox({ box }), RASTERSIZE = "600x400", MARGIN = "0x0" })
		iup.Show(d); R.frame(); R.frame()
		local st = Element.state(box)
		local bx = st.x + st.w - 17
		local fills = {}
		for _, c in ipairs(B.calls) do
			if c[1] == "rect_filled" and c[2] >= bx and c[4] <= bx + 17 then fills[#fills + 1] = c end
		end
		local function has(x1, y1, x2, y2)
			for _, c in ipairs(fills) do if c[2] == x1 and c[3] == y1 and c[4] == x2 and c[5] == y2 then return true end end
			return false
		end
		assert.is_true(has(bx, st.y, bx + 17, st.y + 120))         -- the track
		assert.is_true(has(bx, st.y, bx + 1, st.y + 120))          -- the white edge
		assert.is_true(has(bx + 8, st.y + 17, bx + 10, st.y + 18)) -- the thumb's top end
		assert.is_true(has(bx + 8, st.y + 33, bx + 10, st.y + 34)) -- its bottom end, 17 px on
	end)
end)

describe("imgui scroll bars: the wheel over a canvas", function()
	-- winCanvasMsgProc WM_MOUSEWHEEL: a canvas with no WHEEL_CB and no vertical bar breaks to
	-- DefWindowProc, which forwards the wheel to the parent window. The host's canvas kept it.
	it("reaches the scroll box around a canvas without WHEEL_CB", function()
		local iup, R, B, Element = host()
		local cv = iup.canvas({ RASTERSIZE = "200x900", EXPAND = "NO" })
		local box = iup.scrollbox({ iup.vbox({ cv }), SCROLLBAR = "VERTICAL" })
		local d = iup.dialog({ box, RASTERSIZE = "300x300", MARGIN = "0x0" })
		iup.Show(d); R.frame()
		local st = Element.state(cv)
		local mx, my = st.x + 5, st.y + 50
		B.queue({ mx = mx, my = my }); R.frame()
		B.queue({ mx = mx, my = my, wheel = -1 }); R.frame()
		assert.near(30, tonumber(iup.GetAttribute(box, "POSY")), 1e-6)
		local got
		cv.wheel_cb = function(_, delta) got = delta end
		B.queue({ mx = mx, my = my, wheel = -1 }); R.frame()
		assert.equal(-1, got)
		assert.near(30, tonumber(iup.GetAttribute(box, "POSY")), 1e-6)
	end)
end)
