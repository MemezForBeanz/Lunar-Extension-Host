local CellGrid = require("core.ui.CellGrid")

describe("CellGrid", function()
	local attrs, bound, iup, raw
	before_each(function()
		attrs, bound = {}, nil
		iup = {
			SetAttribute = function(_, k, v) attrs[k] = v end,
			GetAttribute = function(_, k) return attrs[k] end,
			Update = function() end,
		}
		raw = {
			flatgrid = function() return {} end,
			bindgrid = function(_, callbacks) bound = callbacks end,
		}
	end)

	it("reads a plain item table by lowercase field", function()
		CellGrid.new(iup, { raw = raw, items = { { title = "Alien", badge = "4K", progress = 40, state = "unplayed" } } })
		assert.equals("1", attrs.COUNT)
		assert.equals("Alien", bound.value(1, "TITLE"))
		assert.equals("4K", bound.value(1, "BADGE"))
		assert.equals(40, bound.value(1, "PROGRESS"))
		assert.equals("unplayed", bound.value(1, "STATE"))
		assert.is_nil(bound.value(2, "TITLE"))
	end)

	it("asks a provider, and stops when given plain items again", function()
		local grid = CellGrid.new(iup, { raw = raw, count = 100000, value = function(pos, field) return field .. pos end })
		assert.equals("100000", attrs.COUNT)
		assert.equals("TITLE7", bound.value(7, "TITLE"))
		grid:setItems({ { title = "One" } })
		assert.equals("1", attrs.COUNT)
		assert.equals("One", bound.value(1, "TITLE"))
	end)

	it("sets a vertical grid by default and a shelf when asked", function()
		CellGrid.new(iup, { raw = raw })
		assert.equals("VERTICAL", attrs.ORIENTATION)
		assert.equals("VERTICAL", attrs.FLATSCROLLBAR)
		CellGrid.new(iup, { raw = raw, shelf = true, aspect = "16:9", cell_width = 240 })
		assert.equals("HORIZONTAL", attrs.ORIENTATION)
		assert.equals("HORIZONTAL", attrs.FLATSCROLLBAR)
		assert.equals("1", attrs.ROWS)
		assert.equals("16:9", attrs.ASPECT)
		assert.equals("240", attrs.CELLWIDTH)
		CellGrid.new(iup, { raw = raw, rows = 2 })
		assert.equals("HORIZONTAL", attrs.ORIENTATION)
		assert.equals("2", attrs.ROWS)
	end)

	it("turns a selection mask into positions", function()
		assert.same({ 1, 3, 4 }, CellGrid.parseMask("+-++-"))
		assert.same({}, CellGrid.parseMask("---"))
		assert.same({}, CellGrid.parseMask(nil))
	end)

	it("reports the range in view", function()
		local grid = CellGrid.new(iup, { raw = raw })
		attrs.VISIBLERANGE = "29:56"
		assert.same({ 29, 56 }, { grid:visibleRange() })
		attrs.VISIBLERANGE = nil
		assert.same({ 0, 0 }, { grid:visibleRange() })
	end)

	it("names a poster by image and cell size, and asks once for a miss", function()
		local cache = { asked = {}, ready = {}, finished = {} }
		function cache:get(key) local p = self.ready[key]; if p then return p, 400 end end
		function cache:request(key, path, w, h) self.asked[#self.asked + 1] = { key, path, w, h } end
		function cache:drain() local f = self.finished; self.finished = {}; return f end
		local grid = CellGrid.new(iup, { raw = raw })
		CellGrid.posters(grid, cache, function(pos) return pos == 1 and "a.jpg" or nil end)
		assert.is_nil(bound.bits(1, 150, 225))
		assert.same({ "a.jpg@150x225", "a.jpg", 150, 225 }, cache.asked[1])
		assert.is_nil(bound.bits(2, 150, 225))
		assert.equals(1, #cache.asked)
		cache.ready["a.jpg@150x225"] = "pixels"
		local pixels, stride = bound.bits(1, 150, 225)
		assert.equals("pixels", pixels)
		assert.equals(400, stride)
	end)

	it("repaints only the cells whose posters arrived", function()
		local cache = { finished = {} }
		function cache:get() end
		function cache:request() end
		function cache:drain() local f = self.finished; self.finished = {}; return f end
		local grid = CellGrid.new(iup, { raw = raw })
		local drain = CellGrid.posters(grid, cache, function(pos) return "p" .. pos end)
		bound.bits(5, 10, 15)
		cache.finished = { "p5@10x15", "unknown@1x1" }
		assert.equals(2, drain())
		assert.equals("5", attrs.REDRAWCELL)
		attrs.REDRAWCELL = nil
		cache.finished = { "p5@10x15" }
		drain()
		assert.is_nil(attrs.REDRAWCELL)
	end)

	it("passes image bytes to the cache under their own id", function()
		local cache = { bytes = {} }
		function cache:get() end
		function cache:requestBytes(key, data, w, h) self.bytes[#self.bytes + 1] = { key, data, w, h } end
		function cache:drain() return {} end
		local grid = CellGrid.new(iup, { raw = raw })
		CellGrid.posters(grid, cache, function() return { bytes = "jpeg", id = "film9" } end)
		bound.bits(1, 10, 15)
		assert.same({ "film9@10x15", "jpeg", 10, 15 }, cache.bytes[1])
	end)

	it('does not retain a discarded grid while its poster cache stays alive', function()
		local cache = { get = function() end, request = function() end, drain = function() return {} end }
		local weak = setmetatable({}, {__mode = 'v'})
		do
			local grid = {refreshCell = function() end}
			CellGrid.posters(grid, cache, function() return 'poster.jpg' end)
			weak[1] = grid
		end
		collectgarbage('collect'); collectgarbage('collect')
		assert.is_nil(weak[1])
		assert.equal(0, #cache:drain())
	end)

	it('keeps a live subscriber working after another subscriber is collected', function()
		local cache = {finished = {}, get = function() end, request = function() end}
		function cache:drain() local result = self.finished; self.finished = {}; return result end
		do local discarded = {}; CellGrid.posters(discarded, cache, function() return 'gone.jpg' end) end
		local seen
		local grid = {refreshCell = function(_, pos) seen = pos end}
		local drain = CellGrid.posters(grid, cache, function() return 'live.jpg' end)
		grid.bits(7, 10, 15)
		collectgarbage('collect'); collectgarbage('collect')
		cache.finished = {'live.jpg@10x15'}
		drain()
		assert.equal(7, seen)
	end)
end)
