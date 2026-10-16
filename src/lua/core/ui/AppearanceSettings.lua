--- The host's own "Appearance" settings section: theme and interface motion.
--
-- The theme selector stays in sync with the top-bar Theme menu (both come from
-- `ThemeManager`). A setting the org profile locks shows greyed out with a note,
-- and a change is applied only when the write succeeded.
--
-- @module core.ui.AppearanceSettings

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
		local t = iup.toggle({ TITLE = "", VALUE = (settings:get(key) ~= false) and "ON" or "OFF" })
		function t:action(state)
			local on = (state == 1)
			if set_and_save(key, on) then motion:configure({ [configure_key] = on }) end
			return iup.DEFAULT
		end
		return manage(t, key)
	end

	local speed = iup.list({ DROPDOWN = "YES", VISIBLEITEMS = #M.SPEEDS + 1, EXPAND = "HORIZONTAL" })
	for i, label in ipairs(M.SPEEDS) do
		iup.SetAttribute(speed, tostring(i), label)
	end
	iup.SetAttribute(speed, "VALUE", tostring(M.speed_index(settings:get("motion_scale"))))
	function speed:action(_text, item, state)
		if state ~= 1 then return iup.DEFAULT end
		local scale = M.SPEED_VALUES[item]
		if scale and set_and_save("motion_scale", scale) then
			motion:configure({ scale = scale })
		end
		return iup.DEFAULT
	end
	manage(speed, "motion_scale")

	opts.host:addSettings("Appearance", {
		entries = {
			{
				label = "Theme",
				description = "Switch the application color theme. Affects all tabs and extensions.",
				widget = manage(opts.theme_manager:buildDropdown(), "theme"),
			},
			{
				label = "Interface motion",
				description = "Animate tab switches, tab dragging and group creation. "
					.. "Turn this off for an instant, static interface.",
				widget = toggle("motion_enabled", "enabled"),
			},
			{
				label = "Motion speed",
				description = "Scales the duration of every animation.",
				widget = speed,
			},
			{
				label = "Follow system motion setting",
				description = "Disable interface motion automatically when the system is set to "
					.. "reduce animations (on Windows: Settings > Accessibility > Visual effects).",
				widget = toggle("motion_respect_system", "respect_system"),
			},
		},
	})
end

return M
