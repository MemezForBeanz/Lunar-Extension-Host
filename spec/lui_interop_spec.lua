-- core.lui interop with imperative iup code: Native handles, children added by other code,
-- components mounted inside an existing tree, unmount, and the layout coalescing.
local T = require("core.lui.test")
local ui = require("core.lui")

local iup, Runtime
before_each(function() iup, Runtime = T.boot({}) end)

local function classes(box)
	local out = {}
	for i = 0, iup.GetChildCount(box) - 1 do
		local c = iup.GetChild(box, i)
		out[#out + 1] = iup.GetAttribute(c, "TITLE") or iup.GetClassName(c)
	end
	return out
end

describe("lui Native", function()
	it("places an existing handle and never destroys it", function()
		local mine = iup.flatlabel({ TITLE = "native" })
		local root = ui.mount(ui.HBox{ ui.Text{ "a" }, ui.Native{ handle = mine }, ui.Text{ "b" } }, { iup = iup })
		local box = root:widget()
		assert.same({ "a", "native", "b" }, classes(box))
		assert.equal(box, iup.GetParent(mine))
		root:update(ui.HBox{ ui.Text{ "a" }, ui.Text{ "b" } })
		assert.is_true(iup.ihandle(mine), "removed from the tree, not destroyed")
		assert.is_nil(iup.GetParent(mine))
		assert.same({ "a", "b" }, classes(box))
	end)

	it("survives the destruction of the host it was placed in", function()
		local mine = iup.flatlabel({ TITLE = "native" })
		local root = ui.mount(ui.VBox{ ui.HBox{ ui.Native{ handle = mine } } }, { iup = iup })
		local inner = iup.GetChild(root:widget(), 0)
		root:update(ui.VBox{})
		assert.is_false(iup.ihandle(inner))
		assert.is_true(iup.ihandle(mine))
		root:unmount()
		assert.is_true(iup.ihandle(mine))
	end)

	it("never writes the native's attributes", function()
		local mine = iup.flatlabel({ TITLE = "keep" })
		local root = ui.mount(ui.VBox{ ui.Native{ handle = mine, tip = "ignored" } }, { iup = iup })
		root:update(ui.VBox{ ui.Native{ handle = mine, tip = "still ignored" } })
		assert.equal("keep", iup.GetAttribute(mine, "TITLE"))
		assert.is_nil(iup.GetAttribute(mine, "TIP"))
	end)

	it("embeds a bare iup handle given as a child", function()
		local mine = iup.flatlabel({ TITLE = "bare" })
		local root = ui.mount(ui.VBox{ mine }, { iup = iup })
		assert.equal(root:widget(), iup.GetParent(mine))
	end)

	it("hands the handle to a ref", function()
		local mine = iup.flatlabel({})
		local ref = {}
		ui.mount(ui.VBox{ ui.Native{ handle = mine, ref = ref } }, { iup = iup })
		assert.equal(mine, ref.current)
	end)
end)

describe("lui and children added by other code", function()
	it("never touches the children of a host given no component children", function()
		local box_ref, set = {}, nil
		local function Bar()
			local text, s = ui.useState("one")
			set = s
			return ui.HBox{ ui.Text{ text }, ui.HBox{ ref = box_ref, gap = 2, tip = text } }
		end
		local root = ui.mount(Bar, { iup = iup })
		local ext = box_ref.current
		local foreign = iup.flatlabel({ TITLE = "extension" })
		iup.Append(ext, foreign)
		ui.flushSync(function() set("two") end)
		ui.flushSync(function() set("three") end)
		assert.equal(ext, iup.GetParent(foreign))
		assert.same({ "extension" }, classes(ext))
		assert.equal("three", iup.GetAttribute(ext, "TIP"))
		root:unmount()
	end)

	it("leaves foreign siblings in place when its own children change", function()
		local set
		local function C()
			local show, s = ui.useState(false)
			set = s
			return ui.HBox{ ui.Text{ "a" }, show and ui.Text{ "b" } }
		end
		local root = ui.mount(C, { iup = iup })
		local box = root:widget()
		local foreign = iup.flatlabel({ TITLE = "foreign" })
		iup.Append(box, foreign)
		ui.flushSync(function() set(true) end)
		assert.equal(box, iup.GetParent(foreign))
		assert.equal(3, iup.GetChildCount(box))
		ui.flushSync(function() set(false) end)
		assert.same({ "a", "foreign" }, classes(box))
	end)
end)

describe("lui inside an iup tree", function()
	it("gives root:widget() to existing code and keeps it updated", function()
		local set
		local function Status() local v, s = ui.useState("idle"); set = s; return ui.Text{ v } end
		local root = ui.mount(Status, { iup = iup })
		local dlg = iup.dialog({ iup.vbox({ iup.label({ TITLE = "old code" }), root:widget() }), RASTERSIZE = "300x100" })
		iup.Show(dlg)
		Runtime.frame()
		ui.flushSync(function() set("busy") end)
		assert.equal("busy", iup.GetAttribute(root:widget(), "TITLE"))
		assert.is_not_nil(iup.GetAttribute(root:widget(), "WID"), "mapped with its dialog")
		iup.Destroy(dlg)
	end)

	it("maps widgets it adds to a mapped tree", function()
		local set
		local function C() local v, s = ui.useState(false); set = s; return ui.VBox{ v and ui.Button{ "late" } } end
		local root = ui.mount(C, { iup = iup })
		local dlg = iup.dialog({ root:widget(), RASTERSIZE = "200x100" })
		iup.Show(dlg)
		ui.flushSync(function() set(true) end)
		local btn = iup.GetChild(root:widget(), 0)
		assert.is_not_nil(iup.GetAttribute(btn, "WID"))
		iup.Destroy(dlg)
	end)

	it("refreshes the lowest common container once per flush", function()
		local set
		local function C()
			local w, s = ui.useState(100)
			set = s
			return ui.VBox{ ui.HBox{ ui.Button{ "a", width = w } }, ui.HBox{ ui.Button{ "b", width = w } }, ui.HBox{ ui.Text{ "same" } } }
		end
		local root = ui.mount(C, { iup = iup })
		local dlg = iup.dialog({ root:widget(), RASTERSIZE = "300x200" })
		iup.Show(dlg)
		local refreshed = {}
		local raw = iup.Refresh
		iup.Refresh = function(h) refreshed[#refreshed + 1] = h; return raw(h) end
		ui.flushSync(function() set(120) end)
		iup.Refresh = raw
		assert.same({ root:widget() }, refreshed)
		iup.Destroy(dlg)
	end)

	it("does not refresh for paint-only changes, nor with layout = manual", function()
		local set
		local function C() local v, s = ui.useState("a"); set = s; return ui.VBox{ ui.Button{ "x", tip = v } } end
		local root = ui.mount(C, { iup = iup })
		local dlg = iup.dialog({ root:widget(), RASTERSIZE = "300x200" })
		iup.Show(dlg)
		local n = 0
		local raw = iup.Refresh
		iup.Refresh = function(h) n = n + 1; return raw(h) end
		ui.flushSync(function() set("b") end)
		assert.equal(0, n)
		local set2
		local function D() local v, s = ui.useState(1); set2 = s; return ui.VBox{ ui.Button{ "x", width = v * 10 } } end
		local root2 = ui.mount(D, { iup = iup, layout = "manual" })
		iup.Append(root:widget(), root2:widget())
		iup.Map(root2:widget())
		ui.flushSync(function() set2(5) end)
		iup.Refresh = raw
		assert.equal(0, n)
		assert.equal(1, #root2:layoutChanged())
		iup.Destroy(dlg)
	end)

	it("unmount destroys every widget it made", function()
		local root = ui.mount(ui.VBox{ ui.HBox{ ui.Text{ "a" } }, ui.Button{ "b" } }, { iup = iup })
		local box = root:widget()
		local inner = iup.GetChild(box, 0)
		local leaf = iup.GetChild(inner, 0)
		root:unmount()
		assert.is_false(iup.ihandle(box))
		assert.is_false(iup.ihandle(inner))
		assert.is_false(iup.ihandle(leaf))
	end)

	it("themes subtrees it adds after the first commit", function()
		local themed, set = {}, nil
		local function C() local v, s = ui.useState(false); set = s; return ui.VBox{ v and ui.HBox{ ui.Text{ "x" } } } end
		local root = ui.mount(C, { iup = iup, theme = function(h) themed[#themed + 1] = h end })
		assert.same({}, themed, "the first tree is themed by whoever places it")
		ui.flushSync(function() set(true) end)
		assert.same({ iup.GetChild(root:widget(), 0) }, themed)
	end)
end)
