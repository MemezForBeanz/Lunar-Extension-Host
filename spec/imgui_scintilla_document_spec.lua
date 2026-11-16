local iup = require("core.imgui.iup")
local E = require("core.imgui.Element")
local C = require("core.imgui.Classes")
local sci = require("core.imgui.native.sci")
local Document = require("core.imgui.scintilla.document")
local bit = require("bit")
describe("Scintilla shared documents", function()
	local a, b
	before_each(function()
		require("core.imgui.Runtime").init(require("core.imgui.backend.Null").new())
		a, b = iup.scintilla{ VALUE = "abcd\nef" }, iup.scintilla{}
		sci.send(b, 2358, 0, sci.send(a, 2357))
	end)
	after_each(function() iup.Destroy(a); iup.Destroy(b) end)
	local function replace(view, from, to, text)
		sci.send(view, 2190, from); sci.send(view, 2192, to); sci.sends(view, 2194, 0, text)
	end
	it("shares a stable document but resets view state on attachment", function()
		assert.equal(sci.send(a, 2357), sci.send(b, 2357))
		assert.equal("abcd\nef", b.VALUE)
		assert.equal(0, sci.send(b, 2008))
		sci.send(a, 2160, 2, 5)
		assert.equal(0, sci.send(b, 2009))
	end)
	it("shifts selections on insertion and collapses them inside deletions", function()
		sci.send(b, 2160, 2, 6)
		replace(a, 1, 1, "XYZ")
		assert.equal("aXYZbcd\nef", b.VALUE)
		assert.equal(5, sci.send(b, 2009)); assert.equal(9, sci.send(b, 2008))
		replace(a, 3, 8, "")
		assert.equal(3, sci.send(b, 2009)); assert.equal(4, sci.send(b, 2008))
	end)
	it("shares undo, redo and save point notifications", function()
		local saves, changes = { {}, {} }, { 0, 0 }
		for i, view in ipairs({ a, b }) do
			view.SAVEPOINT_CB = function(_, state) saves[i][#saves[i] + 1] = state end
			view.MODIFIED_CB = function(_, _, flags) if bit.band(flags, 3) ~= 0 then changes[i] = changes[i] + 1 end end
		end
		sci.send(a, 2014)
		replace(a, 0, 1, "Z")
		assert.equal(1, sci.send(b, 2159)); assert.equal(1, sci.send(b, 2174))
		sci.send(b, 2176)
		assert.equal("abcd\nef", a.VALUE); assert.equal(0, sci.send(a, 2159))
		sci.send(a, 2011); assert.equal("Zbcd\nef", b.VALUE)
		assert.same({ 1, 0, 1, 0 }, saves[1]); assert.same(saves[1], saves[2])
		assert.equal(changes[1], changes[2]); assert.is_true(changes[1] > 0)
	end)
	it("shares edits made through keyboard and IUP attributes", function()
		sci.send(a, 2025, 1)
		C.get("scintilla").event(a, E.state(a), { type = "char", char = "!" })
		assert.equal("a!bcd\nef", b.VALUE)
		b.VALUE = "new"
		assert.equal("new", a.VALUE)
		a.INSERT = "!"; assert.equal("new!", b.VALUE)
	end)
	it("shares read only, style bytes, lexer, markers and indicators", function()
		sci.send(a, 2032, 0); sci.send(a, 2033, 2, 7)
		assert.equal(7, sci.send(b, 2010, 1))
		sci.send(a, 2043, 1, 3); assert.equal(8, sci.send(b, 2046, 1))
		sci.send(a, 2500, 2); sci.send(a, 2504, 0, 3)
		assert.equal(1, E.state(b).data.doc:indicator_value_at(2, 2))
		sci.send(b, 2171, 1); replace(a, 0, 1, "X"); assert.equal("abcd\nef", a.VALUE)
		sci.send(b, 2171, 0)
		sci.sends(a, 4006, 0, "lua"); sci.sends(a, 4005, 0, "abcd")
		assert.equal(5, sci.send(b, 2010, 0))
	end)
	it("retains created documents and drops the last reference on destroy", function()
		local handle = sci.send(a, 2375)
		local doc = Document.from_handle(handle)
		assert.equal(1, doc.refs)
		sci.send(a, 2358, 0, handle); sci.send(a, 2377, 0, handle)
		assert.equal(1, doc.refs)
		sci.send(b, 2358, 0, handle); assert.equal(2, doc.refs)
		sci.send(a, 2358, 0, 0); assert.equal(1, doc.refs)
		iup.Destroy(b); assert.is_nil(Document.from_handle(handle))
	end)
	it("preserves constructor read only and keeps view configuration independent", function()
		local c = iup.scintilla{ VALUE = "locked", READONLY = "YES" }
		sci.sends(c, 2282, 1, "!"); assert.equal("locked", c.VALUE); iup.Destroy(c)
		sci.send(a, 2268, 2); sci.send(a, 2373, 3); sci.send(a, 2242, 0, 20)
		assert.equal(0, sci.send(b, 2269)); assert.equal(0, sci.send(b, 2374)); assert.equal(0, E.state(b).data.margin_width[0])
	end)
	it("stores configuration messages sent by CodeView", function()
		local settings = { [2035] = "buffered_draw", [2611] = "font_quality", [2130] = "hscrollbar", [2280] = "vscrollbar",
			[2371] = "popup_mode", [2516] = "scroll_width_tracking", [2655] = "caret_line_always",
			[2525] = "extra_ascent", [2527] = "extra_descent" }
		for msg, field in pairs(settings) do sci.send(a, msg, 2); assert.equal(2, E.state(a).data[field]) end
		sci.send(a, 2037, 65001); assert.equal(65001, E.state(b).data.doc.code_page)
		sci.send(a, 2031, 2); assert.equal(2, E.state(b).data.doc.eol_mode)
		sci.send(a, 2040, 2, 3); assert.equal(3, E.state(a).data.marker_symbol[2])
		sci.send(a, 2290, 1, 0x112233); assert.equal("51 34 17", E.state(a).data.fold_margin_color)
		sci.send(a, 2291, 1, 0x112233); assert.equal("51 34 17", E.state(a).data.fold_margin_hi_color)
		sci.sends(a, 4004, "fold", "1"); assert.equal("1", E.state(b).data.properties.fold)
	end)
	it("uses the document EOL mode for typed newlines in both views", function()
		for mode, newline in pairs({ [0] = "\r\n", [1] = "\r", [2] = "\n" }) do
			sci.sends(a, 2181, 0, "x"); sci.send(a, 2031, mode); sci.send(b, 2025, 1)
			C.get("scintilla").event(b, E.state(b), { type = "key", key = iup.K_CR, mods = {} })
			assert.equal("x" .. newline, a.VALUE)
			assert.equal(2, sci.send(a, 2154))
		end
	end)
	it("keeps CR, LF and CRLF line indexes correct across splices", function()
		local d = Document.new()
		local samples = { "a\r\nb\rc\nd", "\r\n", "\n\n", "abc", "" }
		for _, text in ipairs(samples) do
			for pos = 0, #text do
				d.text, d.starts = "", { 0 }; d:delete_undo_history(); d:insert_string(0, text)
				d:insert_string(pos, "\r\nx")
				local expected = { 0 }
				for i = 1, #d.text do local c = d.text:byte(i); if c == 10 or c == 13 and d.text:byte(i + 1) ~= 10 then expected[#expected + 1] = i end end
				assert.same(expected, d.starts)
				d:delete_chars(pos, 3); assert.equal(text, d.text)
			end
		end
	end)
end)
