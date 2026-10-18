--- Multi-page welcome tour dialog shown on first launch.
-- Walks the user through three pages: a Lunar overview, extensions and org packs,
-- and help/feedback resources.  Persists completion or dismissal through the
-- `SettingsManager` keys `welcome_tour_completed` and `welcome_tour_dismissed`.
--
-- @module core.ui.WelcomeTour

local L = require("core.lib.CarbonLayout")
local ModalMotion = require("core.ui.ModalMotion")

local M = {}

local PAGES = {
	{
		title = "Welcome to Lunar Extension Host",
		body = table.concat({
			"Lunar Extension Host is a desktop host for tool extensions.",
			"",
			"Use the tabs for feature work, the host-owned Settings tab for configuration,",
			"and the Help menu for onboarding, shortcuts, and feedback.",
		}, "\n"),
	},
	{
		title = "Extensions and your organization",
		body = table.concat({
			"Every tab other than Settings comes from an extension.",
			"Extensions -> Reload Extensions picks up changes without restarting.",
			"",
			"Your organization may install a pack that adds its tools, in a tab group of",
			"their own, and sets defaults. Help -> Window Diagnostics... shows which pack",
			"is active and why.",
		}, "\n"),
	},
	{
		title = "Help and feedback",
		body = table.concat({
			"Need this tour again? Open Help -> Welcome Tour...",
			"",
			"When a feedback backend is configured, Help -> Feedback... sends an editable",
			"report to it and shows the workstation details attached.",
			"It never sends anything automatically: you choose whether to copy or save it.",
		}, "\n"),
	},
}

-- These keys must match the ones SettingsManager declares in DEFAULTS and that
-- main.lua checks on startup; anything else is silently dropped when settings
-- are reloaded, which makes the tour reappear on every launch.
local COMPLETED_KEY = "welcome_tour_completed"
local DISMISSED_KEY = "welcome_tour_dismissed"

local function persist(settings, result)
	if not settings then
		return
	end
	if result == "completed" then
		settings:set(COMPLETED_KEY, true)
		settings:set(DISMISSED_KEY, false)
	elseif not settings:get(COMPLETED_KEY) then
		settings:set(DISMISSED_KEY, true)
	else
		-- Re-opened from Help and closed again: keep the completed flag intact.
		return
	end
	if type(settings.save) == "function" then
		pcall(function() settings:save() end)
	end
end

--- Show the welcome tour dialog and block until the user completes or dismisses it.
-- Persists the result to `settings` when provided.
-- **opts fields:**
--
-- * `iup` `userdata` *(required)* — IUP library reference.
-- * `settings` `table` *(optional)* — `SettingsManager` instance; used to persist
--   `welcome_tour_completed` / `welcome_tour_dismissed`.
-- * `notify_tree_change` `function(dlg)` *(optional)* — called with the dialog handle
--   so the host can register it for theme-tree updates.
--
-- @tparam[opt] table opts Options (see above).
-- @treturn string `"completed"` when the user clicked Finish, `"dismissed"` otherwise.
function M.show(opts)
	opts = opts or {}
	local iup = opts.iup
	local settings = opts.settings
	if not iup then
		return
	end

	local index = 1
	local result = "dismissed"

	local title_lbl = iup.label({
		TITLE = "",
		FONT = "Segoe UI, Bold 13",
		EXPAND = "HORIZONTAL",
	})
	local body_text = iup.text({
		MULTILINE = "YES",
		READONLY = "YES",
		BORDER = "NO",
		CANFOCUS = "NO",
		EXPAND = "YES",
		VISIBLELINES = "10",
		FONT = "Segoe UI, 10",
		THEMEROLE = "text",
	})
	local page_lbl = iup.label({
		TITLE = "",
		FONT = "Segoe UI, 8",
		FGCOLOR = "120 120 120",
	})

	local back_btn = iup.flatbutton({
		TITLE = "Back",
		THEMEROLE = "actionbutton",
		PADDING = "12x6",
	})
	local next_btn = iup.flatbutton({
		TITLE = "Next",
		THEMEROLE = "primary_btn",
		PADDING = "12x6",
	})
	local dismiss_btn = iup.flatbutton({
		TITLE = "Not Now",
		THEMEROLE = "actionbutton",
		PADDING = "12x6",
	})

	local dlg

	local function render()
		local page = PAGES[index]
		iup.SetAttribute(title_lbl, "TITLE", page.title)
		iup.SetAttribute(body_text, "VALUE", page.body)
		iup.SetAttribute(page_lbl, "TITLE", string.format("Step %d of %d", index, #PAGES))
		iup.SetAttribute(back_btn, "ACTIVE", index > 1 and "YES" or "NO")
		iup.SetAttribute(next_btn, "TITLE", index < #PAGES and "Next" or "Finish")
	end

	function back_btn:flat_action()
		if index > 1 then
			index = index - 1
			render()
		end
		return iup.DEFAULT
	end

	function next_btn:flat_action()
		if index < #PAGES then
			index = index + 1
			render()
		else
			result = "completed"
			ModalMotion.result(iup, dlg, "confirm")
			return iup.CLOSE
		end
		return iup.DEFAULT
	end

	function dismiss_btn:flat_action()
		result = "dismissed"
		ModalMotion.result(iup, dlg, "cancel")
		return iup.CLOSE
	end

	dlg = iup.dialog({
		iup.vbox({
			title_lbl,
			iup.flatframe({
				body_text,
				TITLE = "",
				MARGIN = L.margin(3),
				EXPAND = "YES",
				THEMEROLE = "settingspanel",
			}),
			page_lbl,
			iup.hbox({
				back_btn,
				iup.fill({}),
				dismiss_btn,
				next_btn,
				GAP = L.gap(3),
				ALIGNMENT = "ACENTER",
			}),
			MARGIN = L.margin(4),
			GAP = L.gap(3),
		}),
		TITLE = "Welcome Tour",
		-- Win32 ICON RESOURCE name from assets/Lunar.rc.
		ICON = "IUP",
		SIZE = "420x260",
		SHRINK = "YES",
	})

	if opts.notify_tree_change then
		opts.notify_tree_change(dlg)
	end
	render()
	ModalMotion.popup(iup, dlg, { x = iup.CENTER, y = iup.CENTER })
	iup.Destroy(dlg)
	-- Persist after the popup returns so every exit path is recorded, including
	-- closing the dialog from the title-bar close button.
	persist(settings, result)
	return result
end

return M
