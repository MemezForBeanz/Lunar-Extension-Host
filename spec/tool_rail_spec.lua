local ToolRail = require("core.ui.ToolRail")
local View = require("core.ui.TabStripView")

local function fixture()
	local iup = { DEFAULT = 0, IGNORE = -1, BUTTON1 = 1 }
	local function widget(def)
		def.children = def.children or {}
		return def
	end
	iup.flattabs, iup.vbox, iup.fill = widget, widget, widget
	function iup.GetAttribute(w, k) return w[k] end
	function iup.SetAttribute(w, k, v) w[k] = v end
	function iup.GetAttributeId(w, k, n) return w[k .. n] end
	function iup.SetAttributeId(w, k, n, v) w[k .. n] = v end
	function iup.GetChild(w, n) return w.children[n + 1] end
	function iup.Append(w, child) w.children[#w.children + 1] = child; child.parent = w end
	function iup.Destroy(w)
		for i, child in ipairs(w.parent.children) do if child == w then table.remove(w.parent.children, i); break end end
	end
	function iup.Map(w) w.WID = "mapped" end
	function iup.Update() end
	function iup.Refresh() end
	function iup.ConvertXYToPos() return 1 end
	local a = { toolbar = "top", HOSTTABOWNERID = "a" }
	local child = { HOSTTABOWNERID = "b" }
	local group = { toolbar = "left", TABTYPE = "TOP", children = { child } }
	local settings = { toolbar = "top", settings = true }
	local root = widget({ children = { a, group, settings }, VALUEPOS = "0", TABTITLE0 = "Top",
		TABTITLE1 = "Tools", TABTITLE2 = "Settings", TABIMAGE1 = "tool-icon" })
	local saved = {}
	local storage = { get = function(_, k) return saved[k] end,
		set = function(_, k, v) saved[k] = v end, save = function() end }
	local groups = { _children = function(_, strip) return strip.children end,
		toolbarOf = function(_, page) return page.toolbar end,
		isGroupStrip = function(_, page) return page.children ~= nil end,
		setActiveRoot = function() end,
		reveal = function(_, page)
			for i, node in ipairs(root.children) do if page == node then root.VALUEPOS = tostring(i - 1); return true end end
		end }
	local rail = ToolRail.new({ iup = iup, main = root, settings = storage, icon = function(name) return name end,
		is_settings = function(page) return page.settings end })
	rail:connect({ groups = groups })
	rail:refresh()
	return rail, root, group, iup, saved
end

describe("core.ui.ToolRail", function()
	describe("statusOf", function()
		it("says nothing for a tab with no work", function()
			assert.is_nil(ToolRail.statusOf({ { tab = "a", state = "ok" } }, "a"))
			assert.is_nil(ToolRail.statusOf({ { tab = "b", state = "running" } }, "a"))
			assert.is_nil(ToolRail.statusOf({ { tab = "a", state = "running" } }, nil))
		end)

		it("shows a failure until it has been seen", function()
			assert.equal("failed", ToolRail.statusOf({ { tab = "a", state = "failed" } }, "a"))
			assert.is_nil(ToolRail.statusOf({ { tab = "a", state = "failed", viewed = true } }, "a"))
		end)

		it("lets running work win over an unseen failure", function()
			assert.equal("running", ToolRail.statusOf({
				{ tab = "a", state = "failed" }, { tab = "a", state = "running" },
			}, "a"))
		end)
	end)

	describe("independent toolbar", function()
		it("shows only sidebar roots and leaves their nested strips horizontal", function()
			local rail, root, group = fixture()
			local strip = rail:widget()
			assert.equal("NO", strip.TABVISIBLE0)
			assert.equal("YES", strip.TABVISIBLE1)
			assert.equal("NO", strip.TABVISIBLE2)
			assert.equal("tool-icon", strip.TABIMAGE1)
			assert.equal("TOP", group.TABTYPE)
			assert.is_nil(root.TABTYPE)
			assert.equal(1, #group.children)
		end)
		it("starts compact and remembers expansion from its bottom control", function()
			local rail, _, _, _, saved = fixture()
			assert.equal("48", rail:widget().TABSBREADTH)
			rail:widget():extrabutton_cb(2, 0)
			assert.equal("176", rail:widget().TABSBREADTH)
			assert.is_false(saved.tool_rail_collapsed)
			rail:themeChanged()
			assert.equal("176", rail:widget().TABSBREADTH)
		end)
		it("selects sidebar roots by their visible ordinal", function()
			local rail, root = fixture()
			assert.is_true(rail:jump(1))
			assert.equal("1", root.VALUEPOS)
			assert.is_false(rail:jump(2))
		end)
		it("keeps top and left selection tied to the same content", function()
			local rail, root, _, iup = fixture()
			local top = iup.flattabs({})
			local view = View.new({ iup = iup, root = root, strip = top,
				is_hidden = function(page) return page.settings or page.toolbar == "left" end })
			view:sync(root.children)
			assert.equal("YES", top.TABVISIBLE0)
			assert.equal("NO", top.TABVISIBLE1)
			root.VALUEPOS = "1"
			view:sync(root.children); rail:refresh()
			assert.is_true(view._away)
			assert.is_false(rail._view._away)
			assert.equal("1", rail:widget().VALUEPOS)
		end)
	end)
end)
