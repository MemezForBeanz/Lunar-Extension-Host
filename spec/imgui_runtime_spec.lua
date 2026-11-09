-- The ImGui host's element model, iup API and frame loop, driven through the Null backend.

local Null = require("core.imgui.backend.Null")

local function host(opts)
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new(opts)
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

describe("imgui element attributes", function()
	local iup, _, _, Element
	before_each(function() iup, _, _, Element = host() end)

	it("stores attributes from the constructor, fields and SetAttribute alike", function()
		local b = iup.flatbutton({ TITLE = "a" })
		assert.equal("a", iup.GetAttribute(b, "TITLE"))
		b.title = "b"
		assert.equal("b", b.TITLE)
		iup.SetAttribute(b, "TITLE", "c")
		assert.equal("c", b.title)
	end)

	it("turns numbers and booleans into IUP strings", function()
		local b = iup.flatbutton({})
		iup.SetAttribute(b, "SPACING", 6)
		assert.equal("6", iup.GetAttribute(b, "SPACING"))
		iup.SetAttribute(b, "X1", 1.5)
		assert.equal("1.5", iup.GetAttribute(b, "X1"))
	end)

	it("inherits colours and unregistered names but not TITLE, GAP or MARGIN", function()
		local inner = iup.flatlabel({})
		local box = iup.vbox({ inner, BGCOLOR = "1 2 3", THEMEROLE = "x", GAP = "4", MARGIN = "2x2", TITLE = "t" })
		assert.equal("1 2 3", iup.GetAttribute(inner, "BGCOLOR"))
		assert.equal("x", iup.GetAttribute(inner, "THEMEROLE"))
		assert.is_nil(iup.GetAttribute(inner, "TITLE"))
		assert.is_nil(Element.own(inner, "GAP"))
		assert.is_nil(iup.GetAttribute(inner, "MARGIN"))
		assert.equal(box, iup.GetParent(inner))
	end)

	it("keeps _IUP names local and readable", function()
		local inner = iup.flatlabel({})
		local box = iup.vbox({ inner })
		iup.SetAttribute(box, "_IUPLUNAR_TABKEY", "k1")
		assert.equal("k1", iup.GetAttribute(box, "_IUPLUNAR_TABKEY"))
		assert.is_nil(iup.GetAttribute(inner, "_IUPLUNAR_TABKEY"))
		assert.equal("k1", require("core.lib.attr").get(iup, box, "_IUPLUNAR_TABKEY"))
	end)

	it("falls back to the driver defaults", function()
		Element.globals.DLGBGCOLOR = "9 9 9"
		local l = iup.flatlabel({})
		assert.equal("9 9 9", iup.GetAttribute(l, "BGCOLOR"))
		assert.equal("YES", iup.GetAttribute(l, "ACTIVE"))
	end)

	it("binds lower-case functions as callbacks, iuplua style", function()
		local b = iup.flatbutton({ flat_action = function() return 7 end })
		assert.equal(7, Element.call(b, "FLAT_ACTION"))
		local got
		function b:button_cb(btn, pressed) got = { self, btn, pressed } end
		Element.call(b, "BUTTON_CB", 49, 1)
		assert.same({ b, 49, 1 }, got)
		assert.is_function(b.button_cb)
	end)

	it("keeps plain Lua values on the handle", function()
		local b = iup.flatbutton({})
		b.payload = { 1, 2 }
		assert.same({ 1, 2 }, b.payload)
	end)

	it("resolves handle attributes and SetHandle names", function()
		local img = iup.imagergba({ width = 1, height = 1, pixels = { 1, 2, 3, 4 } })
		local b = iup.flatbutton({})
		iup.SetAttribute(b, "IMAGE", img)
		assert.equal(img, iup.GetAttributeHandle(b, "IMAGE"))
		iup.SetHandle("PIC", img)
		local c = iup.flatbutton({ IMAGE = "PIC" })
		assert.equal(img, iup.GetAttributeHandle(c, "IMAGE"))
		assert.equal("PIC", iup.GetName(img))
		assert.equal("\1\2\3\4", Element.state(img).data.pixels)
	end)

	it("uses array strings as list items", function()
		local l = iup.flatlist({ "a", "b" })
		assert.equal("a", iup.GetAttribute(l, "1"))
		assert.equal("b", iup.GetAttributeId(l, "", 2))
	end)

	it("applies an NTHEME user's attributes and its class sub-theme", function()
		local sub = iup.user({ FGCOLOR = "5 5 5" })
		iup.SetHandle("SUBTHEME", sub)
		local theme = iup.user({ BGCOLOR = "1 1 1", IUPFLATBUTTON = "SUBTHEME" })
		iup.SetHandle("THEME1", theme)
		local b = iup.flatbutton({})
		iup.SetAttribute(b, "NTHEME", "THEME1")
		assert.equal("1 1 1", iup.GetAttribute(b, "BGCOLOR"))
		assert.equal("5 5 5", iup.GetAttribute(b, "FGCOLOR"))
	end)
end)

describe("imgui tree operations", function()
	local iup
	before_each(function() iup = host() end)

	it("appends, inserts, detaches and reparents like IUP", function()
		local a, b, c = iup.flatlabel({}), iup.flatlabel({}), iup.flatlabel({})
		local box = iup.hbox({ a })
		iup.Append(box, c)
		iup.Insert(box, c, b)
		assert.equal(b, iup.GetChild(box, 1))
		assert.equal(2, iup.GetChildPos(box, c))
		assert.equal(3, iup.GetChildCount(box))
		assert.equal(c, iup.GetNextChild(box, b))
		iup.Detach(b)
		assert.equal(2, iup.GetChildCount(box))
		local other = iup.vbox({})
		iup.Reparent(a, other)
		assert.equal(other, iup.GetParent(a))
		assert.equal(1, iup.GetChildCount(box))
	end)

	it("finds the dialog and named children", function()
		local field = iup.text({ NAME = "field" })
		local dlg = iup.dialog({ iup.vbox({ iup.hbox({ field }) }) })
		assert.equal(dlg, iup.GetDialog(field))
		assert.equal(field, iup.GetDialogChild(field, "field"))
		assert.equal("dialog", iup.GetClassName(dlg))
	end)

	it("destroys children first and fires DESTROY_CB", function()
		local order = {}
		local child = iup.flatlabel({ destroy_cb = function() order[#order + 1] = "child" end })
		local box = iup.vbox({ child, destroy_cb = function() order[#order + 1] = "box" end })
		iup.Destroy(box)
		assert.same({ "child", "box" }, order)
		assert.is_nil(iup.GetParent(child))
	end)

	it("errors like iuplua on a non-handle", function()
		assert.has_error(function() iup.SetAttribute({}, "X", "1") end)
	end)
end)

describe("imgui keys and status strings", function()
	local iup
	before_each(function() iup = host() end)

	it("has IUP's key codes", function()
		assert.equal(0xFF1B, iup.K_ESC)
		assert.equal(13, iup.K_CR)
		assert.equal(0xFF52, iup.K_UP)
		assert.equal(0xFFBE + 11, iup.K_F12)
		assert.equal(0x20000000 + 67, iup.K_cC)
		assert.equal(0x20000000 + 32, iup.K_cSP)
		assert.equal(0x40000000 + 0xFF51, iup.K_mLEFT)
		assert.equal(0x20000000 + 44, iup.K_cComma)
	end)

	it("reads mouse status strings", function()
		local s = iup._status({ ctrl = true, b1 = true, double = true })
		assert.is_true(iup.iscontrol(s))
		assert.is_true(iup.isbutton1(s))
		assert.is_true(iup.isdouble(s))
		assert.is_false(iup.isshift(s))
	end)
end)

describe("imgui runtime", function()
	local iup, R, B, Element
	before_each(function() iup, R, B, Element = host() end)

	local function dialog_with(child, extra)
		local init = { child, RASTERSIZE = "400x300" }
		for k, v in pairs(extra or {}) do init[k] = v end
		return iup.dialog(init)
	end

	it("opens the backend window for the first dialog and lays it out", function()
		local btn = iup.flatbutton({ TITLE = "Run", RASTERSIZE = "80x24" })
		local dlg = dialog_with(iup.vbox({ btn, MARGIN = "10x10" }), { TITLE = "Lunar" })
		iup.Show(dlg)
		assert.is_true(B.alive())
		assert.equal("Lunar", B.title)
		R.frame()
		local st = Element.state(btn)
		assert.equal(10, st.x)
		assert.equal(10, st.y)
		assert.equal(80, st.w)
		assert.equal("80x24", iup.GetAttribute(btn, "RASTERSIZE"))
	end)

	it("routes a click to the flat button and fires FLAT_ACTION", function()
		local fired = 0
		local btn = iup.flatbutton({ TITLE = "Go", RASTERSIZE = "80x24", flat_action = function() fired = fired + 1 end })
		local dlg = dialog_with(iup.vbox({ btn }))
		iup.Show(dlg)
		R.frame()
		B.queue({ mx = 10, my = 10 })
		B.queue({ press = 1 })
		B.queue({ release = 1 })
		R.frame(); R.frame(); R.frame()
		assert.equal(1, fired)
	end)

	it("fires enter and leave on hover changes", function()
		local log = {}
		local c = iup.canvas({ RASTERSIZE = "50x50",
			enterwindow_cb = function() log[#log + 1] = "enter" end,
			leavewindow_cb = function() log[#log + 1] = "leave" end })
		iup.Show(dialog_with(iup.vbox({ c })))
		R.frame()
		B.queue({ mx = 10, my = 10 }); R.frame()
		B.queue({ mx = 200, my = 200 }); R.frame()
		assert.same({ "enter", "leave" }, log)
	end)

	it("runs timers from the loop and stops on iup.CLOSE", function()
		local ticks = 0
		local t = iup.timer({ TIME = 100 })
		function t:action_cb()
			ticks = ticks + 1
			if ticks == 3 then return iup.CLOSE end
		end
		iup.Show(dialog_with(iup.vbox({})))
		t.run = "YES"
		assert.equal("YES", t.run)
		iup.MainLoop()
		assert.equal(3, ticks)
		t.run = "NO"
		assert.equal("NO", iup.GetAttribute(t, "RUN"))
	end)

	it("leaves MainLoop when the last dialog hides", function()
		local dlg = dialog_with(iup.vbox({}))
		iup.Show(dlg)
		local t = iup.timer({ TIME = 10, action_cb = function() iup.Hide(dlg) end })
		t.run = "YES"
		iup.MainLoop()
		assert.equal("NO", iup.GetAttribute(dlg, "VISIBLE"))
	end)

	it("runs a nested loop for Popup until the dialog hides", function()
		local main = dialog_with(iup.vbox({}))
		iup.Show(main)
		local popup = iup.dialog({ iup.vbox({}), RASTERSIZE = "100x80" })
		local t = iup.timer({ TIME = 50, action_cb = function(self) self.run = "NO"; iup.Hide(popup) end })
		t.run = "YES"
		local before = R.loopLevel()
		iup.Popup(popup, iup.CENTERPARENT, iup.CENTERPARENT)
		assert.equal(before, R.loopLevel())
		assert.equal("NO", iup.GetAttribute(popup, "VISIBLE"))
		assert.equal(150, Element.state(popup).data.ox) -- centred in the 400 wide window
	end)

	it("propagates K_ANY from the focus to the dialog and honours IGNORE", function()
		local seen = {}
		local field = iup.text({ k_any = function(_, c) seen[#seen + 1] = "field"; return iup.CONTINUE end })
		local dlg = dialog_with(iup.vbox({ field }), { k_any = function(_, c) seen[#seen + 1] = c; return iup.IGNORE end })
		iup.Show(dlg)
		iup.SetFocus(field)
		R.frame()
		B.queue({ keys = { { code = 0xFF1B, down = true } } })
		R.frame()
		assert.same({ "field", iup.K_ESC }, seen)
	end)

	it("sends Ctrl+letter as IUP's control code and typed text as characters", function()
		local codes = {}
		local dlg = dialog_with(iup.vbox({}), { k_any = function(_, c) codes[#codes + 1] = c end })
		iup.Show(dlg)
		R.frame()
		B.queue({ keys = { { code = 83, down = true, ctrl = true }, { code = 97, down = true } }, chars = { "a" } })
		R.frame()
		assert.same({ iup.K_cS, 97 }, codes)
	end)

	it("activates DEFAULTENTER and DEFAULTESC buttons", function()
		local hits = {}
		local ok = iup.flatbutton({ flat_action = function() hits[#hits + 1] = "ok" end })
		local cancel = iup.flatbutton({ flat_action = function() hits[#hits + 1] = "cancel" end })
		local dlg = dialog_with(iup.vbox({ ok, cancel }))
		iup.SetAttribute(dlg, "DEFAULTENTER", ok)
		iup.SetAttribute(dlg, "DEFAULTESC", cancel)
		iup.Show(dlg)
		R.frame()
		iup.SetFocus(nil)
		B.queue({ keys = { { code = 13, down = true }, { code = 0xFF1B, down = true } } })
		R.frame()
		assert.same({ "ok", "cancel" }, hits)
	end)

	it("moves focus with Tab and fires focus callbacks", function()
		local log = {}
		local a = iup.text({ getfocus_cb = function() log[#log + 1] = "a+" end, killfocus_cb = function() log[#log + 1] = "a-" end })
		local b = iup.text({ getfocus_cb = function() log[#log + 1] = "b+" end })
		iup.Show(dialog_with(iup.vbox({ a, b })))
		assert.equal(a, iup.GetFocus())
		R.frame()
		B.queue({ keys = { { code = 9, down = true } } })
		R.frame()
		assert.equal(b, iup.GetFocus())
		assert.same({ "a+", "a-", "b+" }, log)
	end)

	it("answers GetGlobal for screen and cursor", function()
		assert.equal("1920x1040", iup.GetGlobal("SCREENSIZE"))
		assert.matches("^%d+x%d+$", iup.GetGlobal("CURSORPOS"))
		iup.SetGlobal("LOCKLOOP", "YES")
		assert.equal("YES", iup.GetGlobal("LOCKLOOP"))
	end)

	it("logs a failing callback and keeps the loop alive", function()
		local warned
		R.warn = function(m) warned = m end
		local btn = iup.flatbutton({ RASTERSIZE = "40x20", flat_action = function() error("boom") end })
		iup.Show(dialog_with(iup.vbox({ btn })))
		R.frame()
		B.queue({ mx = 5, my = 5, press = 1 }); R.frame()
		B.queue({ release = 1 }); R.frame()
		R.frame()
		assert.is_true(B.alive())
	end)

	it("asks CLOSE_CB before closing the window", function()
		local asked = 0
		local dlg = dialog_with(iup.vbox({}), { close_cb = function() asked = asked + 1; return iup.IGNORE end })
		iup.Show(dlg)
		B.queue({ close_requested = true })
		R.frame()
		assert.equal(1, asked)
		assert.equal("YES", iup.GetAttribute(dlg, "VISIBLE"))
	end)

	it("shows a tooltip after the delay", function()
		local btn = iup.flatbutton({ RASTERSIZE = "40x20", TIP = "Run the build" })
		iup.Show(dialog_with(iup.vbox({ btn })))
		R.frame()
		B.queue({ mx = 5, my = 5 }); R.frame()
		B.advance(1)
		R.frame()
		local found = false
		for _, t in ipairs(B.texts()) do if t == "Run the build" then found = true end end
		assert.is_true(found)
	end)

	it("opens a file dialog through the backend", function()
		B.file_dialog_result = "C:/tmp/a.txt"
		local fd = iup.filedlg({ DIALOGTYPE = "SAVE", TITLE = "Save", EXTFILTER = "Text|*.txt|" })
		iup.Popup(fd)
		assert.equal("C:/tmp/a.txt", iup.GetAttribute(fd, "VALUE"))
		assert.equal("SAVE", B.last_file_dialog.type)
		assert.equal("Text|*.txt|", B.last_file_dialog.filter)
	end)

	it("reads and writes the clipboard", function()
		local cb = iup.clipboard({})
		cb.text = "hello"
		assert.equal("hello", B.clipboard)
		assert.equal("hello", cb.text)
	end)
end)

describe("imgui draw context", function()
	it("records and replays calls with an offset and alpha", function()
		local _, R, B = host()
		local Draw = require("core.imgui.Draw")
		local dc = Draw.new(B)
		dc:begin(100, 100)
		B.frame_calls = {}
		dc:record()
		dc:fill(1, 2, 10, 10, "255 0 0")
		local list = dc:stop()
		assert.equal(0, #B.frame_calls)
		dc:replay(list, 5, 7, 0.5)
		local c = B.frame_calls[1]
		assert.equal("rect_filled", c[1])
		assert.same({ 6, 9, 16, 19 }, { c[2], c[3], c[4], c[5] })
		local _, _, _, a = require("core.imgui.Color").unpack(c[6])
		assert.equal(128, a)
	end)

	it("wraps, ellipsizes and aligns text", function()
		local _, _, B = host()
		local Draw = require("core.imgui.Draw")
		local Fonts = require("core.imgui.Fonts")
		local f = Fonts.get("Segoe UI, -10") -- 5px per char in the Null backend
		assert.same({ "aaa bbb", "ccc" }, Draw.wrap(f, "aaa bbb ccc", 40))
		assert.equal("abc...", Draw.ellipsize(f, "abcdefghij", 30))
		local dc = Draw.new(B)
		dc:begin(200, 200)
		B.frame_calls = {}
		dc:text("ab", 0, 0, 100, 20, "0 0 0", f, { align = "ACENTER" })
		assert.equal(45, B.frame_calls[1][4])
	end)

	it("parses IUP colours", function()
		local Color = require("core.imgui.Color")
		assert.equal(Color.pack(1, 2, 3), Color.parse("1 2 3"))
		assert.equal(Color.pack(255, 0, 16, 32), Color.parse("#ff001020"))
		assert.equal(Color.pack(1, 2, 3, 4), Color.parse("1 2 3 4"))
		assert.is_nil(Color.parse(""))
	end)
end)
