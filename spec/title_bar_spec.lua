local TitleBar = require("core.ui.TitleBar")
describe("core.ui.TitleBar layout", function()
	it("measures the group area before the centred command field is reserved", function()
		assert.is_true(TitleBar.layout(1920, 138).groups > 1500)
	end)
	it("reserves native window buttons and a caption drag area", function()
		for width = 480, 1920, 40 do
			local lay = TitleBar.layout(width, 138, 5000)
			assert.is_true(lay.left <= width - 138 - 80)
		end
	end)
	it("keeps short tab lists at their natural width", function()
		assert.equal(200, TitleBar.layout(1920, 138, 200).groups)
	end)
	it("never returns negative space in a narrow window", function()
		assert.equal(0, TitleBar.layout(180, 138, 100).groups)
	end)
end)

describe("TitleBar command field", function()
 it("gives tabs priority and collapses search before they collide", function()
  assert.equal(32,TitleBar.commandWidth(1100,138,650))
  assert.is_true(TitleBar.commandWidth(1100,138,400) < 367)
  local iup = require("core.lui.test").boot({})
  local bar = TitleBar.new({iup=iup,root=iup.flattabs{},icon=function() end})
  bar._tabs_width=800;bar:fit(1100)
  assert.equal("32x28",iup.GetAttribute(bar:commandWidget(),"RASTERSIZE"))
  assert.equal("",iup.GetAttribute(bar._command,"TITLE"))
  assert.equal("NO",iup.GetAttribute(bar._shortcut,"VISIBLE"))
  bar:fit(1920)
  assert.equal("Search or run a command",iup.GetAttribute(bar._command,"TITLE"))
 end)
 it("collapses the same way in every theme, whatever the tab font measures", function()
  -- narrow tab fonts (Segoe) and wide ones (Plex) both get the icon at 1100 px
  for _, tabs in ipairs({ 300, 420, 520 }) do
   assert.equal(32, TitleBar.commandWidth(1100, 138, tabs))
  end
 end)
 it("never lets the field take the room the tabs and their + measured", function()
  for width = 1200, 1920, 20 do
   for tabs = 200, 900, 50 do
    local field = TitleBar.commandWidth(width, 138, tabs)
    if field > 32 then
     assert.equal(tabs, TitleBar.layout(width - field, 138, tabs).groups)
    end
   end
  end
 end)
 it("keeps search bounded and opens the command callback", function()
  local iup = require("core.lui.test").boot({})
  local root = iup.flattabs({})
  local bar = TitleBar.new({iup=iup,root=root,icon=function() end})
  bar:fit(1920)
  assert.equal("480x28",iup.GetAttribute(bar:commandWidget(),"RASTERSIZE"))
  assert.equal("NO",iup.GetAttribute(bar:commandWidget(),"EXPAND"))
  local called=false;bar:onCommand(function() called=true end)
  bar._command:flat_action();assert.is_true(called)
 end)
end)


describe("TitleBar image measurement", function()
	it("adds actual image width and configured spacing", function()
		local images = false
		local iup = {
			GetAttribute = function(w, key) return w[key] end,
			GetAttributeId = function(_, key) return key == "TABTITLE" and "Tools" or (images and "mark" or nil) end,
			GetHandle = function() return { WIDTH = "20" } end,
		}
		local bar = setmetatable({ _iup = iup, _root = {}, _groups = { TABSPADDING = "12x4", TABSIMAGESPACING = "7" } }, TitleBar)
		bar:_measureTabs({ {} }, {})
		local before = bar._tabs_width
		images = true
		bar:_measureTabs({ {} }, {})
		assert.equal(before + 27, bar._tabs_width)
	end)
end)
