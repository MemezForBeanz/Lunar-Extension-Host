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
