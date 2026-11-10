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
