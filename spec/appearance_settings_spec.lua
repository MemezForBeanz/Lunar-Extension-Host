local AppearanceSettings = require("core.ui.AppearanceSettings")

local handles = {}

local function fake_iup()
	local iup = { DEFAULT = -2, BUTTON1 = 49 }
	local function widget(kind) return function(attrs) attrs.kind = kind; return attrs end end
	iup.toggle, iup.list = widget("toggle"), widget("list")
	iup.flatlist, iup.dropbutton = widget("flatlist"), widget("dropbutton")
	function iup.SetAttribute(w, k, v) w[k] = v end
	function iup.GetAttribute(w, k) return w[k] end
	function iup.SetHandle(name, w) handles[name] = w end
	return iup
end

-- The flat list behind a FlatDropdown's button.
local function drop_list(btn) return handles[btn.DROPCHILD] end

local function setup(opts)
	opts = opts or {}
	local store, saved, configured, section = opts.values or {}, 0, {}, nil
	local settings = {
		get = function(_, k) return store[k] end,
		set = function(_, k, v)
			if (opts.locked or {})[k] then return false, "locked" end
			store[k] = v
			return true
		end,
		save = function() saved = saved + 1 end,
		isLocked = function(_, k) return (opts.locked or {})[k] == true end,
	}
	AppearanceSettings.register({
		iup = fake_iup(),
		settings = settings,
		host = { addSettings = function(_, name, s) section = { name = name, entries = s.entries } end },
		theme_manager = { buildDropdown = function() return { kind = "dropdown" } end },
		motion = { configure = function(_, c) configured[#configured + 1] = c end },
		system_theme = opts.system_theme,
		org_name = opts.org_name,
	})
	local by_label = {}
	for _, e in ipairs(section.entries) do by_label[e.label] = e.widget end
	return { section = section, w = by_label, store = store, configured = configured,
		saved = function() return saved end }
end

describe("AppearanceSettings", function()
	it("registers the Appearance section with theme and motion rows", function()
		local s = setup()
		assert.are.equal("Appearance", s.section.name)
		assert.are.equal(4, #s.section.entries)
		assert.are.equal("dropdown", s.w.Theme.kind)
		assert.are.equal("ON", s.w["Interface motion"].VALUE)   -- unset means on
	end)

	it("saves and applies a toggle", function()
		local s = setup()
		s.w["Interface motion"]:action(0)
		assert.is_false(s.store.motion_enabled)
		assert.are.equal(1, s.saved())
		assert.are.same({ { enabled = false } }, s.configured)
	end)

	it("applies a speed choice from an owner-drawn dropdown", function()
		local s = setup({ values = { motion_scale = 2.0 } })
		local btn = s.w["Motion speed"]
		assert.are.equal("dropbutton", btn.kind)          -- not a native iup.list
		local list = drop_list(btn)
		assert.are.equal("5", list.VALUE)
		assert.are.equal(AppearanceSettings.SPEEDS[5], btn.TITLE)
		list.VALUE = "2"                                   -- the user picks 0.75x
		list:valuechanged_cb()
		assert.are.equal(0.75, s.store.motion_scale)
		assert.are.same({ { scale = 0.75 } }, s.configured)
		assert.are.equal(AppearanceSettings.SPEEDS[2], btn.TITLE)
	end)

	it("greys out a locked setting and changes nothing when it is toggled", function()
		local s = setup({ locked = { motion_enabled = true, theme = true }, org_name = "Acme" })
		local t = s.w["Interface motion"]
		assert.are.equal("NO", t.ACTIVE)
		assert.are.equal("Managed by Acme", t.TIP)
		assert.are.equal("NO", s.w.Theme.ACTIVE)
		t:action(0)
		assert.are.same({}, s.configured)
		assert.are.equal(0, s.saved())
	end)

	it("adds a Match system theme toggle that drives SystemTheme", function()
		local calls = {}
		local st = {
			enabled = function() return false end,
			setEnabled = function(_, on) calls[#calls + 1] = on; return true end,
		}
		local s = setup({ system_theme = st })
		assert.are.equal(5, #s.section.entries)
		assert.are.equal("Match system theme", s.section.entries[2].label)
		local t = s.w["Match system theme"]
		assert.are.equal("OFF", t.VALUE)
		t:action(1)
		assert.are.same({ true }, calls)
	end)

	it("greys out Match system theme when the org locks the theme", function()
		local st = { enabled = function() return false end, setEnabled = function() return false end }
		local s = setup({ system_theme = st, locked = { theme = true }, org_name = "Acme" })
		local t = s.w["Match system theme"]
		assert.are.equal("NO", t.ACTIVE)
		assert.are.equal("Managed by Acme", t.TIP)
		t:action(1)                                       -- refused: the toggle snaps back
		assert.are.equal("OFF", t.VALUE)
	end)

	it("maps a scale to the nearest choice", function()
		assert.are.equal(3, AppearanceSettings.speed_index(nil))
		assert.are.equal(1, AppearanceSettings.speed_index(0.4))
		assert.are.equal(4, AppearanceSettings.speed_index("1.4"))
	end)
end)
