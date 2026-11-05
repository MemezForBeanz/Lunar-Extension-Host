local Adaptive = require("core.ui.Adaptive")
local Kit = require("core.ui.Kit")

-- Just enough of a widget tree for a layout to move through.
local function fake_iup()
	local iup = {}
	local function box(kind)
		return function(attrs)
			attrs.kind, attrs.kids = kind, {}
			for _, kid in ipairs(attrs) do
				attrs.kids[#attrs.kids + 1] = kid
				kid.parent = attrs
			end
			return attrs
		end
	end
	iup.hbox, iup.vbox = box("hbox"), box("vbox")
	iup.SetAttribute = function(w, k, v) w[k] = v end
	iup.GetAttribute = function(w, k) return w[k] end
	iup.ResetAttribute = function(w, k) w[k] = nil end
	iup.Refresh = function() end
	iup.GetChild = function(w, i) return w.kids and w.kids[i + 1] end
	iup.GetParent = function(w) return w.parent end
	iup.Reparent = function(w, parent, ref)
		for i, kid in ipairs(w.parent.kids) do
			if kid == w then table.remove(w.parent.kids, i) break end
		end
		local at = #parent.kids + 1
		for i, kid in ipairs(parent.kids) do
			if kid == ref then at = i break end
		end
		table.insert(parent.kids, at, w)
		w.parent = parent
		return 0
	end
	return iup
end

local function names(box)
	local out = {}
	for _, kid in ipairs(box.kids) do out[#out + 1] = kid.name or kid.kind end
	return table.concat(out, " ")
end

describe("Adaptive.railPage", function()
	local iup, side, main, page, fit
	before_each(function()
		iup = fake_iup()
		side, main = { name = "side" }, { name = "main" }
		page, fit = Adaptive.railPage(iup, { side = side, main = main, side_expand = "YES" })
	end)

	it("keeps the rail beside the work while there is room", function()
		fit(Adaptive.NARROW)
		assert.equals("hbox", names(page))
		assert.equals(main, page.kids[1].kids[2])
	end)

	it("stacks in a narrow pane, rail first, and drops the fixed width", function()
		fit(Adaptive.NARROW - 1)
		local rail = page.kids[1]
		assert.equals(side, rail.kids[2])
		assert.equals(main, page.kids[2])
		assert.equals("YES", rail.EXPAND)
		assert.equals("1x0", rail.kids[1].RASTERSIZE)
		assert.equals("YES", page.kids[3].FLOATING)
	end)

	it("goes back when the pane widens", function()
		fit(600)
		fit(1200)
		assert.equals("hbox", names(page))
		assert.equals(main, page.kids[1].kids[2])
		assert.equals("320x0", page.kids[1].kids[1].kids[1].RASTERSIZE)
		assert.equals("VERTICAL", page.kids[1].kids[1].EXPAND)
	end)
end)

describe("Adaptive.setSecondPane", function()
	it("hides the pane and its sash, and gives the room to the first", function()
		local iup = fake_iup()
		local sash, second = { name = "sash" }, { name = "second" }
		local split = iup.vbox({ sash, { name = "first" }, second })
		local anchor = { VISIBLE = "YES" }
		Adaptive.setSecondPane(iup, split, second, false, 700, anchor)
		assert.equals("1000", split.VALUE)
		assert.equals("YES", second.FLOATING)
		assert.equals("YES", sash.FLOATING)
		Adaptive.setSecondPane(iup, split, second, true, 700, anchor)
		assert.equals("700", split.VALUE)
		assert.equals("NO", second.FLOATING)
		assert.equals("NO", sash.FLOATING)
	end)
end)

describe("Kit.show", function()
	it("leaves a hidden part hidden when the box around it is shown", function()
		local iup = fake_iup()
		local hidden, plain = { name = "hidden" }, { name = "plain" }
		local box = iup.vbox({ hidden, plain })
		Kit.show(iup, hidden, false)
		Kit.show(iup, box, false)
		-- IUP clears an inheritable attribute all the way down; so does this.
		iup.ResetAttribute = function(w, k)
			w[k] = nil
			for _, kid in ipairs(w.kids or {}) do kid[k] = nil end
		end
		Kit.show(iup, box, true, { VISIBLE = "YES" })
		assert.equals("NO", hidden.VISIBLE)
		assert.is_nil(plain.VISIBLE)
	end)
end)
