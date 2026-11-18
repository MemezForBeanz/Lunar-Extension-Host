local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Groups = require("core.classes.TabGroups")
local Order = require("core.classes.TabOrder")
local View = require("core.ui.TabStripView")
local Tabs = require("core.imgui.widgets.flattabs")

describe("group toolbar switching", function()
	it("persists icon-only group labels and keeps the full name as a tooltip", function()
		R.init(Null.new())
		local root = iup.flattabs{}
		local groups = Groups:new{ iup = iup, root_strip = root }
		local group = groups:createGroup(root, "Tools")
		groups:setIconOnly(group, true)
		assert.equal("T", iup.GetAttributeId(root, "TABTITLE", 0))
		assert.equal("Tools", iup.GetAttributeId(root, "TABTIP", 0))
		assert.is_true(groups:serialize().children[1].icon_only)
		E.state(root).data.hover = 0
		assert.equal("Tools", iup.GetAttribute(root, "TIP"))
		local restored = iup.flattabs{}
		local other = Groups:new{ iup = iup, root_strip = restored }
		other:_restoreInto(restored, groups:serialize().children, {}, 0, {})
		assert.is_true(other:isIconOnly(iup.GetChild(restored, 0)))
		iup.SetAttribute(group, "TABIMAGE", "group-icon")
		groups:_syncTitles(root)
		assert.equal("", iup.GetAttributeId(root, "TABTITLE", 0))
		groups:setIconOnly(group, false)
		assert.equal("Tools", iup.GetAttributeId(root, "TABTITLE", 0))
	end)
	it("keeps group identity and children aligned through repeated clicks and double clicks", function()
		R.init(Null.new())
		local root = iup.flattabs{}
		local order = Order:new{ iup = iup }
		local groups = Groups:new{ iup = iup, root_strip = root, on_strip_created = function(s) order:install(s) end }
		order:setGroups(groups)
		local a = groups:createGroup(root, "HPE")
		local b = groups:createGroup(root, "Microchip")
		local aa, bb = iup.vbox{ TABTITLE = "Log Parser" }, iup.vbox{ TABTITLE = "Black Duck" }
		iup.Append(a, aa); iup.Append(b, bb)
		local strip = iup.flattabs{ TABTYPE = "LEFT", TABSBREADTH = "48" }
		local view = View.new{ iup = iup, root = root, strip = strip }
		view:setOrder(order); order:setStandIn(root, strip, "left")
		local function sync() view:sync(groups:_children(root)) end
		root.tabchange_cb = sync
		sync()
		local st = E.state(strip); st.x, st.y, st.w, st.h = 0, 0, 48, 240
		local function click(pos, double)
			local rect = Tabs.headerRects(strip)[pos + 1]
			local x, y = rect.x + 12, rect.y + 8
			R.deliver(strip, { type = "press", button = 1, x = x, y = y, status = iup._status{ double = double } })
			R.deliver(strip, { type = "release", button = 1, x = x, y = y })
		end
		for n = 1, 12 do
			local pos = n % 2
			click(pos)
			assert.equal(pos == 0 and a or b, iup.GetAttributeHandle(root, "VALUE_HANDLE"))
			assert.equal(tostring(pos), iup.GetAttribute(strip, "VALUEPOS"))
			assert.equal(aa, iup.GetChild(a, 0)); assert.equal(bb, iup.GetChild(b, 0))
		end
		click(0, true)
		assert.is_true(groups:isCollapsed(a))
		click(0, true)
		assert.is_false(groups:isCollapsed(a))
	end)
end)
