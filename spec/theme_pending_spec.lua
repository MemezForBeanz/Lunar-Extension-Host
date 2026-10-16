-- ThemeManager re-themes new subtrees on a short timer, so a widget can be
-- destroyed between being queued and being themed (TabGroups drops a group strip
-- it created moments earlier once it ends up empty). The flush must skip it:
-- iuplua raises on any use of a destroyed handle, and that surfaced as a Lua
-- error dialog at startup.

local ThemeManager = require("core.classes.ThemeManager")

describe("ThemeManager pending subtrees", function()
	it("skips a widget destroyed before the flush and themes the rest", function()
		local dead, live = { dead = true }, { dead = false }
		local iup = {
			GetClassName = function(w)
				if w.dead then error("bad argument #1 (destroyed handle)") end
				return "flattabs"
			end,
			Refresh = function() end,
		}
		local mgr = setmetatable({
			_iup = iup, _active = {}, _root = {}, _pending_full = false,
			_pending_subtrees = { dead, live },
		}, { __index = ThemeManager })
		local themed = {}
		mgr._beginPaintBatch = function() end
		mgr._endPaintBatch = function() end
		mgr._repaintSubtree = function(_, w) themed[#themed + 1] = w end

		assert.has_no.errors(function() mgr:_flushPending() end)
		assert.are.same({ live }, themed)
	end)
end)
