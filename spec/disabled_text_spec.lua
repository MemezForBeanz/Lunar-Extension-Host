local Null = require("core.imgui.backend.Null")
local Fonts = require("core.imgui.Fonts")
local Element = require("core.imgui.Element")
local iup = require("core.imgui.iup")
local Classes = require("core.imgui.Classes")

-- A disabled control's label is drawn in its theme's `inactivetext` exactly and keeps
-- 4.5:1 on its fill (space-3 item 4: Lunar's Build at 3.13:1 dark, 2.36:1 light).
describe("disabled labels", function()
	before_each(function()
		Fonts.backend = Null.new(); Fonts.reset()
		Element.globals.DEFAULTFONT = "Segoe UI, 10"
		Element.globals.DLGBGCOLOR, Element.globals.DLGFGCOLOR = "240 240 240", "0 0 0"
	end)

	local function drawn(attrs)
		local F = require("core.imgui.widgets.flatdraw")
		local b = iup.flatbutton(attrs)
		local dialog = iup.dialog{ iup.vbox{ b } }
		local st = Element.state(b)
		st.x, st.y, st.w, st.h = 0, 0, 80, 24
		local old_icon, got = F.icon, {}
		F.icon = function(...) local a = { ... }; got.fg, got.active, got.fade = a[19], a[21], a[16] end
		local dc = setmetatable({}, { __index = function() return function() end end })
		local ok, err = pcall(Classes.get("flatbutton").draw, b, st, dc)
		F.icon = old_icon
		iup.Destroy(dialog)
		assert.is_true(ok, err)
		return got
	end

	it("draws a disabled flat button's label in TEXTINACTIVECOLOR, not faded again", function()
		local got = drawn({ TITLE = "Build", ACTIVE = "NO", FGCOLOR = "183 193 206", BGCOLOR = "30 38 48",
			TEXTINACTIVECOLOR = "137 146 159" })
		assert.equal("137 146 159", got.fg)
		assert.is_true(got.active)   -- the text is not faded toward the fill
	end)

	it("keeps IUP's halfway fade without one", function()
		local got = drawn({ TITLE = "Build", ACTIVE = "NO", FGCOLOR = "183 193 206", BGCOLOR = "30 38 48" })
		assert.equal("183 193 206", got.fg)
		assert.is_false(got.active)
	end)

	it("gives every Lunar and Fluent theme's buttons a disabled label at 4.5:1 on their fill", function()
		local lunar = require("core.classes.Themes.lunar_rules")
		local roles = { "flatbutton", "primary_btn", "actionbutton", "ghost_btn", "danger_btn", "link_btn", "icon_btn" }
		for _, name in ipairs({ "LunarDarkTheme", "LunarLightTheme", "OneDarkProTheme", "OneLightTheme" }) do
			local theme = require("core.classes.Themes." .. name):new()
			local rules = theme:rules()
			for _, role in ipairs(roles) do
				local r = rules[role]
				if r and r.inactivefg then
					assert.is_not_nil(r.inactivetext, name .. "." .. role)
					local ratio = lunar.contrast(r.inactivetext, r.inactivebg)
					assert.is_true(ratio >= 4.5, ("%s.%s %.2f:1"):format(name, role, ratio))
					-- quieter than the muted text it comes from, where that reads
					local muted = lunar.contrast(r.inactivefg, r.inactivebg)
					if muted >= 5 then assert.is_true(ratio < muted, name .. "." .. role) end
				end
			end
		end
	end)

	it("audits a disabled label as drawn (scripts/theme_contrast.lua)", function()
		local audit = require("scripts.theme_contrast")
		for _, name in ipairs({ "LunarDarkTheme", "LunarLightTheme" }) do
			local lines = {}
			audit.audit(require("core.classes.Themes." .. name):new(), function(s) lines[#lines + 1] = s end)
			local seen = false
			for _, s in ipairs(lines) do
				if s:match("^actionbutton%.inactive ") then
					seen = true
					assert.is_true(tonumber(s:match(" ([%d%.]+):1")) >= 4.5, s)
				end
			end
			assert.is_true(seen, name)
		end
	end)
end)
