-- The multiline IupText on the ImGui host against iupwin_text.c (a Win32 EDIT).
local Null = require("core.imgui.backend.Null")

local function host(opts)
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new(opts)
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

describe("imgui multiline: APPEND and INSERT", function()
	-- winTextSetAppendAttrib: EM_REPLACESEL works on a read-only EDIT, a multiline that has
	-- text gets "\r\n" first (APPENDNEWLINE, default YES), and the callbacks are disabled.
	-- The host went through the typing path: nothing reached a READONLY control (the Build
	-- Queue output log), no line break, and ACTION/VALUECHANGED_CB fired.
	it("appends to a read-only multiline on a new line without callbacks", function()
		local iup, R = host()
		local changed = 0
		local t = iup.text({ MULTILINE = "YES", READONLY = "YES" })
		t.valuechanged_cb = function() changed = changed + 1 end
		local d = iup.dialog({ t }); iup.Show(d); R.frame()
		iup.SetAttribute(t, "APPEND", "first")
		iup.SetAttribute(t, "APPEND", "second")
		assert.equal("first\nsecond", iup.GetAttribute(t, "VALUE"))
		assert.equal(tostring(#"first\nsecond"), iup.GetAttribute(t, "CARETPOS"))
		assert.equal(0, changed)
		iup.SetAttribute(t, "APPENDNEWLINE", "NO")
		iup.SetAttribute(t, "APPEND", "!")
		assert.equal("first\nsecond!", iup.GetAttribute(t, "VALUE"))
	end)

	it("inserts over the selection, read-only or not", function()
		local iup, R = host()
		local t = iup.text({ MULTILINE = "YES", READONLY = "YES", VALUE = "abcdef" })
		local d = iup.dialog({ t }); iup.Show(d); R.frame()
		iup.SetAttribute(t, "SELECTIONPOS", "1:3")
		iup.SetAttribute(t, "INSERT", "XY")
		assert.equal("aXYdef", iup.GetAttribute(t, "VALUE"))
		assert.equal("3", iup.GetAttribute(t, "CARETPOS"))
	end)
end)

describe("imgui multiline: the EDIT's view", function()
	-- Measured on the IUP build (scripts/ui_scroll.lua): a 200x120 multiline with the default
	-- BORDER and SCROLLBAR holding 30 lines and a trailing line break. The client is 196x116;
	-- both bars show (the vertical 17x99, the horizontal 179x17); EM_GETRECT is 1,1,178,91
	-- with 15 px lines; the vertical thumb is 17..30; a wheel notch scrolls 3 lines, an arrow
	-- 1, the track 5; CARETPOS=0 goes back to the top; APPEND (with its line break) shows
	-- the last line at the bottom (first visible line 26). The host had no bars and no view:
	-- the text never scrolled.
	local function make()
		local iup, R, B, Element = host()
		local t = iup.text({ MULTILINE = "YES", RASTERSIZE = "200x120",
			VALUE = string.rep("line of text that is long enough to wrap or scroll\n", 30) })
		local d = iup.dialog({ iup.vbox({ t, MARGIN = "10x10" }), RASTERSIZE = "400x300" })
		iup.Show(d); R.frame(); R.frame()
		return iup, R, B, Element, t, Element.state(t)
	end
	local W = function() return require("core.imgui.widgets.winscrollbar") end

	it("has the measured format rect, bars and thumb", function()
		local iup, R, B, Element, t, st = make()
		assert.same({ x = 1, y = 1, w = 177, h = 90, lh = 15 }, st.data.metrics)
		local v, h = W().info(t, true), W().info(t, false)
		assert.same({ st.x + 2 + 179, st.y + 2, 17, 99, 17, 30 }, { v.x, v.y, v.w, v.h, v.thumb_top, v.thumb_bottom })
		assert.same({ st.x + 2, st.y + 2 + 99, 179, 17 }, { h.x, h.y, h.w, h.h })
		assert.equal("0", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("scrolls 3 lines a notch, 1 an arrow, a page less one the track, and to the caret", function()
		local iup, R, B, Element, t, st = make()
		B.queue({ mx = st.x + 50, my = st.y + 40 }); R.frame()
		B.queue({ mx = st.x + 50, my = st.y + 40, wheel = -1 }); R.frame()
		assert.equal(3, st.data.top_line)
		local v = W().info(t, true)
		local function click(x, y)
			B.queue({ mx = x, my = y }); R.frame(); B.queue({ mx = x, my = y, press = 1 }); R.frame()
			B.queue({ mx = x, my = y, release = 1 }); R.frame()
		end
		click(v.x + 8, v.y + v.h - 8)
		assert.equal(4, st.data.top_line)
		click(v.x + 8, v.y + v.h - 20)
		assert.equal(9, st.data.top_line)
		iup.SetAttribute(t, "CARETPOS", "0")
		assert.equal(0, st.data.top_line)
		iup.SetAttribute(t, "APPEND", "appended line")
		assert.equal(26, st.data.top_line)
		assert.equal("1544", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("keeps the bars, without a thumb, while nothing scrolls", function()
		local iup, R, B, Element = host()
		local t = iup.text({ MULTILINE = "YES", RASTERSIZE = "120x120", VALUE = "two\nlines" })
		local d = iup.dialog({ iup.vbox({ t }), RASTERSIZE = "400x300" })
		iup.Show(d); R.frame(); R.frame()
		local v = W().info(t, true)
		assert.is_not_nil(v)
		assert.equal(v.thumb_top, v.thumb_bottom)
		assert.is_not_nil(W().info(t, false))
	end)

	it("puts the caret on the clicked line and column", function()
		local iup, R, B, Element, t, st = make()
		-- line 2 (y 1 + 15 + 3), 4 characters in (6 px each in the Null backend)
		local x, y = st.x + 2 + 1 + 4 * 6 + 1, st.y + 2 + 1 + 15 + 3
		B.queue({ mx = x, my = y }); R.frame(); B.queue({ mx = x, my = y, press = 1 }); R.frame()
		B.queue({ mx = x, my = y, release = 1 }); R.frame()
		assert.equal(tostring(51 + 4), iup.GetAttribute(t, "CARETPOS"))
	end)
end)

describe("imgui multiline: Enter and Tab", function()
	-- ES_WANTRETURN and iupKeyProcessNavigation: in a multiline Enter is a line break and Tab
	-- a character; Ctrl+Enter is DEFAULTENTER and Ctrl+Tab moves the focus. The host ran
	-- DEFAULTENTER on Enter and moved the focus on Tab.
	it("types a line break and a tab", function()
		local iup, R, B, Element = host()
		local fired = 0
		local ok = iup.flatbutton({ TITLE = "OK", flat_action = function() fired = fired + 1 end })
		local t = iup.text({ MULTILINE = "YES", RASTERSIZE = "200x120", VALUE = "ab" })
		local d = iup.dialog({ iup.vbox({ t, ok }), DEFAULTENTER = ok })
		iup.SetAttribute(d, "DEFAULTENTER", ok)
		iup.Show(d); R.frame()
		R.setFocus(t)
		iup.SetAttribute(t, "CARETPOS", "1")
		B.queue({ keys = { { code = 0x0D, down = true } } }); R.frame()
		B.queue({ keys = { { code = 0x09, down = true } } }); R.frame()
		assert.equal("a\n\tb", iup.GetAttribute(t, "VALUE"))
		assert.equal(0, fired)
		assert.equal(t, R.focused())
	end)
end)
