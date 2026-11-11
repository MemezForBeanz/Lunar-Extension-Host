-- The native text controls' Win32 EDIT behaviour on the ImGui host, driven through the
-- frame loop with queued input on the Null backend (every character is px/2 wide there).
-- Geometry rules were measured on the IUP build with scripts/ui_textmargin.lua: BORDER=YES
-- puts the text 3 px inside on both axes, PADDING is a horizontal margin only, and
-- ALIGNMENT moves a line inside the format rectangle.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")

local B
local function boot()
	B = Null.new()
	R.init(B)
end

local function show(widget, w, h)
	local dlg = iup.dialog{ iup.vbox{ widget, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = w .. "x" .. h, BORDER = "NO" }
	iup.Show(dlg)
	R.frame(); R.frame()
	return dlg, Element.state(widget)
end

local function click(x, y, opts)
	opts = opts or {}
	B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", x = x, y = y, button = 1,
		double = opts.double, mods = opts.mods } } }); R.frame()
	B.queue({ events = { { type = "release", x = x, y = y, button = 1, mods = opts.mods } } }); R.frame()
end
local function drag(x1, y, x2)
	B.queue({ events = { { type = "move", x = x1, y = y }, { type = "press", x = x1, y = y, button = 1 } } }); R.frame()
	B.queue({ events = { { type = "move", x = x2, y = y } } }); R.frame()
	B.queue({ events = { { type = "release", x = x2, y = y, button = 1 } } }); R.frame()
end
local function key(code, mods)
	local k = { code = code, down = true }
	for m, v in pairs(mods or {}) do k[m] = v end
	B.queue({ keys = { k } }); R.frame()
end
local function type_text(s) B.queue({ chars = { s } }); R.frame() end

-- The text draw calls of the last frame whose string is `s`.
local function text_call(s)
	for _, c in ipairs(B.lastFrame()) do if c[1] == "text" and c[7] == s then return c end end
end
local function sel(t) return iup.GetAttribute(t, "SELECTIONPOS") end

describe("native text on the ImGui host: geometry", function()
	before_each(boot)

	it("starts the text at the control's edge without a border or padding", function()
		local t = iup.text{ VALUE = "abc", BORDER = "NO", RASTERSIZE = "200x20" }
		local _, st = show(t, 300, 100)
		local c = assert(text_call("abc"))
		assert.equal(st.x, c[4]); assert.equal(st.y, c[5])
	end)

	it("puts the text 3 px inside a BORDER=YES control on both axes", function()
		local t = iup.text{ VALUE = "abc", BORDER = "YES", RASTERSIZE = "200x26" }
		local _, st = show(t, 300, 100)
		local c = assert(text_call("abc"))
		assert.equal(st.x + 3, c[4]); assert.equal(st.y + 3, c[5])
	end)

	it("adds PADDING horizontally only (EM_SETMARGINS)", function()
		local t = iup.text{ VALUE = "abc", BORDER = "YES", PADDING = "4x2", RASTERSIZE = "200x26" }
		local _, st = show(t, 300, 100)
		local c = assert(text_call("abc"))
		assert.equal(st.x + 7, c[4]); assert.equal(st.y + 3, c[5])
	end)

	it("right-aligns and centres a line narrower than the field (ES_RIGHT, ES_CENTER)", function()
		local r = iup.text{ VALUE = "abcd", BORDER = "NO", ALIGNMENT = "ARIGHT", RASTERSIZE = "200x20" }
		local c = iup.text{ VALUE = "abcd", BORDER = "NO", ALIGNMENT = "ACENTER", RASTERSIZE = "200x20" }
		local dlg = iup.dialog{ iup.vbox{ r, c, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = "300x100", BORDER = "NO" }
		iup.Show(dlg); R.frame(); R.frame()
		local font = require("core.imgui.Fonts").forElement(r)
		local w = font:measure("abcd")
		local rs, cs = Element.state(r), Element.state(c)
		local found = {}
		for _, call in ipairs(B.lastFrame()) do
			if call[1] == "text" and call[7] == "abcd" then found[#found + 1] = call[4] end
		end
		table.sort(found)
		assert.same({ cs.x + math.floor((200 - w) / 2), rs.x + 200 - w }, found)
	end)

	it("draws a password as one bullet per character, multibyte ones included", function()
		local t = iup.text{ VALUE = "aé€", PASSWORD = "YES", BORDER = "NO", RASTERSIZE = "200x20" }
		show(t, 300, 100)
		assert.truthy(text_call("•••"))
	end)
end)

describe("native text on the ImGui host: mouse", function()
	before_each(boot)

	it("puts the caret on the nearest character boundary", function()
		local t = iup.text{ VALUE = "abcdef", BORDER = "NO", RASTERSIZE = "200x20" }
		local _, st = show(t, 300, 100)
		local cw = require("core.imgui.Fonts").forElement(t):measure("a")
		click(st.x + cw * 2 + cw * 0.4, st.y + 5)   -- left half of "c": before it
		assert.equal("2", iup.GetAttribute(t, "CARETPOS"))
		click(st.x + cw * 2 + cw * 0.6, st.y + 5)   -- right half of "c": after it
		assert.equal("3", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("hit-tests through a border, padding and alignment", function()
		local t = iup.text{ VALUE = "abcd", BORDER = "YES", PADDING = "4x2", ALIGNMENT = "ARIGHT", RASTERSIZE = "200x26" }
		local _, st = show(t, 300, 100)
		local font = require("core.imgui.Fonts").forElement(t)
		local cw, w = font:measure("a"), font:measure("abcd")
		local left = st.x + 3 + 4 + (200 - 14 - w)
		click(left + cw * 1 + 1, st.y + 8)
		assert.equal("1", iup.GetAttribute(t, "CARETPOS"))
		click(st.x + 10, st.y + 8)                 -- left of the text
		assert.equal("0", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("selects by dragging and extends with Shift+click", function()
		local t = iup.text{ VALUE = "abcdef", BORDER = "NO", RASTERSIZE = "200x20" }
		local _, st = show(t, 300, 100)
		local cw = require("core.imgui.Fonts").forElement(t):measure("a")
		drag(st.x + 1, st.y + 5, st.x + cw * 3 + 1)
		assert.equal("0:3", sel(t))
		click(st.x + cw * 5 + 1, st.y + 5, { mods = { shift = true } })
		assert.equal("0:5", sel(t))
	end)

	it("selects the word under a double click (default word break: blanks)", function()
		local t = iup.text{ VALUE = "foo bar.baz qux", BORDER = "NO", RASTERSIZE = "300x20" }
		local _, st = show(t, 400, 100)
		local cw = require("core.imgui.Fonts").forElement(t):measure("a")
		click(st.x + cw * 5 + 1, st.y + 5, { double = 1 })
		assert.equal("4:11", sel(t))
		assert.equal("bar.baz", iup.GetAttribute(t, "SELECTEDTEXT"))
	end)

	it("hit-tests the clicked line of a multiline", function()
		local t = iup.multiline{ VALUE = "abc\ndefgh\nij", BORDER = "NO", RASTERSIZE = "200x80", SCROLLBAR = "NO" }
		local _, st = show(t, 300, 120)
		local font = require("core.imgui.Fonts").forElement(t)
		local cw = font:measure("a")
		local _, ch = font:charsize()
		click(st.x + cw * 2 + 1, st.y + ch + 2)
		assert.equal("6", iup.GetAttribute(t, "CARETPOS")) -- "abc\nde|fgh"
		click(st.x + 150, st.y + ch * 2 + 2)                 -- past the end of "ij"
		assert.equal("12", iup.GetAttribute(t, "CARETPOS"))
	end)
end)

describe("native text on the ImGui host: keyboard", function()
	before_each(boot)

	local function focused(value, attrs)
		local t = iup.multiline{ VALUE = value, BORDER = "NO", RASTERSIZE = "200x80", SCROLLBAR = "NO" }
		for k, v in pairs(attrs or {}) do iup.SetAttribute(t, k, v) end
		show(t, 300, 120)
		iup.SetFocus(t); R.frame()
		return t
	end

	it("moves up and down keeping the x position, clamped to short lines", function()
		local t = focused("abcdef\nab\nabcdef")
		iup.SetAttribute(t, "CARETPOS", "5"); R.frame()
		key(iup.K_DOWN)
		assert.equal("9", iup.GetAttribute(t, "CARETPOS"))  -- end of "ab"
		key(iup.K_DOWN)
		assert.equal("12", iup.GetAttribute(t, "CARETPOS")) -- x of "ab|": column 2
		key(iup.K_UP); key(iup.K_UP)
		assert.equal("2", iup.GetAttribute(t, "CARETPOS"))
		key(iup.K_UP)                                         -- first line: stays
		assert.equal("2", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("extends the selection with Shift+Down and goes to the ends with Ctrl+Home/End", function()
		local t = focused("abc\ndef")
		iup.SetAttribute(t, "CARETPOS", "1"); R.frame()
		key(iup.K_DOWN, { shift = true })
		assert.equal("1:5", sel(t))
		key(iup.K_END, { ctrl = true })
		assert.equal("7", iup.GetAttribute(t, "CARETPOS"))
		key(iup.K_HOME, { ctrl = true })
		assert.equal("0", iup.GetAttribute(t, "CARETPOS"))
	end)

	it("fires CARET_CB with line and column on each move", function()
		local seen = {}
		local t = focused("ab\ncd")
		function t:caret_cb(lin, col, pos) seen[#seen + 1] = lin .. "," .. col .. "," .. pos end
		iup.SetAttribute(t, "CARETPOS", "0"); R.frame()
		key(iup.K_DOWN)
		key(iup.K_RIGHT)
		assert.same({ "2,1,3", "2,2,4" }, seen)
	end)

	it("scrolls a single-line field to keep the caret visible, a third of the width in", function()
		local t = iup.text{ VALUE = "", BORDER = "NO", RASTERSIZE = "60x20" }
		local _, st = show(t, 300, 100)
		iup.SetFocus(t); R.frame()
		type_text(string.rep("x", 40))
		local font = require("core.imgui.Fonts").forElement(t)
		local total = font:measure(string.rep("x", 40))
		-- the caret is at the end, so the text's end is at the right edge
		assert.equal(total - 60, st.data.scroll_x)
		key(iup.K_HOME)
		assert.equal(0, st.data.scroll_x)
	end)

	it("scrolls a multiline's lines to the caret and with the wheel", function()
		local lines = {}
		for i = 1, 20 do lines[i] = "line " .. i end
		local t = focused(table.concat(lines, "\n"))
		local st = Element.state(t)
		local _, ch = require("core.imgui.Fonts").forElement(t):charsize()
		iup.SetAttribute(t, "CARETPOS", "0"); R.frame()
		for _ = 1, 10 do key(iup.K_DOWN) end
		local top = tonumber(iup.GetAttribute(t, "FIRSTVISIBLELINE")) - 1
		assert.is_true(top > 0)
		assert.is_true(10 * ch >= top * ch and 11 * ch <= top * ch + 80)
		B.queue({ events = { { type = "move", x = st.x + 10, y = st.y + 10 }, { type = "wheel", dx = 0, dy = 1 } } }); R.frame()
		assert.equal(tostring(math.max(0, top - 3) + 1), iup.GetAttribute(t, "FIRSTVISIBLELINE"))
	end)

	it("types into a focused field and keeps READONLY fields unchanged", function()
		local t = focused("ab")
		iup.SetAttribute(t, "CARETPOS", "2"); R.frame()
		type_text("c")
		assert.equal("abc", iup.GetAttribute(t, "VALUE"))
		iup.SetAttribute(t, "READONLY", "YES")
		type_text("d")
		assert.equal("abc", iup.GetAttribute(t, "VALUE"))
	end)
end)

describe("native text on the ImGui host: caret blink", function()
	before_each(boot)

	it("blinks every 530 ms by waking the loop, not by drawing every frame", function()
		local t = iup.text{ VALUE = "ab", BORDER = "NO", RASTERSIZE = "100x20" }
		show(t, 200, 60)
		iup.SetFocus(t); R.frame()
		local function caret_drawn()
			for _, c in ipairs(B.lastFrame()) do if c[1] == "line" then return true end end
			return false
		end
		key(iup.K_END)
		assert.is_true(caret_drawn())
		B.advance(0.6); R.frame()
		assert.is_false(caret_drawn())
		B.advance(0.53); R.frame()
		assert.is_true(caret_drawn())
	end)
end)

-- Lunar fork patch 0001: IupFlatScrollBox NATIVETEXTSCROLL drives a multiline's own line
-- scroll (iup_flatscrollbox.c native mode, iupwin_text.c FIRSTVISIBLELINE and the wheel).
describe("native text on the ImGui host: NATIVETEXTSCROLL hosting", function()
	before_each(boot)

	local function hosted(n)
		local lines = {}
		for i = 1, n do lines[i] = "line " .. i end
		local t = iup.multiline{ VALUE = table.concat(lines, "\n"), BORDER = "NO", SCROLLBAR = "NO", EXPAND = "YES" }
		local box = iup.flatscrollbox{ t, NATIVETEXTSCROLL = "YES", FLATSCROLLBAR = "VERTICAL", RASTERSIZE = "300x200" }
		local dlg = iup.dialog{ iup.vbox{ box, MARGIN = "0x0", GAP = "0" }, RASTERSIZE = "400x300", BORDER = "NO" }
		iup.Show(dlg); R.frame(); R.frame()
		local _, ch = require("core.imgui.Fonts").forElement(t):charsize()
		return t, box, ch
	end

	it("keeps the text at viewport size and makes the line count the virtual height", function()
		local t, box, ch = hosted(100)
		local ts, bs = Element.state(t), Element.state(box)
		assert.equal(bs.x, ts.x); assert.equal(bs.y, ts.y)
		assert.equal(bs.w - 15, ts.w); assert.equal(bs.h, ts.h)
		assert.equal(tostring(100 * ch), iup.GetAttribute(box, "YMAX"))
		assert.equal(tostring(bs.h), iup.GetAttribute(box, "DY"))
	end)

	it("turns POSY into the text's first visible line without moving the text", function()
		local t, box, ch = hosted(100)
		local ts = Element.state(t)
		local y0 = ts.y
		iup.SetAttribute(box, "POSY", tostring(10 * ch + 3)); R.frame()
		assert.equal("11", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
		assert.equal(y0, ts.y)
	end)

	it("jumps to a line with SCROLLTO lin:col and SYNCFROMCHILD moves the thumb (Log Parser)", function()
		local t, box, ch = hosted(100)
		iup.SetAttribute(t, "SCROLLTO", "40:1")
		assert.equal("40", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
		iup.SetAttribute(box, "SYNCFROMCHILD", "1")
		assert.equal(tostring(39 * ch), iup.GetAttribute(box, "POSY"))
	end)

	it("clamps a jump so the last line sits at the bottom (EM_LINESCROLL)", function()
		local t, _, ch = hosted(100)
		iup.SetAttribute(t, "SCROLLTO", "100,1")
		local visible = math.floor((Element.state(t).h - 2) / ch) -- the format rect: 1 px in each side (EM_GETRECT)
		assert.equal(tostring(100 - visible + 1), iup.GetAttribute(t, "FIRSTVISIBLELINE"))
		iup.SetAttribute(t, "SCROLLTOPOS", "0")
		assert.equal("1", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
	end)

	it("hands the wheel to the box: 3 lines a notch through POSY", function()
		local t, box, ch = hosted(100)
		local ts = Element.state(t)
		iup.SetAttribute(box, "POSY", tostring(30 * ch)); R.frame()
		B.queue({ events = { { type = "move", x = ts.x + 20, y = ts.y + 20 }, { type = "wheel", dx = 0, dy = 1 } } }); R.frame()
		assert.equal(tostring(27 * ch), iup.GetAttribute(box, "POSY"))
		assert.equal("28", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
	end)

	it("lays a pending dialog out before SYNCFROMCHILD or a range read (IupRefresh is synchronous)", function()
		local t, box, ch = hosted(10)
		local lines = {}
		for i = 1, 300 do lines[i] = "row " .. i end
		iup.SetAttribute(t, "VALUE", table.concat(lines, "\n"))
		iup.Refresh(box)
		-- no frame: the Log Parser reads the new range and jumps in the same callback
		assert.equal(tostring(300 * ch), iup.GetAttribute(box, "YMAX"))
		iup.SetAttribute(t, "SCROLLTO", "200:1")
		iup.SetAttribute(box, "SYNCFROMCHILD", "1")
		assert.equal(tostring(199 * ch), iup.GetAttribute(box, "POSY"))
	end)

	it("ignores SCROLLTO on a single-line text (EM_LINESCROLL is multiline only)", function()
		local t = iup.text{ VALUE = "abc", RASTERSIZE = "100x20" }
		show(t, 200, 60)
		iup.SetAttribute(t, "SCROLLTO", "5")
		assert.equal("1", iup.GetAttribute(t, "FIRSTVISIBLELINE"))
		assert.equal(0, Element.state(t).data.scroll_x or 0)
	end)
end)

-- winTextSetCaretAttrib / winTextSetSelectionAttrib and their getters (the Log Parser
-- highlights the failure line with CARET "ln:1" and SELECTION "ln,1:ln,col").
describe("native text on the ImGui host: CARET and SELECTION", function()
	before_each(boot)

	local function multi(value)
		local t = iup.multiline{ VALUE = value, BORDER = "NO", SCROLLBAR = "NO", RASTERSIZE = "200x60" }
		show(t, 300, 100)
		return t
	end

	it("sets and reads CARET as 1-based lin,col on a multiline", function()
		local t = multi("abc\ndefgh\nij")
		iup.SetAttribute(t, "CARET", "2,3")
		assert.equal("6", iup.GetAttribute(t, "CARETPOS"))
		assert.equal("2,3", iup.GetAttribute(t, "CARET"))
		iup.SetAttribute(t, "CARET", "3:1")                 -- iupStrToIntInt with ',' reads line 3
		assert.equal("3,1", iup.GetAttribute(t, "CARET"))
		iup.SetAttribute(t, "CARET", "9,99")                -- clamped to the last line's end
		assert.equal("3,3", iup.GetAttribute(t, "CARET"))
	end)

	it("sets and reads CARET as the column on a single line", function()
		local t = iup.text{ VALUE = "hello", RASTERSIZE = "100x20" }
		show(t, 200, 60)
		iup.SetAttribute(t, "CARET", "3")
		assert.equal("2", iup.GetAttribute(t, "CARETPOS"))
		assert.equal("3", iup.GetAttribute(t, "CARET"))
	end)

	it("selects a whole line with SELECTION l,1:l,len+1 and scrolls it into view with CARET", function()
		local lines = {}
		for i = 1, 50 do lines[i] = "line " .. i end
		local t = multi(table.concat(lines, "\n"))
		iup.SetAttribute(t, "CARET", "30:1")
		iup.SetAttribute(t, "SELECTION", "30,1:30,8")
		assert.equal("line 30", iup.GetAttribute(t, "SELECTEDTEXT"))
		assert.equal("30,1:30,8", iup.GetAttribute(t, "SELECTION"))
		local st = Element.state(t)
		local _, ch = require("core.imgui.Fonts").forElement(t):charsize()
		local sy = (tonumber(iup.GetAttribute(t, "FIRSTVISIBLELINE")) - 1) * ch
		assert.is_true(sy <= 29 * ch and sy + st.h >= 30 * ch)
	end)

	it("returns no SELECTION when nothing is selected, and takes ALL and NONE", function()
		local t = iup.text{ VALUE = "hello", RASTERSIZE = "100x20" }
		show(t, 200, 60)
		assert.is_nil(iup.GetAttribute(t, "SELECTION"))
		iup.SetAttribute(t, "SELECTION", "ALL")
		assert.equal("1:6", iup.GetAttribute(t, "SELECTION"))
		iup.SetAttribute(t, "SELECTION", "2:4")
		assert.equal("el", iup.GetAttribute(t, "SELECTEDTEXT"))
		iup.SetAttribute(t, "SELECTION", "NONE")
		assert.is_nil(iup.GetAttribute(t, "SELECTION"))
	end)
end)
