local Fullscreen = require("core.ui.Fullscreen")

describe("Fullscreen", function()
	it("changes the real dialog mode and restores the active tab on exit", function()
		local attrs = {
			dialog = { FULLSCREEN = "NO", MAXIMIZED = "YES", PLACEMENT = "MAXIMIZED" },
			tabs = { VALUEPOS = "2" },
		}
		local iup = { K_ESC = 27 }
		function iup.GetAttribute(widget, name)
			for key, value in pairs(attrs) do
				if widget == key then return value[name] end
			end
		end
		function iup.SetAttribute(widget, name, value)
			for key, values in pairs(attrs) do
				if widget == key then values[name] = value end
			end
		end
		local escape, removed
		local ctx = {
			registerShortcut = function(_, key, fn)
				escape = { key = key, fn = fn }
				return escape
			end,
			unregisterShortcut = function(_, entry) removed = entry end,
		}
		local tabs = "tabs"
		local controller = Fullscreen.new({
			iup = iup, dialog = "dialog", tabs = tabs, context = ctx, owner = {},
		})

		assert.is_true(controller.enter())
		assert.equals("YES", attrs.dialog.FULLSCREEN)
		assert.is_true(controller.active())
		assert.equals(27, escape.key)
		attrs.tabs.VALUEPOS = "1"
		escape.fn()
		assert.equals("NO", attrs.dialog.FULLSCREEN)
		assert.equals("2", attrs.tabs.VALUEPOS)
		assert.equals(escape, removed)
		assert.is_false(controller.active())
		assert.equals("MAXIMIZED", attrs.dialog.PLACEMENT)
	end)

	it("does not toggle a missing dialog", function()
		local controller = Fullscreen.new({ iup = {}, dialog = nil })
		assert.is_false(controller.toggle())
		assert.is_false(controller.active())
	end)
end)
