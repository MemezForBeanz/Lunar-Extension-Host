local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")
local iup = require("core.imgui.iup")
local sci = require("core.imgui.native.sci")

describe("ImGui scintilla compatibility", function()
	it("paints the caret line with the colour supplied by CodeView", function()
		local B = require("core.imgui.backend.Null").new()
		local R = require("core.imgui.Runtime")
		R.init(B)
		local c = iup.scintilla{ VALUE = "terminal input" }
		local st = Element.state(c)
		st.x, st.y, st.w, st.h = 0, 0, 300, 100
		sci.send(c, 2096, 1) -- SCI_SETCARETLINEVISIBLE
		sci.send(c, 2098, 0x332211) -- SCI_SETCARETLINEBACK, BGR
		local dc = require("core.imgui.Draw").new(B)
		dc:begin(300, 100)
		Classes.get("scintilla").draw(c, st, dc, R)
		local found = false
		for _, call in ipairs(B.frame_calls) do
			if call[1] == "rect_filled" and call[6] == require("core.imgui.Color").parse("17 34 51") then found = true end
		end
		assert.is_true(found)
	end)
	it("answers CodeView's document and position messages", function()
		local c = iup.scintilla({ VALUE = "one\ntwo", VISIBLELINES = "4" })
		assert.equal(7, sci.send(c, 2006))
		assert.equal(2, sci.send(c, 2154))
		assert.equal(4, sci.send(c, 2167, 1))
		assert.equal(1, sci.send(c, 2166, 4))
		assert.equal(7, sci.send(c, 2136, 1))
		sci.send(c, 2160, 0, 3)
		assert.equal(3, sci.send(c, 2145))
	end)
	it("applies lexer keywords, edits through target messages, and reports styles", function()
		local c = iup.scintilla({ VALUE = "local n = 1" })
		sci.sends(c, 4006, 0, "lua")
		sci.sends(c, 4005, 0, "local function")
		assert.equal(5, sci.send(c, 2010, 0))
		sci.send(c, 2190, 6); sci.send(c, 2192, 7); sci.sends(c, 2194, 0, "x")
		assert.equal("local x = 1", iup.GetAttribute(c, "VALUE"))
	end)
	it("draws each styled run once, so the runs of a line add up to the line", function()
		local Null = require("core.imgui.backend.Null")
		local R = require("core.imgui.Runtime")
		local B = Null.new()
		R.init(B)
		local line = '"@odata.context": "/redfish/v1/$metadata", "Id": "1", "naïve" = 42'
		local c = iup.scintilla({ VALUE = line, RASTERSIZE = "900x200" })
		sci.sends(c, 4006, 0, "lua")
		iup.Show(iup.dialog({ iup.vbox({ c }), RASTERSIZE = "1000x300" }))
		R.frame()
		local drawn = {}
		for _, call in ipairs(B.lastFrame()) do
			if call[1] == "text" then drawn[#drawn + 1] = call[7] end
		end
		local joined = table.concat(drawn)
		assert.is_truthy(joined:find(line, 1, true), "runs: " .. table.concat(drawn, "|"))
		-- nothing else is drawn but the line (and a line number when a margin shows)
		assert.is_true(#joined <= #line + 1, "runs: " .. table.concat(drawn, "|"))
	end)
end)
