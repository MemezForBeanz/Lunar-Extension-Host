local Null = require("core.imgui.backend.Null")
local Runtime = require("core.imgui.Runtime")
local iup = require("core.imgui.iup")

describe("ImGui tray bridge", function()
	local B
	before_each(function()
		B = Null.new()
		Runtime.init(B)
	end)

	it("forwards IUP tray attributes and click arguments", function()
		local got
		local dlg = iup.dialog{ iup.label{ TITLE = "body" },
			TRAY = "YES", TRAYTIP = "Lunar", TRAYTIPBALLOONTITLE = "Title",
			trayclick_cb = function(_, button, pressed, double)
				got = { button, pressed, double }
			end }
		iup.Show(dlg)
		assert.is_true(B.tray)
		assert.equals("Lunar", B.tray_tip)
		B.injectTray(3, 1, true)
		Runtime.frame()
		assert.same({ 3, 1, 1 }, got)
		iup.Destroy(dlg)
	end)

	it("keeps the tray active while the main dialog is hidden and restores it", function()
		local dlg = iup.dialog{ iup.label{ TITLE = "body" }, TRAY = "YES" }
		iup.Show(dlg)
		iup.Hide(dlg)
		assert.is_true(B.tray)
		assert.is_false(B.visible)
		iup.Show(dlg)
		assert.is_true(B.visible)
		iup.Destroy(dlg)
	end)
end)
