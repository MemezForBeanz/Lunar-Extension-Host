local SeekBar = require("core.ui.SeekBar")

describe("SeekBar", function()
	local attrs, bound, iup, raw
	before_each(function()
		attrs, bound = {}, nil
		iup = {
			SetAttribute = function(_, k, v) attrs[k] = v end,
			GetAttribute = function(_, k) return attrs[k] end,
		}
		raw = {
			flatseek = function() return {} end,
			bindseek = function(_, callbacks) bound = callbacks end,
		}
	end)

	it("sets its length and place", function()
		local bar = SeekBar.new(iup, { raw = raw, max = 5400, value = 60, step = 10, page_step = 60 })
		assert.equals("5400", attrs.MAX)
		assert.equals("60", attrs.VALUE)
		assert.equals("10", attrs.STEP)
		assert.equals("60", attrs.PAGESTEP)
		bar:setValue(61)
		assert.equals(61, bar:value())
	end)

	it("writes buffered ranges and marks in the control's format", function()
		assert.equals("0.000-120.500,300.000-360.000", SeekBar.formatRanges({ { 0, 120.5 }, { 300, 360 } }))
		assert.equals("95.000-180.000,1200.000", SeekBar.formatMarks({ { at = 95, to = 180 }, { at = 1200 } }))
		assert.equals("", SeekBar.formatRanges(nil))
		local bar = SeekBar.new(iup, { raw = raw })
		bar:setBuffered({ { 1, 2 } })
		bar:setMarks({ { at = 3 } })
		assert.equals("1.000-2.000", attrs.BUFFERED)
		assert.equals("3.000", attrs.MARKS)
	end)

	it("skips unchanged native writes but restores a value changed by dragging", function()
		local writes = 0
		iup.SetAttribute = function(_, k, v) attrs[k] = v; writes = writes + 1 end
		local bar = SeekBar.new(iup, { raw = raw, max = 5400, value = 60 })
		bar:setMarks({ { at = 90 } })
		local initial = writes
		attrs.VALUE = "60.000000"
		for _ = 1, 100 do
			bar:setValue(60)
			bar:setMax(5400)
			bar:setMarks({ { at = 90 } })
		end
		assert.equals(initial, writes)
		attrs.VALUE = "80.000000"
		bar:setValue(60)
		assert.equals(initial + 1, writes)
		assert.equals(60, bar:value())
	end)

	it("hands a seek its value alone, and a hover its position too", function()
		local seen, hovered = {}, {}
		SeekBar.new(iup, { raw = raw,
			on_seek = function(...) seen = { n = select("#", ...), ... } end,
			on_hover = function(value, x) hovered = { value, x } end,
		})
		bound.seek(12.5, 0)
		assert.equals(1, seen.n)
		assert.equals(12.5, seen[1])
		bound.hover(30, 200)
		assert.same({ 30, 200 }, hovered)
	end)
end)
