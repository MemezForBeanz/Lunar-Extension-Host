-- core.lui's reconciler: keyed diffing, insert/move/remove, fragments, conditional
-- children, components returning nil, type changes and unmount, asserted on the iup tree.
local T = require("core.lui.test")
local ui = require("core.lui")

local iup
before_each(function() iup = T.boot({}) end)

-- The titles of a box's children, in order.
local function titles(box)
	local out = {}
	for i = 0, iup.GetChildCount(box) - 1 do
		out[#out + 1] = iup.GetAttribute(iup.GetChild(box, i), "TITLE") or iup.GetClassName(iup.GetChild(box, i))
	end
	return out
end

local function list_of(keys)
	local kids = {}
	for _, k in ipairs(keys) do kids[#kids + 1] = ui.Text{ k, key = k } end
	return ui.VBox(kids)
end

describe("lui reconciler", function()
	it("builds the iup tree an element describes", function()
		local root = ui.mount(ui.VBox{ gap = 4, ui.Text{ "a" }, ui.Button{ "b" } }, { iup = iup })
		local box = root:widget()
		assert.equal("vbox", iup.GetClassName(box))
		assert.equal("4", iup.GetAttribute(box, "GAP"))
		assert.same({ "a", "b" }, titles(box))
		assert.equal("flatlabel", iup.GetClassName(iup.GetChild(box, 0)))
		assert.equal("flatbutton", iup.GetClassName(iup.GetChild(box, 1)))
	end)

	it("reorders keyed children by moving the same widgets", function()
		local root = ui.mount(list_of({ "a", "b", "c", "d" }), { iup = iup })
		local box = root:widget()
		local before = {}
		for i = 0, 3 do local c = iup.GetChild(box, i); before[iup.GetAttribute(c, "TITLE")] = c end
		root:update(list_of({ "d", "b", "a", "c" }))
		assert.same({ "d", "b", "a", "c" }, titles(box))
		for i = 0, 3 do
			local c = iup.GetChild(box, i)
			assert.equal(before[iup.GetAttribute(c, "TITLE")], c)
		end
	end)

	it("inserts and removes keyed children in the middle", function()
		local root = ui.mount(list_of({ "a", "c" }), { iup = iup })
		local box = root:widget()
		local a, c = iup.GetChild(box, 0), iup.GetChild(box, 1)
		root:update(list_of({ "a", "b", "c" }))
		assert.same({ "a", "b", "c" }, titles(box))
		assert.equal(a, iup.GetChild(box, 0))
		assert.equal(c, iup.GetChild(box, 2))
		local b = iup.GetChild(box, 1)
		root:update(list_of({ "a", "c" }))
		assert.same({ "a", "c" }, titles(box))
		assert.is_false(iup.ihandle(b), "the removed widget is destroyed")
	end)

	it("places fragment and component children among their host siblings", function()
		local function Pair(p) return ui.Fragment{ ui.Text{ p.x .. "1" }, ui.Text{ p.x .. "2" } } end
		local function Nothing() return nil end
		local function view(show)
			return ui.HBox{
				ui.Text{ "first" },
				ui.h(Pair, { x = "p" }),
				ui.h(Nothing, {}),
				show and ui.Text{ "maybe" },
				ui.Text{ "last" },
			}
		end
		local root = ui.mount(view(false), { iup = iup })
		local box = root:widget()
		assert.same({ "first", "p1", "p2", "last" }, titles(box))
		root:update(view(true))
		assert.same({ "first", "p1", "p2", "maybe", "last" }, titles(box))
		root:update(view(false))
		assert.same({ "first", "p1", "p2", "last" }, titles(box))
	end)

	it("replaces a widget when the element type at a position changes", function()
		local root = ui.mount(ui.VBox{ ui.Text{ "x" } }, { iup = iup })
		local box = root:widget()
		local old = iup.GetChild(box, 0)
		root:update(ui.VBox{ ui.Button{ "x" } })
		local new = iup.GetChild(box, 0)
		assert.equal("flatbutton", iup.GetClassName(new))
		assert.is_false(iup.ihandle(old))
		assert.equal(1, iup.GetChildCount(box))
	end)

	it("writes only the attributes that changed", function()
		local root = ui.mount(ui.Text{ "a", tip = "t", font = "Segoe UI, 9" }, { iup = iup })
		local label = root:widget()
		local writes = {}
		local raw = iup.SetAttribute
		iup.SetAttribute = function(h, k, v) writes[#writes + 1] = k; return raw(h, k, v) end
		root:update(ui.Text{ "b", tip = "t", font = "Segoe UI, 9" })
		iup.SetAttribute = raw
		assert.same({ "TITLE" }, writes)
		assert.equal("b", iup.GetAttribute(label, "TITLE"))
	end)

	it("resets an attribute whose prop went away", function()
		local root = ui.mount(ui.Text{ "a", tip = "hello" }, { iup = iup })
		root:update(ui.Text{ "a" })
		assert.is_nil(iup.GetAttribute(root:widget(), "TIP"))
	end)

	it("keeps unkeyed children by position and state with them", function()
		local seen = {}
		local function Item(p)
			local id = ui.useRef(p.label)
			seen[#seen + 1] = id.current
			return ui.Text{ p.label }
		end
		local root = ui.mount(ui.VBox{ ui.h(Item, { label = "a" }), ui.h(Item, { label = "b" }) }, { iup = iup })
		seen = {}
		root:update(ui.VBox{ ui.h(Item, { label = "b" }), ui.h(Item, { label = "a" }) })
		assert.same({ "a", "b" }, seen, "position 1 kept the ref it was mounted with")
	end)

	it("keeps keyed component state across a reorder", function()
		local function Item(p)
			local first = ui.useRef(p.label)
			return ui.Text{ first.current }
		end
		local function view(keys)
			local kids = {}
			for _, k in ipairs(keys) do kids[#kids + 1] = ui.h(Item, { key = k, label = k }) end
			return ui.VBox(kids)
		end
		local root = ui.mount(view({ "a", "b" }), { iup = iup })
		root:update(view({ "b", "a" }))
		assert.same({ "b", "a" }, titles(root:widget()))
	end)

	it("flattens lists and skips holes in the children", function()
		local rows = { ui.Text{ "r1" }, ui.Text{ "r2" } }
		local root = ui.mount(ui.VBox{ ui.Text{ "head" }, rows, false, nil, ui.Text{ "foot" } }, { iup = iup })
		assert.same({ "head", "r1", "r2", "foot" }, titles(root:widget()))
	end)

	it("turns bare strings in a container into Text", function()
		local root = ui.mount(ui.VBox{ "hello", 42 }, { iup = iup })
		assert.same({ "hello", "42" }, titles(root:widget()))
	end)

	it("rejects element children inside a leaf control", function()
		local msgs = {}
		ui.mount(ui.Button{ ui.Text{ "x" } }, { iup = iup, onError = function(m) msgs[#msgs + 1] = m end })
		assert.equal(1, #msgs)
		assert.truthy(msgs[1]:find("Button takes text"))
	end)

	it("re-renders only the component whose state changed", function()
		local renders = { parent = 0, a = 0, b = 0 }
		local set_a
		local function A() renders.a = renders.a + 1; local v, s = ui.useState(0); set_a = s; return ui.Text{ "a" .. v } end
		local function B() renders.b = renders.b + 1; return ui.Text{ "b" } end
		local function Parent() renders.parent = renders.parent + 1; return ui.VBox{ ui.h(A, {}), ui.h(B, {}) } end
		local root = ui.mount(Parent, { iup = iup })
		set_a(1)
		root:flush()
		assert.same({ parent = 1, a = 2, b = 1 }, renders)
		assert.same({ "a1", "b" }, titles(root:widget()))
	end)

	it("unmount destroys the widgets and runs cleanups", function()
		local cleaned = false
		local function C()
			ui.useEffect(function() return function() cleaned = true end end, {})
			return ui.VBox{ ui.Text{ "x" } }
		end
		local root = ui.mount(C, { iup = iup })
		local box = root:widget()
		root:unmount()
		assert.is_true(cleaned)
		assert.is_false(iup.ihandle(box))
	end)

	it("mounts into an existing container and refreshes it once per flush", function()
		local dlg_box = iup.vbox({})
		local dlg = iup.dialog({ dlg_box, RASTERSIZE = "200x100" })
		iup.Show(dlg)
		local refreshed = {}
		local raw = iup.Refresh
		iup.Refresh = function(h) refreshed[#refreshed + 1] = h; return raw(h) end
		local set
		local function C()
			local v, s = ui.useState("a")
			set = s
			return ui.Fragment{ ui.Text{ v }, ui.Text{ v .. v } }
		end
		ui.mount(C, { iup = iup, parent = dlg_box })
		assert.same({ "a", "aa" }, titles(dlg_box))
		refreshed = {}
		ui.flushSync(function() set("bb") end)
		iup.Refresh = raw
		assert.same({ "bb", "bbbb" }, titles(dlg_box))
		assert.equal(1, #refreshed)
		assert.equal(dlg_box, refreshed[1])
		iup.Destroy(dlg)
	end)
end)
