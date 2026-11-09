-- IupDropButton on the ImGui host (port of iup_dropbutton.c).
local Null = require("core.imgui.backend.Null")

describe("imgui dropbutton", function()
	local iup, R, B, Element
	before_each(function()
		R = require("core.imgui.Runtime")
		B = Null.new()
		R.init(B)
		Element = require("core.imgui.Element")
		Element.globals.DEFAULTFONT = "Segoe UI, -10"
		iup = require("core.imgui.iup")
	end)

	it("measures title + padding + the 16px arrow area + border", function()
		local b = iup.dropbutton({ TITLE = "abcd" })
		local w, h = require("core.imgui.Layout").natural(b)
		-- text 20x13, PADDING 3x3, focus room 4, arrow 16 (not high DPI), border 2
		assert.same({ 20 + 6 + 4 + 16 + 2, 13 + 6 + 4 + 2 }, { w, h })
	end)

	it("uses VISIBLECOLUMNS for the text width", function()
		local b = iup.dropbutton({ TITLE = "x", VISIBLECOLUMNS = "20" })
		local w = require("core.imgui.Layout").natural(b)
		assert.equal(100 + 6 + 16 + 2, w) -- 20 * 50/10 + padding + arrow + border
	end)

	it("draws its title and the arrow", function()
		local b = iup.dropbutton({ TITLE = "HPE Dark", RASTERSIZE = "180x26" })
		iup.Show(iup.dialog({ iup.vbox({ b }), RASTERSIZE = "300x200" }))
		R.frame()
		local found, poly = false, false
		for _, c in ipairs(B.lastFrame()) do
			if c[1] == "text" and c[7] == "HPE Dark" then found = true end
			if c[1] == "poly" then poly = true end
		end
		assert.is_true(found)
		assert.is_true(poly)
	end)

	it("shows DROPCHILD below itself and closes it with SHOWDROPDOWN=NO", function()
		local list = iup.flatlist({ "one", "two", RASTERSIZE = "160x60" })
		iup.SetHandle("DROPLIST", list)
		local shown = {}
		local b = iup.dropbutton({ TITLE = "pick", DROPCHILD = "DROPLIST", RASTERSIZE = "180x26", DROPONARROW = "NO",
			dropshow_cb = function(_, s) shown[#shown + 1] = s end })
		iup.Show(iup.dialog({ iup.vbox({ b }), RASTERSIZE = "300x200" }))
		R.frame()
		B.queue({ mx = 20, my = 10 }); R.frame()
		B.queue({ press = 1 }); R.frame()
		B.queue({ release = 1 }); R.frame()
		assert.equal("YES", iup.GetAttribute(b, "SHOWDROPDOWN"))
		assert.equal(1, #R.overlays())
		local ls = Element.state(list)
		assert.equal(26, ls.y)
		iup.SetAttribute(b, "SHOWDROPDOWN", "NO")
		assert.equal(0, #R.overlays())
		assert.same({ 1, 0 }, shown)
	end)

	it("fires FLAT_ACTION from the button part when DROPONARROW", function()
		local acted = 0
		local list = iup.flatlist({ "a" })
		iup.SetHandle("DROPLIST2", list)
		local b = iup.dropbutton({ TITLE = "go", DROPCHILD = "DROPLIST2", RASTERSIZE = "180x26",
			flat_action = function() acted = acted + 1 end })
		iup.Show(iup.dialog({ iup.vbox({ b }), RASTERSIZE = "300x200" }))
		R.frame()
		B.queue({ mx = 20, my = 10 }); R.frame()
		B.queue({ press = 1 }); R.frame()
		B.queue({ release = 1 }); R.frame()
		assert.equal(1, acted)
		assert.equal(0, #R.overlays())
	end)
end)
