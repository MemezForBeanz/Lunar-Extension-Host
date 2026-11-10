local Null = require("core.imgui.backend.Null")
local Runtime = require("core.imgui.Runtime")
local iup = require("core.imgui.iup")

describe("ImGui video host", function()
	local B
	before_each(function()
		B = Null.new({ w = 640, h = 480 })
		Runtime.init(B)
	end)

	it("creates a child surface, reports its id, and follows placement", function()
		local host = iup.videohost{ BGCOLOR = "1 2 3" }
		local dlg = iup.dialog{ iup.vbox{ host }, RASTERSIZE = "640x480" }
		iup.Show(dlg)
		Runtime.frame()
		local id = iup.GetAttribute(host, "WINDOWID")
		assert.is_truthy(id)
		assert.equals(id, iup.GetAttribute(host, "WID"))
		local child = B.video_hosts[tonumber(id)]
		assert.is_true(child.visible)
		assert.same({ x = 0, y = 0, w = 640, h = 480 }, child.rect)
		iup.Hide(dlg)
		assert.is_false(child.visible)
		iup.Show(dlg)
		Runtime.frame()
		assert.is_true(child.visible)
		iup.Destroy(dlg)
		assert.is_nil(B.video_hosts[tonumber(id)])
	end)
end)
