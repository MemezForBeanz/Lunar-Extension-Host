package.loaded["core.imgui.Fonts"] = {
	forElement = function()
		return {
			charsize = function() return 8, 16 end,
			measure = function(_, text) return #(text or "") * 8, 16 end,
		}
	end,
}

local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")

Classes.define({
	name = "testleaf",
	children = 0,
	natural = function() return 50, 20 end,
})

local function leaf(attrs)
	local init = attrs or {}
	return Element.new("testleaf", init)
end
local function box(name, children, attrs)
	local init = attrs or {}
	for i = 1, #children do init[i] = children[i] end
	return Element.new(name, init)
end
local function run(root, w, h)
	Layout.run(root, w, h)
	return Element.state(root)
end

describe("core.imgui.Layout", function()
	it("measures hbox and vbox gaps and margins without inheritance", function()
		local inner = box("hbox", { leaf(), leaf() }, { GAP = "3", MARGIN = "2x4" })
		local outer = box("vbox", { inner, leaf() }, { GAP = "5", MARGIN = "1x2" })
		local w, h = Layout.natural(outer)
		assert.are.equal(109, w)
		assert.are.equal(57, h)
	end)

	it("splits the extra space equally among expanding children, dropping the remainder as IUP does", function()
		local a = leaf({ EXPAND = "HORIZONTAL" })
		local b = leaf({ EXPAND = "HORIZONTAL" })
		local root = box("hbox", { a, b })
		run(root, 103, 20)
		assert.are.equal(51, Element.state(a).w) -- 50 + floor(3 / 2)
		assert.are.equal(51, Element.state(b).w)
		assert.are.equal(51, Element.state(b).x)
	end)

	it("supports alignment and homogeneous boxes", function()
		local root = box("vbox", { leaf(), leaf() }, { ALIGNMENT = "ARIGHT", HOMOGENEOUS = "YES" })
		run(root, 100, 80)
		assert.are.equal(50, Element.state(Element.state(root).children[1]).w)
		assert.are.equal(50, Element.state(Element.state(root).children[1]).x)
		-- a homogeneous slot is 40 tall, but a child that does not expand keeps its natural height
		assert.are.equal(20, Element.state(Element.state(root).children[1]).h)
		assert.are.equal(40, Element.state(Element.state(root).children[2]).y)
	end)

	it("expands fill only in its parent direction", function()
		local hfill = Element.new("fill")
		local hroot = box("hbox", { hfill })
		run(hroot, 80, 20)
		assert.are.equal(80, Element.state(hfill).w)
		assert.are.equal(0, Element.state(hfill).h)
		local vfill = Element.new("fill")
		local vroot = box("vbox", { vfill })
		run(vroot, 20, 80)
		assert.are.equal(80, Element.state(vfill).h)
	end)

	it("applies SIZE, RASTERSIZE, minimum and maximum dimensions", function()
		local a = leaf({ SIZE = "10x2", MINSIZE = "90x30", MAXSIZE = "95x35" })
		local b = leaf({ RASTERSIZE = "12x40" })
		local root = box("hbox", { a, b })
		local w, h = Layout.natural(root)
		assert.are.equal(102, w)
		assert.are.equal(40, h)
	end)

	it("sizes a zbox to all its children (CHILDSIZEALL, registered Yes) or the current one, and paints only VALUE", function()
		local a, b = leaf({ NAME = "a" }), leaf({ NAME = "b", RASTERSIZE = "90x30" })
		local root = box("zbox", { a, b }, { VALUE = "a" })
		run(root, 100, 40)
		assert.are.equal(90, Element.state(root).nat_w)
		Element.setAttribute(root, "CHILDSIZEALL", "NO")
		run(root, 100, 40)
		assert.are.equal(50, Element.state(root).nat_w)
		local current = Element.state(root).class.visibleChildren(root, Element.state(root))
		assert.are.equal(1, #current)
		assert.are.equal(a, current[1])
	end)

	it("keeps floating children out of box measurement and gives back expandable content", function()
		local a = leaf({ EXPAND = "HORIZONTAL" })
		local b = leaf({ FLOATING = "YES" })
		local root = box("hbox", { a, b })
		local w = Layout.natural(root)
		assert.are.equal(50, w)
		run(root, 30, 20)
		-- without SHRINK a box never goes below its natural size
		assert.are.equal(50, Element.state(a).w)
		assert.are.equal(0, Element.state(b).x)
	end)

	it("places cbox children at CX and CY", function()
		local child = leaf({ CX = "7", CY = "9" })
		local root = box("cbox", { child })
		run(root, 100, 100)
		assert.are.equal(7, Element.state(child).x)
		assert.are.equal(9, Element.state(child).y)
	end)
end)
