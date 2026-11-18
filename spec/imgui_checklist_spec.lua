-- core.ui.CheckList on the ImGui host: setItems refills the one flatlist whatever wrote
-- its rows before (REMOVEITEM=ALL clears rows written by id), as on IUP. The Build Queue's
-- tool lists are CheckLists; rows written by id used to survive the refill.
local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local iup = require("core.imgui.iup")
local CheckList = require("core.ui.CheckList")

describe("CheckList on the ImGui host", function()
	before_each(function() R.init(Null.new({ w = 600, h = 400 })) end)

	it("replaces rows written by id when setItems runs", function()
		local list = CheckList:new(iup, { format = function(t) return t.name end, show_checkboxes = false })
		local h = list:widget()
		for i = 1, 20 do iup.SetAttribute(h, tostring(i), "sample " .. i) end
		list:setItems({ { name = "AcpiTables" }, { name = "BootOrder" } })
		assert.equal("2", iup.GetAttribute(h, "COUNT"))
		assert.equal("AcpiTables", iup.GetAttribute(h, "1"))
		assert.is_nil(iup.GetAttribute(h, "3"))
	end)

	it("selects rows with VALUE and reports them back", function()
		local list = CheckList:new(iup, { format = function(t) return t.name end })
		list:setItems({ { name = "a" }, { name = "b" }, { name = "c" } })
		list:_applySelection({ [1] = true, [3] = true })
		assert.same({ 1, 3 }, list:getSelection())
		assert.equal("+-+", iup.GetAttribute(list:widget(), "VALUE"))
	end)

	it("lays out and paints inside a dialog with its flat scroll bar", function()
		local list = CheckList:new(iup, { format = function(t) return t.name end })
		local items = {}
		for i = 1, 60 do items[i] = { name = "tool " .. i } end
		list:setItems(items)
		local dlg = iup.dialog{ iup.vbox{ list:widget() }, RASTERSIZE = "300x200" }
		iup.Show(dlg)
		R.frame(); R.frame()
		local h = list:widget()
		assert.is_true(tonumber(iup.GetAttribute(h, "YMAX")) > tonumber(iup.GetAttribute(h, "DY")))
		assert.equal("YES", iup.GetAttribute(iup.GetChild(h, 0), "VISIBLE"))
		iup.Destroy(dlg)
	end)
end)
