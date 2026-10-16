local ThemeManager = require("core.classes.ThemeManager")
local Theme = require("core.classes.Themes.Theme")

-- Just enough IUP for ThemeManager's constructor and its menu/dropdown bookkeeping.
local function fake_iup()
	local attrs = {}
	local iup = { DEFAULT = -2 }
	function iup.GetGlobal() return "" end
	function iup.SetAttribute(h, k, v) attrs[h] = attrs[h] or {}; attrs[h][k] = v end
	function iup.GetAttribute(h, k) return attrs[h] and attrs[h][k] end
	function iup.item(t) return t end
	function iup.menu(t) return { children = t } end
	function iup.submenu(t) return t end
	function iup.Append(menu, item) menu.children[#menu.children + 1] = item end
	function iup.Map() end
	function iup.Detach(item) item.detached = true end
	function iup.Destroy() end
	iup._attrs = attrs
	return iup
end

local function make_theme(id)
	local T = Theme:subclass("RegSpec_" .. id)
	function T:initialize() Theme.initialize(self, { id = id, label = "Label " .. id, palette = {} }) end
	return T
end

describe("ThemeManager runtime themes", function()
	local iup, mgr
	before_each(function()
		iup = fake_iup()
		mgr = ThemeManager:new({ iup = iup })
	end)

	it("adds a theme to the list and the menu, and refuses duplicates", function()
		local menu = mgr:buildMenu()
		local before = #menu[1].children
		assert.are.equal("pack_dark", mgr:registerTheme(make_theme("pack_dark")))
		assert.are.equal(before + 1, #menu[1].children)
		local found = false
		for _, t in ipairs(mgr:themes()) do found = found or t.id == "pack_dark" end
		assert.is_true(found)

		local id, err = mgr:registerTheme(make_theme("pack_dark"))
		assert.is_nil(id)
		assert.truthy(err:find("already exists", 1, true))
	end)

	it("rejects things that aren't themes", function()
		local id, err = mgr:registerTheme({})
		assert.is_nil(id)
		assert.truthy(err:find("not a Theme subclass", 1, true))
	end)

	it("re-applies the user's saved theme when its extension reloads", function()
		local m = ThemeManager:new({ iup = iup, settings = { get = function(_, k) return k == "theme" and "pack_dark" or nil end } })
		local applied
		m.apply = function(_, id) applied = id end
		m._applied = "classic_dark"   -- startup has painted a theme already
		m._current = "classic_dark"
		m:registerTheme(make_theme("pack_dark"))
		assert.are.equal("pack_dark", applied)

		-- Before startup's own apply nothing is forced: startup applies the saved theme itself.
		local m2 = ThemeManager:new({ iup = iup, settings = { get = function() return "pack_dark" end } })
		local applied2
		m2.apply = function(_, id) applied2 = id end
		m2:registerTheme(make_theme("pack_dark"))
		assert.is_nil(applied2)
	end)

	it("forgets cached native bundles for an unregistered theme", function()
		mgr:registerTheme(make_theme("cached"))
		mgr._element_handles = { cached = { x = 1 } }
		mgr:unregisterTheme("cached")
		assert.is_nil(mgr._element_handles.cached)
	end)

	it("removes an unregistered theme from the menu and list", function()
		mgr:buildMenu()
		mgr:registerTheme(make_theme("gone_soon"))
		local item = mgr._menu_items.gone_soon
		mgr:unregisterTheme("gone_soon")
		assert.is_true(item.detached)
		for _, t in ipairs(mgr:themes()) do assert.are_not.equal("gone_soon", t.id) end
	end)
end)
