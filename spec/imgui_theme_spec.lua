-- IUP's native themes on the ImGui host: DEFAULTTHEME at creation and THEME/NTHEME copies.
local Null = require("core.imgui.backend.Null")

local function host()
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new()
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end

describe("imgui themes: NTHEME", function()
	-- iupClassObjectAttribCanCopy: only attributes registered on the element's class copy.
	it("copies only the class's registered attributes", function()
		local iup = host()
		local t = iup.user({ TITLELINE = "NO", FONT = "Segoe UI, 12" })
		iup.SetHandle("SPEC_THEME2", t)
		local b = iup.vbox({})
		iup.SetAttribute(b, "NTHEME", "SPEC_THEME2")
		assert.is_nil(require("core.imgui.Element").own(b, "TITLELINE"))
		assert.equal("Segoe UI, 12", iup.GetAttribute(b, "FONT"))
	end)
end)
