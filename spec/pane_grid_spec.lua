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
