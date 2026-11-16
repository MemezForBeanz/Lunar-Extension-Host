--- The host's own "Appearance" settings section: palette, light or dark, and motion.
--
-- The palette selector stays in sync with the top-bar Theme menu (both come from
-- `ThemeManager`), and the Dark mode toggle with the moon button: all three follow
-- whatever theme is on screen. A setting the org profile locks shows greyed out with a note,
-- and a change is applied only when the write succeeded.
--
-- @module core.ui.AppearanceSettings

local FlatDropdown = require("core.ui.FlatDropdown")

local M = {}

--- Motion speed choices, as shown and as `motion_scale` values.
M.SPEEDS = { "0.5x (faster)", "0.75x", "1x (default)", "1.5x", "2x (slower)" }
M.SPEED_VALUES = { 0.5, 0.75, 1.0, 1.5, 2.0 }

--- The list position (1-based) of the choice nearest `scale`; 1x when unset.
-- @tparam number|string|nil scale
-- @treturn number
function M.speed_index(scale)
	scale = tonumber(scale) or 1.0
	local best, best_d = 3, math.huge
	for i, v in ipairs(M.SPEED_VALUES) do
		local d = math.abs(v - scale)
		if d < best_d then best, best_d = i, d end
	end
	return best
end

--- Tab transition choices: "Theme default", then every kind core.lib.PageTransitions
-- knows (the built-in ones and those extensions registered), as `{ labels, values }`.
function M.transition_choices()
	local labels, values = { "Theme default" }, { "theme" }
	for _, k in ipairs(require("core.lib.PageTransitions").list()) do
		labels[#labels + 1], values[#values + 1] = k.label, k.name
	end
	return labels, values
end

--- Build the section and register it with the host.
-- @tparam table opts
-- @tparam table opts.iup the IUP binding
-- @tparam table opts.settings the `SettingsManager`
-- @tparam table opts.host the `HostAPI` (for `addSettings`)
-- @tparam table opts.theme_manager the `ThemeManager` (for its dropdown)
-- @tparam table opts.motion the `MotionDirector`
-- @tparam[opt] table opts.system_theme the `core.lib.SystemTheme` ("Match system theme")
-- @tparam[opt] string opts.org_name shown on locked settings ("Managed by ...")
function M.register(opts)
	local iup, settings, motion = opts.iup, opts.settings, opts.motion
	local Glass = require("core.ui.Glass")
	Glass.setEnabled(rawget(iup, "_IMGUI") and settings:get("glass_effects") ~= false)

	local function manage(widget, key)
		if settings:isLocked(key) then
			iup.SetAttribute(widget, "ACTIVE", "NO")
			iup.SetAttribute(widget, "TIP", "Managed by " .. (opts.org_name or "your organization"))
		end
		return widget
	end

	local function set_and_save(key, value)
		if not settings:set(key, value) then return false end
		settings:save()
		return true
	end

	local function toggle(key, configure_key)
		local t = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle", VALUE = (settings:get(key) ~= false) and "ON" or "OFF" })
		function t:valuechanged_cb()
			local on = iup.GetAttribute(t, "VALUE") == "ON"
			if set_and_save(key, on) then motion:configure({ [configure_key] = on }) end
			return iup.DEFAULT
		end
		return manage(t, key)
	end

	-- Owner-drawn (core.ui.FlatDropdown), like the Theme selector above it: a
	-- native dropdown follows the OS theme instead of Lunar's.
	local speed_dd = FlatDropdown.new(iup, {
		items = M.SPEEDS,
		value = M.speed_index(settings:get("motion_scale")),
		width = 180,   -- the same as the Theme selector above it, so the column lines up
		font = "Segoe UI, 11",
		name = "appearance_motion_speed",
		on_change = function(index)
			local scale = M.SPEED_VALUES[index]
			if scale and set_and_save("motion_scale", scale) then
				motion:configure({ scale = scale })
			end
		end,
	})
	local speed = speed_dd.widget
	manage(speed, "motion_scale")

	-- The tab transition: the theme's, or one the user picks (core.lib.PageTransitions).
	-- Listed when the section is built; an extension loaded later adds its kind to the
	-- theme's choice and to `motion_tab_transition` set by hand.
	local t_labels, t_values = M.transition_choices()
	local t_index = 1
	for i, v in ipairs(t_values) do if v == (settings:get("motion_tab_transition") or "theme") then t_index = i end end
	local transition_dd = FlatDropdown.new(iup, {
		items = t_labels,
		value = t_index,
		width = 180,
		font = "Segoe UI, 11",
		name = "appearance_tab_transition",
		on_change = function(index)
			local kind = t_values[index]
			if kind and set_and_save("motion_tab_transition", kind) then
				motion:configure({ page_transition = kind })
			end
		end,
	})
	manage(transition_dd.widget, "motion_tab_transition")

	local entries = {
		{
			label = "Theme",
			description = "Choose a palette for all tools.",
			widget = manage(opts.theme_manager:buildDropdown(), "theme"),
		},
	}
	local glass = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle", VALUE = settings:get("glass_effects") ~= false and "ON" or "OFF" })
	function glass:valuechanged_cb()
		local on = iup.GetAttribute(glass, "VALUE") == "ON"
		if set_and_save("glass_effects", on) then
			Glass.setEnabled(rawget(iup, "_IMGUI") and on)
			local root = iup.GetDialog and iup.GetDialog(glass)
			if root then iup.Update(root) end
		end
		return iup.DEFAULT
	end
	entries[#entries + 1] = { label = "Glass effects", description = "Frosted chrome and floating surfaces.", widget = manage(glass, "glass_effects") }
	local themes = opts.theme_manager
	local function is_dark()
		local theme = themes:activeTheme()
		return theme ~= nil and theme:isDark()
	end
	local system_theme = opts.system_theme
	local function mode_index()
		return system_theme and system_theme:enabled() and 1 or (is_dark() and 3 or 2)
	end
	local mode_dd
	mode_dd = FlatDropdown.new(iup, {
		items = { "System", "Light", "Dark" }, value = mode_index(), width = 180,
		name = "appearance_mode",
		on_change = function(index)
			if settings:isLocked("theme") or settings:isLocked("theme_follow_system") then
				mode_dd:setValue(mode_index()); return
			end
			if system_theme then
				if not system_theme:setEnabled(index == 1) then mode_dd:setValue(mode_index()); return end
			elseif index == 1 then mode_dd:setValue(mode_index()); return end
			if index ~= 1 and (index == 3) ~= is_dark() then themes:toggleMode() end
			mode_dd:setValue(mode_index())
		end,
	})
	manage(mode_dd.widget, "theme")
	manage(mode_dd.widget, "theme_follow_system")
	entries[#entries + 1] = { label = "Mode", description = "Follow the system or choose light or dark.", widget = mode_dd.widget }
	themes:onApply(function() mode_dd:setValue(mode_index()) end)

	local function motion_index()
		if settings:get("motion_enabled") == false then return 2 end
		return settings:get("motion_respect_system") ~= false and 1 or 3
	end
	local motion_dd
	motion_dd = FlatDropdown.new(iup, {
		items = { "System", "Reduced", "Full" }, value = motion_index(), width = 180,
		name = "appearance_motion",
		on_change = function(index)
			if settings:isLocked("motion_enabled") or settings:isLocked("motion_respect_system") then
				motion_dd:setValue(motion_index()); return
			end
			-- Keep the legacy keys authoritative for existing installations and policies.
			settings:set("motion_enabled", index ~= 2)
			settings:set("motion_respect_system", index == 1)
			settings:save()
			motion:configure({ enabled = index ~= 2, respect_system = index == 1 })
		end,
	})
	manage(motion_dd.widget, "motion_enabled")
	manage(motion_dd.widget, "motion_respect_system")
	entries[#entries + 1] = { label = "Motion", description = "Follow the system or choose reduced or full motion.", widget = motion_dd.widget }
	entries[#entries + 1] = { label = "Advanced", children = {
		{ label = "Motion speed", description = "Scale animation duration.", widget = speed },
		{ label = "Tab transition", description = "Choose how pages change.", widget = transition_dd.widget },
	} }

	opts.host:addSettings("Appearance", { entries = entries, icon = "color-palette" })
end

return M
