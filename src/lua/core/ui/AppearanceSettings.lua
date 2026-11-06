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

	local entries = {
		{
			label = "Theme",
			description = "Choose the application's color palette. Affects all tabs and extensions.",
			widget = manage(opts.theme_manager:buildDropdown(), "theme"),
		},
	}
	local themes = opts.theme_manager
	local function is_dark()
		local theme = themes:activeTheme()
		return theme ~= nil and theme:isDark()
	end
	local dark_mode = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle", VALUE = is_dark() and "ON" or "OFF" })
	function dark_mode:valuechanged_cb()
		if (iup.GetAttribute(dark_mode, "VALUE") == "ON") ~= is_dark() then themes:toggleMode() end
		iup.SetAttribute(dark_mode, "VALUE", is_dark() and "ON" or "OFF")
		return iup.DEFAULT
	end
	manage(dark_mode, "theme")
	entries[#entries + 1] = {
		label = "Dark mode",
		description = "Show this palette's dark colors. The moon button in the title bar does the same. "
			.. "A palette with only one mode can't switch.",
		widget = dark_mode,
	}
	local system_theme = opts.system_theme
	local follow
	if system_theme then
		follow = iup.flattoggle({ TITLE = "", THEMEROLE = "flattoggle", VALUE = system_theme:enabled() and "ON" or "OFF" })
		function follow:valuechanged_cb()
			if not system_theme:setEnabled(iup.GetAttribute(follow, "VALUE") == "ON") then
				iup.SetAttribute(follow, "VALUE", system_theme:enabled() and "ON" or "OFF")
			end
			return iup.DEFAULT
		end
		entries[#entries + 1] = {
			label = "Match system theme",
			description = "Follow the system's light or dark mode (on Windows: Settings > Personalization > "
				.. "Colors; on Linux: the desktop's light/dark style). Switching mode by hand turns this off.",
			widget = manage(follow, "theme"),
		}
	end

	themes:onApply(function()
		iup.SetAttribute(dark_mode, "VALUE", is_dark() and "ON" or "OFF")
		if follow then iup.SetAttribute(follow, "VALUE", system_theme:enabled() and "ON" or "OFF") end
		if not settings:isLocked("theme") then
			iup.SetAttribute(dark_mode, "ACTIVE", themes:counterpart(themes:current()) and "YES" or "NO")
		end
	end)

	entries[#entries + 1] = {
		label = "Interface motion",
		description = "Animate tab switches, tab dragging and group creation. "
			.. "Turn this off for an instant, static interface.",
		widget = toggle("motion_enabled", "enabled"),
	}
	entries[#entries + 1] = {
		label = "Motion speed",
		description = "Scales the duration of every animation.",
		widget = speed,
	}
	entries[#entries + 1] = {
		label = "Follow system motion setting",
		description = "Disable interface motion automatically when the system is set to "
			.. "reduce animations (on Windows: Settings > Accessibility > Visual effects).",
		widget = toggle("motion_respect_system", "respect_system"),
	}

	opts.host:addSettings("Appearance", { entries = entries, icon = "color-palette" })
end

return M
