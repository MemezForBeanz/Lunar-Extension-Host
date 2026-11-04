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
		title = "Welcome to Lunar",
		body = table.concat({
			"Lunar puts your team's tools in one window.",
			"",
			"Each tab is a tool. Settings holds every option in one place,",
			"and Ctrl+P finds any command.",
		}, "\n"),
	},
	{
		title = "Your organization's tools",
		body = table.concat({
			"Every tab other than Settings comes from an extension.",
			"",
			"Your organization may install a pack with its own tools and defaults.",
			"The Window Diagnostics command shows which pack is active.",
		}, "\n"),
	},
	{
		title = "Help and feedback",
		body = table.concat({
			"Find this tour again under Help in the menu.",
			"",
			"Feedback shows you the report and the workstation details first.",
			"Nothing is sent automatically.",
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

	local title_lbl = iup.flatlabel({ TITLE = "", THEMEROLE = "sectiontitle", EXPAND = "HORIZONTAL" })
	-- A label, not a text field: this is reading, and a field brings native scrollbars.
	local body_text = iup.flatlabel({
		TITLE = "", THEMEROLE = "settingslabel", EXPAND = "YES", ALIGNMENT = "ALEFT:ATOP",
	})
	local page_lbl = iup.flatlabel({ TITLE = "", THEMEROLE = "hint", EXPAND = "HORIZONTAL" })

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
		iup.SetAttribute(body_text, "TITLE", page.body)
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
			body_text,
			iup.hbox({
				page_lbl,
				back_btn,
				dismiss_btn,
				next_btn,
				GAP = L.gap(3),
				ALIGNMENT = "ACENTER",
			}),
			MARGIN = L.margin(6),
			GAP = L.gap(4),
		}),
		TITLE = "Welcome",
		-- Win32 ICON RESOURCE name from assets/Lunar.rc.
		ICON = "IUP",
		SIZE = "300x120",
		SHRINK = "YES",
		RESIZE = "NO",
		MINBOX = "NO",
		MAXBOX = "NO",
	})

	-- The primary action starts focused, so its neighbour doesn't wear the focus ring.
	if iup.SetHandle then
		iup.SetHandle("welcome_tour_next", next_btn)
		iup.SetAttribute(dlg, "STARTFOCUS", "welcome_tour_next")
	end
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
