local AppearanceSettings = require("core.ui.AppearanceSettings")

local handles = {}

local function fake_iup()
	local iup = { DEFAULT = -2, BUTTON1 = 49 }
	local function widget(kind) return function(attrs) attrs.kind = kind; return attrs end end
	iup.flattoggle, iup.list = widget("flattoggle"), widget("list")
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
		theme_manager = opts.theme_manager or {
			buildDropdown = function() return { kind = "dropdown" } end,
			activeTheme = function() return { isDark = function() return true end, palette = function() return { glass = opts.glass ~= false } end } end,
			onApply = function() end,
		},
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
    it("keeps the Glass row conditional so a later theme switch can reveal it", function()
        local s = setup({ glass = false })
        assert.is_false(s.section.entries[2].visible())
        assert.is_true(setup().section.entries[2].visible())
    end)

 local function choose(button, index)
  local list = drop_list(button); list.VALUE = tostring(index); list:valuechanged_cb()
 end
 it("consolidates mode and motion and nests advanced controls", function()
  local s = setup()
  assert.equal(5, #s.section.entries)
  assert.equal("System", s.w.Motion.TITLE)
  assert.equal("Dark", s.w.Mode.TITLE)
  assert.equal("Advanced", s.section.entries[5].label)
  assert.equal(2, #s.section.entries[5].children)
 end)
 it("migrates existing reduced and full preferences without changing keys", function()
  assert.equal("Reduced", setup({values={motion_enabled=false}}).w.Motion.TITLE)
  assert.equal("Full", setup({values={motion_respect_system=false}}).w.Motion.TITLE)
 end)
 it("saves both compatible motion keys and applies the choice", function()
  local s = setup(); choose(s.w.Motion, 2)
  assert.is_false(s.store.motion_enabled)
  assert.is_false(s.store.motion_respect_system)
  assert.same({{enabled=false,respect_system=false}},s.configured)
  choose(s.w.Motion, 1)
  assert.is_true(s.store.motion_enabled); assert.is_true(s.store.motion_respect_system)
 end)
 it("honours either motion policy lock", function()
  local s=setup({locked={motion_respect_system=true}})
  assert.equal("NO",s.w.Motion.ACTIVE)
  choose(s.w.Motion,2); assert.equal(0,s.saved())
 end)
 it("changes mode and follows external theme changes", function()
  local dark,follow,listener=true,false,nil
  local s=setup({theme_manager={buildDropdown=function() return {} end,
   activeTheme=function() return {isDark=function() return dark end} end,
   toggleMode=function() dark=not dark end,onApply=function(_,fn) listener=fn end},
   system_theme={enabled=function() return follow end,setEnabled=function(_,on) follow=on;return true end}})
  choose(s.w.Mode,2);assert.is_false(dark);assert.is_false(follow)
  choose(s.w.Mode,1);assert.is_true(follow)
  follow=false;dark=true;listener();assert.equal("Dark",s.w.Mode.TITLE)
 end)
 it("keeps advanced speed and transition settings functional",function()
  local s=setup();local children=s.section.entries[5].children
  choose(children[1].widget,5);assert.equal(2,s.store.motion_scale)
  local _,values=AppearanceSettings.transition_choices()
  choose(children[2].widget,2);assert.equal(values[2],s.store.motion_tab_transition)
 end)
 it("persists glass changes",function()
  local s=setup();local t=s.w["Glass effects"];t.VALUE="OFF";t:valuechanged_cb()
  assert.is_false(s.store.glass_effects)
 end)
end)
