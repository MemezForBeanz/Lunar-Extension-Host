local PaneGrid = require("core.classes.PaneGrid")
local SplitMotion = require("core.lib.SplitMotion")

describe("PaneGrid geometry", function()
	local none = {}

	it("treats the outer quarter of the grid as a split target", function()
		assert.equals("right", PaneGrid.zoneAt(0.9, 0.3, none))
		assert.equals("bottom", PaneGrid.zoneAt(0.3, 0.9, none))
		assert.equals("corner", PaneGrid.zoneAt(0.9, 0.9, none))
	end)

	it("answers nil outside the grid", function()
		assert.is_nil(PaneGrid.zoneAt(1.2, 0.5, none))
		assert.is_nil(PaneGrid.zoneAt(0.5, -0.1, none))
	end)

	it("answers the pane under the pointer in the middle", function()
		assert.equals("main", PaneGrid.zoneAt(0.4, 0.4, { right = true }, 0.5))
		assert.equals("right", PaneGrid.zoneAt(0.6, 0.4, { right = true }, 0.5))
	end)

	it("follows the sash when it decides which side the pointer is on", function()
		assert.equals("main", PaneGrid.zoneAt(0.6, 0.4, { right = true }, 0.7))
	end)

	local rect = { x = 10, y = 20, w = 1000, h = 600 }

	it("previews the right half for a first split", function()
		assert.same({ x = 510, y = 20, w = 500, h = 600 }, PaneGrid.zoneRect("right", rect, {}))
	end)

	it("previews a full-width lower half when nothing is on the right", function()
		assert.same({ x = 10, y = 320, w = 1000, h = 300 }, PaneGrid.zoneRect("bottom", rect, {}))
	end)

	it("previews a quadrant for the corner", function()
		assert.same({ x = 510, y = 320, w = 500, h = 300 }, PaneGrid.zoneRect("corner", rect, {}))
	end)

	it("keeps the main preview to its half when a right pane exists", function()
		assert.same({ x = 10, y = 20, w = 500, h = 600 }, PaneGrid.zoneRect("main", rect, { right = true }))
	end)
end)

describe("SplitMotion.snap", function()
	it("pulls a value near a snap point onto it", function()
		assert.equals(500, SplitMotion.snap(493))
		assert.equals(333, SplitMotion.snap(340))
	end)

	it("leaves everything else alone", function()
		assert.equals(420, SplitMotion.snap(420))
	end)
end)

describe("PaneGrid:sync", function()
	-- IupSplit crops VALUE to MINMAX at the moment VALUE is set, and widening MINMAX later
	-- does not give the lost range back. The mock keeps that, because it decides the order
	-- PaneGrid has to set them in.
	local function fake_iup()
		local iup = { BUTTON1 = 1 }
		function iup.flattabs() return { kind = "tabs", attrs = {} } end
		function iup.split(spec)
			return { kind = "split", attrs = {}, min = 0, max = 1000, val = tonumber(spec.VALUE) }
		end
		function iup.SetAttribute(w, name, value)
			if w.kind == "split" and name == "MINMAX" then
				w.min, w.max = tostring(value):match("(%d+):(%d+)")
				w.min, w.max = tonumber(w.min), tonumber(w.max)
				w.val = math.max(w.min, math.min(w.max, w.val))
			elseif w.kind == "split" and name == "VALUE" then
				w.val = math.max(w.min, math.min(w.max, tonumber(value)))
			else
				w.attrs[name] = value
			end
		end
		function iup.GetAttribute(w, name)
			if w.kind == "split" and name == "VALUE" then return tostring(w.val) end
			return w.attrs[name]
		end
		return iup
	end

	local function grid_with(counts)
		local iup = fake_iup()
		local grid = PaneGrid:new({ iup = iup, main = iup.flattabs() })
		grid._groups = {
			_children = function(_, strip)
				for zone, s in pairs(grid._strips) do
					if s == strip then return counts[zone] or {} end
				end
				return {}
			end,
		}
		return grid
	end

	it("gives the main pane the whole width back when the right pane empties", function()
		local counts = { right = { "page" } }
		local grid = grid_with(counts)
		grid:sync()
		assert.equals(500, grid._grid.val)

		counts.right = {}
		grid:sync()
		assert.equals(1000, grid._grid.val)
	end)

	it("gives the main pane the whole height back when the bottom pane empties", function()
		local counts = { bottom = { "page" } }
		local grid = grid_with(counts)
		grid:sync()
		counts.bottom = {}
		grid:sync()
		assert.equals(1000, grid._left.val)
	end)
end)
