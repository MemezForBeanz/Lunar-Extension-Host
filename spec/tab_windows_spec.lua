local Null = require("core.imgui.backend.Null")
local R = require("core.imgui.Runtime")
local E = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Groups = require("core.classes.TabGroups")
local Order = require("core.classes.TabOrder")
local Windows = require("core.ui.TabWindows")

describe("extension and group windows", function()
	local B, groups, root, dialog, windows, group, a, b
	before_each(function()
		B = Null.new{ w = 1000, h = 700, dialog_windows = true }
		R.init(B)
		root = iup.flattabs{ EXPAND = "YES" }
		dialog = iup.dialog{ root, RASTERSIZE = "1000x700", MINSIZE = "700x500" }
		iup.Show(dialog); R.frame()
		local order = Order:new{ iup = iup }
		groups = Groups:new{ iup = iup, root_strip = root, on_strip_created = function(s) order:install(s) end }
		order:setGroups(groups)
		group = groups:createGroup(root, "HPE", "manifest")
		a = iup.vbox{ iup.text{ VALUE = "unsaved input" }, TABTITLE = "Log Parser", _IUPLUNAR_TABKEY = "hpe/log" }
		b = iup.vbox{ TABTITLE = "Build Queue", _IUPLUNAR_TABKEY = "hpe/build" }
		iup.Append(group, a); iup.Append(group, b)
		groups:_syncTitles(group)
		windows = Windows.new{ iup = iup, groups = groups, dialog = dialog }
	end)
	after_each(function() windows:restoreAll(); R.close() end)

	it("moves a live extension to its own native surface and restores its original slot", function()
		local editor = iup.GetChild(a, 0)
		local window = windows:open(a)
		R.frame()
		assert.equal(window.root, iup.GetParent(a))
		assert.equal(editor, iup.GetChild(a, 0))
		assert.equal("unsaved input", iup.GetAttribute(editor, "VALUE"))
		assert.equal(window, windows:windowOf(a))
		assert.is_truthy(E.state(window.dialog).data.win)
		assert.equal(2, #groups:leaves())
		local saved = groups:serialize().children
		assert.equal("hpe/log", saved[1].children[1].key)
		assert.equal("hpe/build", saved[1].children[2].key)
		windows:restore(window)
		assert.equal(a, iup.GetChild(group, 0))
		assert.equal(b, iup.GetChild(group, 1))
		assert.equal("unsaved input", iup.GetAttribute(editor, "VALUE"))
		assert.equal(0, #windows.windows)
	end)

	it("floats and docks a whole group with the same child controls and saved layout", function()
		local window = windows:open(group)
		assert.equal(window.root, iup.GetParent(group))
		assert.equal(a, iup.GetChild(group, 0)); assert.equal(b, iup.GetChild(group, 1))
		local saved = groups:serialize().children
		assert.equal("HPE", saved[1].name)
		assert.equal(2, #saved[1].children)
		windows:restore(window)
		assert.equal(root, iup.GetParent(group))
	end)

	it("returns a window on native close without destroying its extension", function()
		local window = windows:open(a)
		R.frame()
		local id = E.state(window.dialog).data.win
		B.popups[id].close = true
		R.frame()
		B.advance(0.01); R.step(false)
		assert.equal(group, iup.GetParent(a))
		assert.is_truthy(E.state(a))
		assert.is_nil(B.popups[id])
	end)

	it("keeps a manifest group whose only live page is floating", function()
		iup.Destroy(b)
		local window = windows:open(a)
		groups:_pruneEmptyManifestGroups(root)
		assert.is_truthy(E.state(group))
		assert.equal("hpe/log", groups:serialize().children[1].children[1].key)
		windows:restore(window)
		assert.equal(a, iup.GetChild(group, 0))
	end)

	it("falls back to the main strip if the original group was removed", function()
		local window = windows:open(a)
		iup.Destroy(group)
		windows:restore(window)
		assert.equal(root, iup.GetParent(a))
	end)

	it("enforces the main minimum and separate pop-out limits through the backend", function()
		assert.equal(700, B.limits.min_w); assert.equal(500, B.limits.min_h)
		local window = windows:open(a)
		R.frame()
		local p = B.popups[E.state(window.dialog).data.win]
		assert.equal(500, p.limits.min_w); assert.equal(360, p.limits.min_h)
		iup.SetAttribute(window.dialog, "MINSIZE", "600x400")
		assert.equal(600, p.limits.min_w); assert.equal(400, p.limits.min_h)
	end)
	it("preserves sibling order when multiple windows open and close in different orders", function()
		local c = iup.vbox{ TABTITLE = "Third", _IUPLUNAR_TABKEY = "hpe/third" }
		iup.Append(group, c)
		local wb, wa = windows:open(b), windows:open(a)
		local saved = groups:serialize().children[1].children
		assert.same({ "hpe/log", "hpe/build", "hpe/third" }, { saved[1].key, saved[2].key, saved[3].key })
		windows:restore(wb); windows:restore(wa)
		assert.same({ a, b, c }, groups:_children(group))
	end)

	it("still saves a floating page after its original group is removed", function()
		windows:open(a)
		iup.Destroy(group)
		assert.equal("hpe/log", groups:serialize().children[1].key)
	end)

	it("cleans up an empty window after an extension unloads", function()
		local window = windows:open(a)
		iup.Destroy(a)
		windows:sync()
		assert.equal(0, #windows.windows)
		assert.is_nil(E.state(window.dialog))
	end)
	it("routes active extension context with the focused window", function()
		local window = windows:open(a)
		R.frame()
		local id = E.state(window.dialog).data.win
		B.popups[id].active = true
		R.frame()
		assert.equal(window.root, groups:activeRoot())
		assert.equal(a, groups:activeLeaf())
		B.popups[id].active = false
		R.activateDialog(dialog)
		assert.equal(root, groups:activeRoot())
		assert.equal(b, groups:activeLeaf())
	end)
	it("rejects a logical ancestor drop when nested groups are in separate windows", function()
		local nested = groups:createGroup(group, "Nested")
		iup.Append(nested, iup.vbox{ _IUPLUNAR_TABKEY = "hpe/nested" })
		windows:open(group); windows:open(nested)
		assert.is_true(groups:_isAncestor(group, nested))
		assert.is_false(groups:moveInto(group, nested))
		assert.equal("HPE", groups:serialize().children[1].name)
	end)
	it("draws drop feedback on the destination window's surface", function()
		local window = windows:open(a)
		R.frame()
		local director = { enabled = function() return true end, cancel = function() end,
			animate = function(_, s) s.on_frame(s.to) end, atFrameEnd = function(_, fn) fn() end }
		local feedback = require("core.ui.TabDragMotion"):new{ iup = iup, dialog = dialog, director = director }
		feedback:showCombine(root, 0, 100, 30)
		local first = feedback._compositor
		feedback:showCombine(window.root, 0, 100, 30)
		assert.equal(window.dialog, feedback._compositor.backend.dialog)
		assert.is_nil(first.groups["tab-drag"])
		feedback:clear()
	end)
end)
