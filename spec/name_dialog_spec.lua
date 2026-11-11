-- core.ui.NameDialog on the ImGui host's Null backend: the tree it shows and what typing,
-- Enter, Escape and its buttons return. ModalMotion.popup is replaced by a script that
-- shows the dialog, drives it with real input events, and returns.
local T = require("core.lui.test")
local ModalMotion = require("core.ui.ModalMotion")
local NameDialog = require("core.ui.NameDialog")

local iup, Runtime, B, Element
local raw_popup = ModalMotion.popup
local script

before_each(function()
	iup, Runtime, B, Element = T.boot({})
	ModalMotion.popup = function(_, dlg)
		iup.Show(dlg)
		Runtime.frame()
		script(dlg)
		iup.Hide(dlg)
	end
end)
after_each(function() ModalMotion.popup = raw_popup end)

local function find(root, pred)
	if pred(root) then return root end
	for i = 0, iup.GetChildCount(root) - 1 do
		local f = find(iup.GetChild(root, i), pred)
		if f then return f end
	end
end
local function by_class(dlg, cls) return find(dlg, function(h) return iup.GetClassName(h) == cls end) end
local function by_title(dlg, title) return find(dlg, function(h) return Element.own(h, "TITLE") == title end) end

local function click(h)
	Runtime.frame()
	local st = Element.state(h)
	local x, y = math.floor(st.x + st.w / 2), math.floor(st.y + st.h / 2)
	B.queue({ events = { { type = "move", x = x, y = y }, { type = "press", button = 1 }, { type = "release", button = 1 } } })
	Runtime.frame()
end
local function chars(s)
	local evs = {}
	for ch in s:gmatch(".") do evs[#evs + 1] = { type = "char", char = ch } end
	B.queue({ events = evs })
	Runtime.frame()
end
local function key(code)
	B.queue({ keys = { { code = code, down = true } } })
	Runtime.frame()
end

describe("NameDialog", function()
	it("shows the themed prompt with flat controls", function()
		local parent = iup.dialog({ iup.vbox({}) })
		local seen
		script = function(dlg)
			seen = {
				title = Element.own(dlg, "TITLE"), icon = Element.own(dlg, "ICON"),
				size = Element.own(dlg, "RASTERSIZE"), shrink = Element.own(dlg, "SHRINK"),
				parent = iup.GetAttributeHandle(dlg, "PARENTDIALOG"),
				enter = Element.own(dlg, "DEFAULTENTER"),
			}
			local label = by_class(dlg, "label")
			seen.label = { Element.own(label, "TITLE"), Element.own(label, "FONT"), Element.own(label, "THEMEROLE") }
			local input = by_class(dlg, "text")
			seen.input = { iup.GetAttribute(input, "VALUE"), Element.own(input, "BORDER"),
				Element.own(input, "VISIBLECOLUMNS"), Element.own(input, "THEMEROLE"), Element.own(input, "EXPAND") }
			local frame = by_class(dlg, "flatframe")
			seen.frame = { Element.own(frame, "THEMEROLE"), Element.own(frame, "TITLE"), Element.own(frame, "EXPAND") }
			local ok, cancel = by_title(dlg, "Rename"), by_title(dlg, "Cancel")
			seen.ok = { iup.GetClassName(ok), Element.own(ok, "THEMEROLE"), Element.own(ok, "PADDING") }
			seen.cancel = { iup.GetClassName(cancel), Element.own(cancel, "THEMEROLE") }
		end
		NameDialog.show({ iup = iup, title = "Rename Group", label = "Group name:", value = "Tools",
			ok = "Rename", parent = parent })
		assert.same({ title = "Rename Group", icon = "IUP", size = "380x150", shrink = "YES", parent = parent }, seen.title and {
			title = seen.title, icon = seen.icon, size = seen.size, shrink = seen.shrink, parent = seen.parent })
		assert.is_nil(seen.enter)
		assert.same({ "Group name:", "Segoe UI, 11", "settingslabel" }, seen.label)
		assert.same({ "Tools", "NO", "28", "text", "HORIZONTAL" }, seen.input)
		assert.same({ "text", "", "HORIZONTAL" }, seen.frame)
		assert.same({ "flatbutton", "primary_btn", "12x5" }, seen.ok)
		assert.same({ "flatbutton", "actionbutton" }, seen.cancel)
		iup.Destroy(parent)
	end)

	it("returns the trimmed text on Enter", function()
		script = function(dlg)
			local input = by_class(dlg, "text")
			iup.SetFocus(input)
			iup.SetAttribute(input, "VALUE", "")
			chars("  Build tools ")
			key(iup.K_CR)
		end
		assert.equal("Build tools", NameDialog.show({ iup = iup }))
	end)

	it("returns what was typed when OK is clicked", function()
		script = function(dlg)
			local input = by_class(dlg, "text")
			iup.SetFocus(input)
			iup.SetAttribute(input, "VALUE", "")
			chars("Media")
			click(by_title(dlg, "OK"))
		end
		assert.equal("Media", NameDialog.show({ iup = iup, value = "old" }))
	end)

	it("returns nil on Escape, on Cancel, and for blank text", function()
		script = function() key(iup.K_ESC) end
		assert.is_nil(NameDialog.show({ iup = iup, value = "kept" }))
		script = function(dlg) click(by_title(dlg, "Cancel")) end
		assert.is_nil(NameDialog.show({ iup = iup, value = "kept" }))
		script = function(dlg)
			local input = by_class(dlg, "text")
			iup.SetFocus(input)
			iup.SetAttribute(input, "VALUE", "")
			chars("   ")
			key(iup.K_CR)
		end
		assert.is_nil(NameDialog.show({ iup = iup }))
	end)

	it("confirms the pre-filled value unchanged", function()
		script = function() key(iup.K_CR) end
		assert.equal("Tools", NameDialog.show({ iup = iup, value = "Tools" }))
	end)

	it("tells ModalMotion how it closed, themes the tree first, and destroys it after", function()
		local how, themed, dialog
		local raw_result = ModalMotion.result
		ModalMotion.result = function(_, d, h) how = h; return raw_result(iup, d, h) end
		script = function(dlg) dialog = dlg; key(iup.K_ESC) end
		NameDialog.show({ iup = iup, notify_tree_change = function(d) themed = d end })
		ModalMotion.result = raw_result
		assert.equal("cancel", how)
		assert.equal(dialog, themed)
		assert.is_false(iup.ihandle(dialog))
	end)
end)
