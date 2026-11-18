-- The ordinary text controls report and accept positions in UTF-16 code units, as the
-- Win32 EDIT control does (the value stays UTF-8). A line break is one unit. A position
-- between the halves of a surrogate pair reads as the pair's start. Scintilla stays in bytes.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local U = require("core.lib.utf16")

local E = "\xC3\xA9"                 -- é, 2 bytes, 1 unit
local JA = "\xE6\x97\xA5\xE6\x9C\xAC" -- 日本, 6 bytes, 2 units
local EMOJI = "\xF0\x9F\x98\x80"      -- U+1F600, 4 bytes, 2 units (a surrogate pair)

describe("core.lib.utf16", function()
	it("counts units: BMP characters one, others two", function()
		assert.equal(0, U.units(""))
		assert.equal(5, U.units("hello"))
		assert.equal(1, U.units(E))
		assert.equal(2, U.units(JA))
		assert.equal(2, U.units(EMOJI))
		assert.equal(1 + 1 + 2 + 2, U.units("a" .. E .. JA .. EMOJI:sub(1, 4)))
	end)

	it("maps units to byte offsets and back", function()
		local s = "a" .. E .. JA .. EMOJI .. "z"
		-- units: a=1 é=2 日=3 本=4 pair=5,6 z=7
		assert.equal(0, U.to_bytes(s, 0))
		assert.equal(1, U.to_bytes(s, 1))
		assert.equal(3, U.to_bytes(s, 2))
		assert.equal(6, U.to_bytes(s, 3))
		assert.equal(9, U.to_bytes(s, 4))
		assert.equal(13, U.to_bytes(s, 6))
		assert.equal(14, U.to_bytes(s, 7))
		assert.equal(14, U.to_bytes(s, 99))
		assert.equal(0, U.to_bytes(s, -3))
		assert.equal(0, U.to_units(s, 0))
		assert.equal(2, U.to_units(s, 3))
		assert.equal(6, U.to_units(s, 13))
		assert.equal(7, U.to_units(s, 14))
	end)

	it("reads a unit between the halves of a surrogate pair as the pair's start", function()
		local s = "a" .. EMOJI .. "z"
		assert.equal(1, U.to_bytes(s, 2))  -- inside the pair: its start
		assert.equal(5, U.to_bytes(s, 3))  -- after the pair
	end)

	it("snaps a byte offset inside a character to its start", function()
		local s = "a" .. JA
		assert.equal(1, U.snap(s, 2))
		assert.equal(1, U.snap(s, 3))
		assert.equal(4, U.snap(s, 4))
		assert.equal(0, U.snap(s, 0))
		assert.equal(7, U.snap(s, 99))
	end)

	it("steps over whole characters in both directions", function()
		local s = "a" .. E .. EMOJI
		assert.equal(1, U.next(s, 0))
		assert.equal(3, U.next(s, 1))
		assert.equal(7, U.next(s, 3))
		assert.equal(7, U.next(s, 7))
		assert.equal(3, U.prev(s, 7))
		assert.equal(1, U.prev(s, 3))
		assert.equal(0, U.prev(s, 1))
		assert.equal(0, U.prev(s, 0))
	end)

	it("takes every byte of invalid UTF-8 as one character of one unit", function()
		for _, bad in ipairs({
			"\x80", "\xBF\xBF", "\xC0\x80", "\xC1\xBF", "\xE3\x81", "\xE0\x80\x80", "\xED\xA0\x80",
			"\xF0\x80\x80\x80", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xFF", "\xF0\x9F\x98",
		}) do
			assert.equal(#bad, U.units(bad), bad:byte(1, -1))
			local b = 0
			for i = 1, #bad do b = U.next(bad, b); assert.equal(i, b) end
			for i = #bad - 1, 0, -1 do b = U.prev(bad, b); assert.equal(i, b) end
			for i = 0, #bad do assert.equal(i, U.to_bytes(bad, i)); assert.equal(i, U.snap(bad, i)) end
		end
		-- a good character next to bad bytes stays whole
		local s = "\xE3\x81" .. E .. "\x80"
		assert.equal(4, U.units(s))
		assert.equal(4, U.next(s, 2))
		assert.equal(2, U.prev(s, 4))
	end)
end)

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
	B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", x = x, y = y, button = 1, double = opts.double } } }); R.frame()
	B.queue({ events = { { type = "release", x = x, y = y, button = 1 } } }); R.frame()
end
local function key(code, mods)
	local k = { code = code, down = true }
	for m, v in pairs(mods or {}) do k[m] = v end
	B.queue({ keys = { k } }); R.frame()
end
local function type_text(s) B.queue({ chars = { s } }); R.frame() end
local function get(t, a) return iup.GetAttribute(t, a) end
local function set(t, a, v) iup.SetAttribute(t, a, v) end

describe("native text positions in UTF-16 units: single line", function()
	before_each(boot)
	local function field(value, attrs)
		local t = iup.text{ VALUE = value, BORDER = "NO", RASTERSIZE = "300x20" }
		for k, v in pairs(attrs or {}) do set(t, k, v) end
		show(t, 400, 60)
		iup.SetFocus(t); R.frame()
		return t
	end

	it("counts a character outside ASCII as the EDIT does", function()
		assert.equal("1", get(field(E), "COUNT"))
		assert.equal("2", get(field(JA), "COUNT"))
		assert.equal("2", get(field(EMOJI), "COUNT"))
		assert.equal("5", get(field("hello"), "COUNT"))
		assert.equal("0", get(field(""), "COUNT"))
	end)

	it("reads the caret after set VALUE and after typing in units", function()
		local t = field(JA)
		assert.equal("2", get(t, "CARETPOS"))
		assert.equal("3", get(t, "CARET"))
		type_text(E)
		assert.equal("3", get(t, "CARETPOS"))
		type_text(EMOJI)
		assert.equal("5", get(t, "CARETPOS"))
		assert.equal(JA .. E .. EMOJI, get(t, "VALUE"))
		assert.equal("5", get(t, "COUNT"))
	end)

	it("sets CARETPOS in units and clamps to the text", function()
		local t = field("a" .. JA .. "z")
		set(t, "CARETPOS", "2")
		assert.equal("2", get(t, "CARETPOS"))
		assert.equal(1 + 3, Element.state(t).data.caret) -- after 日
		set(t, "CARETPOS", "99")
		assert.equal("4", get(t, "CARETPOS"))
		set(t, "CARETPOS", "-5")
		assert.equal("0", get(t, "CARETPOS"))
	end)

	it("puts a CARETPOS inside a surrogate pair at the pair's start", function()
		local t = field("a" .. EMOJI .. "z")
		set(t, "CARETPOS", "2")
		assert.equal("1", get(t, "CARETPOS"))
		assert.equal(1, Element.state(t).data.caret)
		set(t, "CARETPOS", "3")
		assert.equal("3", get(t, "CARETPOS"))
	end)

	it("selects by units with SELECTIONPOS and SELECTION (1-based)", function()
		local t = field("a" .. E .. JA .. "z")
		set(t, "SELECTIONPOS", "1:3")
		assert.equal("1:3", get(t, "SELECTIONPOS"))
		assert.equal(E .. JA:sub(1, 3), get(t, "SELECTEDTEXT"))
		assert.equal("2:4", get(t, "SELECTION"))
		set(t, "SELECTION", "3:5")
		assert.equal("2:4", get(t, "SELECTIONPOS"))
		assert.equal(JA, get(t, "SELECTEDTEXT"))
		set(t, "SELECTION", "ALL")
		assert.equal("0:5", get(t, "SELECTIONPOS"))
		assert.equal("1:6", get(t, "SELECTION"))
	end)

	it("never ends a selection inside a surrogate pair", function()
		local t = field(EMOJI .. "z")
		set(t, "SELECTIONPOS", "0:1")
		local st = Element.state(t)
		assert.equal(0, st.data.anchor); assert.equal(0, st.data.caret)
		set(t, "SELECTIONPOS", "0:2")
		assert.equal(EMOJI, get(t, "SELECTEDTEXT"))
		assert.equal("0:2", get(t, "SELECTIONPOS"))
	end)

	it("moves, deletes and backspaces by whole characters", function()
		local t = field("a" .. E .. JA .. EMOJI)
		key(iup.K_HOME)
		key(iup.K_RIGHT); assert.equal("1", get(t, "CARETPOS"))
		key(iup.K_RIGHT); assert.equal("2", get(t, "CARETPOS"))
		key(iup.K_RIGHT); assert.equal("3", get(t, "CARETPOS"))
		key(iup.K_RIGHT, { shift = true }); key(iup.K_RIGHT, { shift = true })
		assert.equal("3:6", get(t, "SELECTIONPOS")) -- 本, then the pair, one step each
		key(iup.K_RIGHT)
		assert.equal("6", get(t, "CARETPOS"))
		key(iup.K_LEFT); assert.equal("4", get(t, "CARETPOS")) -- the pair is one step
		key(iup.K_BS)
		assert.equal("a" .. E .. JA:sub(1, 3) .. EMOJI, get(t, "VALUE"))
		assert.equal("3", get(t, "CARETPOS"))
		key(iup.K_DEL)
		assert.equal("a" .. E .. JA:sub(1, 3), get(t, "VALUE"))
		assert.equal("3", get(t, "COUNT"))
	end)

	it("fires CARET_CB with the column and position in units", function()
		local seen = {}
		local t = field("a" .. E .. JA)
		function t:caret_cb(lin, col, pos) seen[#seen + 1] = lin .. "," .. col .. "," .. pos end
		key(iup.K_HOME)
		key(iup.K_RIGHT); key(iup.K_RIGHT); key(iup.K_RIGHT)
		assert.same({ "1,1,0", "1,2,1", "1,3,2", "1,4,3" }, seen)
	end)

	it("limits the text with NC in units", function()
		local t = field("", { NC = "3" })
		type_text(JA .. E .. "x")
		assert.equal(JA .. E, get(t, "VALUE"))
		type_text("y")
		assert.equal(JA .. E, get(t, "VALUE"))
		local u = field("", { NC = "3" })
		type_text("a" .. EMOJI .. "b")  -- a + the pair is 3 units; b does not fit
		assert.equal("a" .. EMOJI, get(u, "VALUE"))
		local w = field("", { NC = "2" })
		type_text("a" .. EMOJI)         -- the pair does not fit whole: not split
		assert.equal("a", get(w, "VALUE"))
	end)

	it("leaves the limit of ASCII text in bytes as before", function()
		local t = field("", { NC = "4" })
		type_text("abcdef")
		assert.equal("abcd", get(t, "VALUE"))
	end)

	it("inserts, appends and deletes ranges in units", function()
		local t = field(JA)
		set(t, "SELECTIONPOS", "1:1")
		set(t, "INSERT", E)
		assert.equal(JA:sub(1, 3) .. E .. JA:sub(4), get(t, "VALUE"))
		assert.equal("2", get(t, "CARETPOS"))
		set(t, "APPEND", EMOJI)
		assert.equal("5", get(t, "CARETPOS"))
		assert.equal("5", get(t, "COUNT"))
		set(t, "DELETERANGE", "1,3")
		assert.equal(JA:sub(1, 3) .. EMOJI, get(t, "VALUE"))
	end)

	it("keeps ASCII positions exactly as before", function()
		local t = field("hello")
		assert.equal("5", get(t, "CARETPOS"))
		set(t, "SELECTIONPOS", "1:4")
		assert.equal("1:4", get(t, "SELECTIONPOS"))
		assert.equal("ell", get(t, "SELECTEDTEXT"))
		assert.equal("2:5", get(t, "SELECTION"))
		set(t, "CARET", "3")
		assert.equal("2", get(t, "CARETPOS"))
	end)

	it("copes with invalid UTF-8: every bad byte is a unit and nothing loops", function()
		local t = field("a\xE3\x81" .. "b\x80")
		assert.equal("5", get(t, "COUNT"))
		key(iup.K_HOME)
		for i = 1, 5 do key(iup.K_RIGHT); assert.equal(tostring(i), get(t, "CARETPOS")) end
		for i = 4, 0, -1 do key(iup.K_LEFT); assert.equal(tostring(i), get(t, "CARETPOS")) end
		key(iup.K_END, { ctrl = true })
		key(iup.K_BS); assert.equal("a\xE3\x81" .. "b", get(t, "VALUE"))
		key(iup.K_LEFT, { ctrl = true }); key(iup.K_RIGHT, { ctrl = true })
		set(t, "SELECTION", "ALL")
		assert.equal("1:5", get(t, "SELECTION"))
		local lone = field("\xFF")
		key(iup.K_HOME); key(iup.K_RIGHT, { ctrl = true })
		assert.equal("1", get(lone, "CARETPOS"))
	end)

	it("hit-tests the mouse in units", function()
		local t = field(JA .. "ab")
		local st = Element.state(t)
		local font = require("core.imgui.Fonts").forElement(t)
		click(st.x + font:measure(JA) + font:measure("a") + 1, st.y + 5)
		assert.equal("3", get(t, "CARETPOS"))
		click(st.x + 290, st.y + 5)
		assert.equal("4", get(t, "CARETPOS"))
		click(st.x, st.y + 5)
		assert.equal("0", get(t, "CARETPOS"))
	end)

	it("answers ConvertXYToPos in units", function()
		local t = field(JA .. "ab")
		local font = require("core.imgui.Fonts").forElement(t)
		assert.equal(4, iup.ConvertXYToPos(t, 290, 5))
		assert.equal(0, iup.ConvertXYToPos(t, 0, 5))
		assert.equal(3, iup.ConvertXYToPos(t, font:measure(JA) + font:measure("a") + 1, 5))
	end)

	it("converts lin/col and positions on a single line", function()
		local t = field(JA .. "ab")
		assert.equal(3, iup.TextConvertLinColToPos(t, 1, 4))
		local lin, col = iup.TextConvertPosToLinCol(t, 3)
		assert.equal(1, lin); assert.equal(4, col)
	end)
end)

describe("native text positions in UTF-16 units: multiline", function()
	before_each(boot)
	local function area(value)
		local t = iup.multiline{ VALUE = value, BORDER = "NO", SCROLLBAR = "NO", RASTERSIZE = "300x100" }
		show(t, 400, 160)
		iup.SetFocus(t); R.frame()
		return t
	end
	local text = E .. JA .. "\n" .. EMOJI .. "ab\nz"

	it("counts a line break as one unit", function()
		-- é 日本 \n pair a b \n z = 1 + 2 + 1 + 2 + 2 + 1 + 1
		assert.equal("10", get(area(text), "COUNT"))
	end)

	it("reads CARET as lin,col and CARETPOS in units", function()
		local t = area(text)
		set(t, "CARET", "2,3")                         -- after the pair
		assert.equal("2,3", get(t, "CARET"))
		assert.equal("6", get(t, "CARETPOS"))          -- é 日 本 \n = 4, pair = 2
		assert.equal(E .. JA .. "\n" .. EMOJI, text:sub(1, Element.state(t).data.caret))
		set(t, "CARET", "1,3")
		assert.equal("1,3", get(t, "CARET"))
		assert.equal("2", get(t, "CARETPOS"))
		set(t, "CARET", "1,99")                        -- the end of line 1
		assert.equal("1,4", get(t, "CARET"))
		assert.equal("3", get(t, "CARETPOS"))
	end)

	it("sets and reads SELECTION as lin,col:lin,col", function()
		local t = area(text)
		set(t, "SELECTION", "1,2:2,3")
		assert.equal(JA .. "\n" .. EMOJI, get(t, "SELECTEDTEXT"))
		assert.equal("1,2:2,3", get(t, "SELECTION"))
		assert.equal("1:6", get(t, "SELECTIONPOS"))
	end)

	it("sets SELECTIONPOS across lines in units", function()
		local t = area(text)
		set(t, "SELECTIONPOS", "3:7")
		assert.equal("\n" .. EMOJI .. "a", get(t, "SELECTEDTEXT"))
		assert.equal("1,4:2,4", get(t, "SELECTION"))
	end)

	it("moves up and down keeping the x position over wide characters", function()
		local t = area("abc\n" .. JA .. "d")
		set(t, "CARETPOS", "3")
		key(iup.K_DOWN)
		local pos = tonumber(get(t, "CARETPOS"))
		assert.is_true(pos >= 4 and pos <= 8)
		local st = Element.state(t)
		assert.equal(st.data.caret, U.snap(st.data.text, st.data.caret))
	end)

	it("fires CARET_CB with lin, col and pos in units", function()
		local seen = {}
		local t = area("a" .. E .. "\n" .. JA)
		function t:caret_cb(lin, col, pos) seen[#seen + 1] = lin .. "," .. col .. "," .. pos end
		set(t, "CARETPOS", "0"); R.frame()
		key(iup.K_DOWN)
		key(iup.K_RIGHT)
		assert.same({ "2,1,3", "2,2,4" }, seen)
	end)

	it("hit-tests a click and ConvertXYToPos in units", function()
		local t = area(text)
		local st = Element.state(t)
		local font = require("core.imgui.Fonts").forElement(t)
		local _, ch = font:charsize()
		click(st.x + 250, st.y + ch + 2)               -- past the end of line 2
		assert.equal("8", get(t, "CARETPOS"))
		assert.equal(8, iup.ConvertXYToPos(t, 250, ch + 2))
	end)

	it("converts lin/col and positions", function()
		local t = area(text)
		assert.equal(4, iup.TextConvertLinColToPos(t, 2, 1))
		assert.equal(6, iup.TextConvertLinColToPos(t, 2, 3))
		assert.equal(10, iup.TextConvertLinColToPos(t, 9, 9)) -- clamped to the end
		local lin, col = iup.TextConvertPosToLinCol(t, 6)
		assert.equal(2, lin); assert.equal(3, col)
		lin, col = iup.TextConvertPosToLinCol(t, 3)
		assert.equal(1, lin); assert.equal(4, col)
		lin, col = iup.TextConvertPosToLinCol(t, 4)
		assert.equal(2, lin); assert.equal(1, col)
	end)

	it("scrolls to the line of a position given in units", function()
		local lines = {}
		for i = 1, 30 do lines[i] = E .. E .. i end
		local t = area(table.concat(lines, "\n"))
		set(t, "SCROLLTOPOS", "0")
		assert.equal("1", get(t, "FIRSTVISIBLELINE"))
		-- every line is "éé" + number: unit position of line 20's start
		local before = 0
		for i = 1, 19 do before = before + 2 + #tostring(i) + 1 end
		set(t, "SCROLLTOPOS", tostring(before))
		assert.is_true(tonumber(get(t, "FIRSTVISIBLELINE")) > 1)
	end)
end)

describe("core.lib.utf16 names the host UI code uses", function()
	it("byte_to_units, units_to_byte and length match to_units, to_bytes and units", function()
		local s = "a\240\159\152\128b\228\184\150"
		assert.equal(U.units(s), U.length(s))
		assert.equal(0, U.length(nil))
		for b = 0, #s do assert.equal(U.to_units(s, b), U.byte_to_units(s, b)) end
		for u = 0, U.units(s) do assert.equal(U.to_bytes(s, u), U.units_to_byte(s, u)) end
		assert.equal(U.to_units(s, 3), U.byte_to_units(s, 3.7))
	end)
end)
