local MenuBar = require("core.ui.MenuBar")

describe("menu bar tab-strip recovery", function()
	it("exposes Show all tab bars under View and dispatches its action", function()
		local function widget(def) return def end
		local iup = { item = widget, menu = widget, submenu = widget, DEFAULT = 0 }
		local called = 0
		local menu, handles = MenuBar.build({
			iup = iup, app_title = "Test", app_version = "1",
			on_show_tab_bars = function() called = called + 1 end,
		})
		assert.equal("View", menu[2].TITLE)
		assert.equal("Show all tab bars", handles.view_menu[1].TITLE)
		assert.equal(iup.DEFAULT, handles.show_tab_bars:action())
		assert.equal(1, called)
	end)
end)
