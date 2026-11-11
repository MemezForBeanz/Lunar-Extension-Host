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
