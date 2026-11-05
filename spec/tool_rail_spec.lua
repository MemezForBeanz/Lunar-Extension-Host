local ToolRail = require("core.ui.ToolRail")

describe("core.ui.ToolRail", function()
	describe("isNarrow", function()
		it("is wide in a wide pane unless the user collapsed it", function()
			assert.is_false(ToolRail.isNarrow(false, 1920))
			assert.is_true(ToolRail.isNarrow(true, 1920))
		end)

		it("is narrow in a thin pane whatever the user chose", function()
			assert.is_true(ToolRail.isNarrow(false, 1279))
			assert.is_false(ToolRail.isNarrow(false, 1280))
			assert.is_true(ToolRail.isNarrow(false, nil))
		end)
	end)

	describe("press", function()
		local function rail()
			local calls = {}
			local settings = { saved = {}, get = function(s, k) return s.saved[k] end,
				set = function(s, k, v) s.saved[k] = v end, save = function() calls.saved = true end }
			local groups = {
				rootOf = function() return "root" end,
				_newGroup = function(_, strip) calls.new = strip end,
			}
			local panes = { toggleFocus = function(_, strip) calls.focus = strip end }
			local r = ToolRail.new({ iup = {}, groups = groups, panes = panes, settings = settings })
			r.refresh = function() calls.refreshed = true end
			return r, calls, settings
		end

		it("adds a group at the top of the pane the rail belongs to", function()
			local r, calls = rail()
			assert.is_true(r:press("strip", 1))
			assert.equal("root", calls.new)
		end)

		it("focuses the rail's own pane", function()
			local r, calls = rail()
			r:press("strip", 2)
			assert.equal("strip", calls.focus)
		end)

		it("remembers a collapse", function()
			local r, calls, settings = rail()
			r:press("strip", 3)
			assert.is_true(settings.saved.tool_rail_collapsed)
			assert.is_true(calls.saved and calls.refreshed)
		end)

		it("leaves other buttons alone", function()
			local r = rail()
			assert.is_false(r:press("strip", 5))
		end)
	end)
end)
