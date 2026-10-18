--- The installer window: the same pages on Windows and Linux.
--
--   Install:   Welcome and license -> Install type -> Extensions -> Progress -> Done
--   Uninstall: Remove Lunar? -> Progress -> Done
--
-- The window knows nothing about either OS. It is handed a *backend*
-- (`installer.backend`) that says what to offer (install types, extensions) and
-- starts the work; the work is a job the window polls on a timer:
--
--   * `backend.start(choices)` returns a job or nil and why
--   * `job:tick()` returns nil while running, then a result
--     `{ status = "ok"|"reboot"|"cancelled"|"error", message, detail }`
--   * `job:progress()` returns a fraction (nil = unknown) and a line of text
--
-- It is drawn with the host's flat controls and themed by `core.classes.ThemeManager`
-- (dark or light with the system), so it looks like Lunar.
--
-- @module installer.ui

local L = require("core.lib.CarbonLayout")
local platform = require("core.platform")

local M = {}

local FONT = "Segoe UI, 10"
local WIDTH = 560

local function heading(iup, text)
	return iup.label({ TITLE = text, FONT = "Segoe UI, Bold 15", THEMEROLE = "settingslabel", EXPAND = "HORIZONTAL" })
end

-- IUP measures a wrapped label as one line, so give it the height of the lines it
-- will take: about 76 characters of body text fit across the page (Windows' Segoe UI is
-- the widest of the fonts we meet).
local CHARS_PER_LINE, LINE_HEIGHT = 76, 20

local function line_count(text, width)
	local per = math.max(10, math.floor(CHARS_PER_LINE * (width or WIDTH) / WIDTH))
	local lines = 0
	for segment in (tostring(text) .. "\n"):gmatch("(.-)\n") do
		lines = lines + math.max(1, math.ceil(#segment / per))
	end
	return lines
end

local function paragraph(iup, text, muted, width)
	width = width or WIDTH
	return iup.label({
		TITLE = text, FONT = FONT, WORDWRAP = "YES", EXPAND = "HORIZONTAL",
		RASTERSIZE = width .. "x" .. (line_count(text, width) * LINE_HEIGHT),
		THEMEROLE = muted and "settingslabel_muted" or "settingslabel",
	})
end

local function toggle(iup, title, on)
	return iup.flattoggle({
		TITLE = title, VALUE = on and "ON" or "OFF", FONT = FONT, THEMEROLE = "flattoggle_noborder",
		PADDING = "4x4", EXPAND = "NO", ALIGNMENT = "ALEFT:ACENTER",
	})
end

local function button(iup, title, primary, width)
	return iup.flatbutton({
		TITLE = title, FONT = FONT, PADDING = "16x6", RASTERSIZE = width and (width .. "x") or nil,
		THEMEROLE = primary and "primary_btn" or "actionbutton",
	})
end

local function is_on(iup, ih) return iup.GetAttribute(ih, "VALUE") == "ON" end

-- Call `fn` when a flat toggle changes. (Callbacks must return IUP_DEFAULT: a flat
-- button or toggle whose action returns IUP_IGNORE never fires again.)
local function on_change(iup, ih, fn)
	function ih:valuechanged_cb() fn() return iup.DEFAULT end
end

--- Show the installer and run until it closes.
-- @tparam table backend see the module description, plus `kind` ("install" or
--   "uninstall"), `title`, `version`, `license`, `types`, `default_type`, `notice`,
--   `extensions`, `defaults`, `skipped`, `launchable`, `launch(choices)`.
-- @tparam table iup the IUP binding.
function M.run(backend, iup)
	platform.apply_native_style()
	local installing = backend.kind ~= "uninstall"
	local state = { choices = { type = backend.default_type, ids = {} }, job = nil, result = nil }
	local pages, page_index = {}, 1
	local dlg, zbox, back_btn, next_btn, cancel_btn
	local timer

	-- ---- pages -----------------------------------------------------------------
	local accept
	if installing then
		local license = iup.multiline({
			VALUE = backend.license or "", READONLY = "YES", WORDWRAP = "YES", EXPAND = "YES",
			BORDER = "NO", FONT = "Segoe UI, 9", THEMEROLE = "multiline", VISIBLELINES = "9",
		})
		accept = toggle(iup, "I accept the terms of the license agreement", false)
		pages[#pages + 1] = {
			id = "welcome",
			box = iup.vbox({
				heading(iup, "Welcome to Lunar " .. tostring(backend.version)),
				paragraph(iup, "Lunar is a desktop host for tool extensions. This wizard installs it on this computer."
					.. (backend.notice and ("\n\n" .. backend.notice) or "")),
				iup.flatframe({ license, MARGIN = L.margin(1), EXPAND = "YES", THEMEROLE = "text" }),
				accept,
				GAP = L.gap(3), MARGIN = "0x0",
			}),
			enter = function()
				iup.SetAttribute(next_btn, "TITLE", "Next")
			end,
			can_next = function() return is_on(iup, accept) end,
		}

		-- Install type: one row per choice, behaving as a radio group.
		local rows = {}
		local type_children = { heading(iup, "Install for") }
		local function select_type(id)
			state.choices.type = id
			for tid, row in pairs(rows) do iup.SetAttribute(row, "VALUE", tid == id and "ON" or "OFF") end
		end
		for _, t in ipairs(backend.types) do
			local row = toggle(iup, t.label, t.id == state.choices.type)
			rows[t.id] = row
			local function pick() select_type(t.id) end
			on_change(iup, row, pick)
			type_children[#type_children + 1] = row
			type_children[#type_children + 1] = iup.hbox({
				iup.fill({ RASTERSIZE = "28x1" }), paragraph(iup, t.description, true, WIDTH - 28), MARGIN = "0x0",
			})
		end
		if backend.type_note then type_children[#type_children + 1] = paragraph(iup, backend.type_note, true) end
		type_children.GAP = L.gap(3)
		type_children.MARGIN = "0x0"
		pages[#pages + 1] = {
			id = "type",
			box = iup.vbox(type_children),
			enter = function()
				iup.SetAttribute(next_btn, "TITLE", "Next")
				select_type(state.choices.type)
			end,
		}

		-- Extensions.
		local CheckList = require("core.ui.CheckList")
		local ext_list
		local exts = backend.extensions or {}
		local ext_children = {
			heading(iup, "Choose extensions"),
			paragraph(iup, "Lunar itself is always installed. Pick the extensions to install with it. "
				.. "Run setup again later to change the selection."),
		}
		if #exts > 0 then
			ext_list = CheckList:new(iup, {
				format = function(e)
					local line = e.name
					if e.version ~= "" then line = line .. "   " .. e.version end
					if e.description ~= "" then line = line .. "   -   " .. e.description end
					return line
				end,
				font = FONT,
				themerole = "list_bordered",
			})
			ext_list:setItems(exts)
			for i, e in ipairs(exts) do ext_list:setChecked(i, backend.defaults[e.id] ~= false) end
			local all = button(iup, "Select all")
			local none = button(iup, "Select none")
			function all:flat_action() ext_list:setAllSelected(true) for i = 1, #exts do ext_list:setChecked(i, true) end return iup.DEFAULT end
			function none:flat_action() for i = 1, #exts do ext_list:setChecked(i, false) end return iup.DEFAULT end
			ext_children[#ext_children + 1] = ext_list:widget()
			ext_children[#ext_children + 1] = iup.hbox({ all, none, iup.fill({}), GAP = L.gap(3), MARGIN = "0x0" })
		else
			ext_children[#ext_children + 1] = paragraph(iup, "This package contains no extensions.", true)
			ext_children[#ext_children + 1] = iup.fill({})
		end
		if backend.skipped and #backend.skipped > 0 then
			local names = {}
			for _, s in ipairs(backend.skipped) do names[#names + 1] = s.source .. " (" .. s.reason .. ")" end
			ext_children[#ext_children + 1] = paragraph(iup, "Not offered: " .. table.concat(names, "; "), true)
		end
		ext_children.GAP = L.gap(3)
		ext_children.MARGIN = "0x0"
		pages[#pages + 1] = {
			id = "extensions",
			box = iup.vbox(ext_children),
			enter = function() iup.SetAttribute(next_btn, "TITLE", "Install") end,
			leave = function()
				local ids = {}
				if ext_list then
					for i, e in ipairs(exts) do if ext_list:isChecked(i) then ids[#ids + 1] = e.id end end
				end
				state.choices.ids = ids
			end,
		}
	else
		pages[#pages + 1] = {
			id = "confirm",
			box = iup.vbox({
				heading(iup, "Remove Lunar?"),
				paragraph(iup, backend.confirm_text or "Lunar will be removed from this computer."),
				iup.fill({}),
				GAP = L.gap(3), MARGIN = "0x0",
			}),
			enter = function() iup.SetAttribute(next_btn, "TITLE", "Remove") end,
		}
	end

	-- Progress.
	local status_label = paragraph(iup, "", true)
	local bar = iup.progressbar({ EXPAND = "HORIZONTAL", MARQUEE = "YES", MAX = "1", VALUE = "0", RASTERSIZE = WIDTH .. "x16", THEMEROLE = "progressbar" })
	pages[#pages + 1] = {
		id = "progress",
		box = iup.vbox({
			heading(iup, installing and "Installing Lunar" or "Removing Lunar"),
			paragraph(iup, installing and "Please wait while Lunar is installed." or "Please wait while Lunar is removed."),
			bar, status_label, iup.fill({}),
			GAP = L.gap(4), MARGIN = "0x0",
		}),
		enter = function() end,
	}

	-- Done.
	local done_heading = heading(iup, "")
	local done_message = paragraph(iup, "")
	local done_detail = paragraph(iup, "", true)
	local launch = toggle(iup, "Launch Lunar", true)
	pages[#pages + 1] = {
		id = "done",
		box = iup.vbox({
			done_heading, done_message, done_detail, iup.fill({}), launch,
			GAP = L.gap(4), MARGIN = "0x0",
		}),
		enter = function() end,
	}

	-- ---- navigation ------------------------------------------------------------
	local function refresh_buttons()
		local id = pages[page_index].id
		local busy = id == "progress"
		local final = id == "done"
		iup.SetAttribute(back_btn, "ACTIVE", (page_index > 1 and not busy and not final) and "YES" or "NO")
		iup.SetAttribute(back_btn, "VISIBLE", (final or page_index == 1) and "NO" or "YES")
		iup.SetAttribute(cancel_btn, "ACTIVE", busy and "NO" or "YES")
		iup.SetAttribute(cancel_btn, "VISIBLE", final and "NO" or "YES")
		local can = true
		local p = pages[page_index]
		if p.can_next then can = p.can_next() end
		iup.SetAttribute(next_btn, "ACTIVE", (not busy and can) and "YES" or "NO")
		iup.SetAttribute(next_btn, "TITLE", final and "Finish" or iup.GetAttribute(next_btn, "TITLE"))
	end

	local function show(i)
		local old = pages[page_index]
		if old and old.leave then old.leave() end
		page_index = i
		local p = pages[i]
		zbox.VALUEPOS = tostring(i - 1)
		if p.enter then p.enter() end
		refresh_buttons()
	end

	local function finish_job(result)
		state.result = result
		local ok = result.status == "ok" or result.status == "reboot"
		iup.SetAttribute(done_heading, "TITLE",
			ok and (installing and "Lunar is installed" or "Lunar was removed")
			or (result.status == "cancelled" and "Setup was cancelled" or "Setup could not finish"))
		iup.SetAttribute(done_message, "TITLE", result.message or "")
		iup.SetAttribute(done_detail, "TITLE", result.detail or "")
		local can_launch = installing and ok and backend.launchable ~= false
		iup.SetAttribute(launch, "VISIBLE", can_launch and "YES" or "NO")
		iup.SetAttribute(launch, "VALUE", can_launch and "ON" or "OFF")
		show(#pages)
	end

	local function start_work()
		local job, err = backend.start(state.choices)
		if not job then
			local cancelled = err == "cancelled"
			finish_job({ status = cancelled and "cancelled" or "error",
				message = cancelled and "Administrator permission was not given, so nothing was changed."
					or ("Setup could not start: " .. tostring(err)) })
			return
		end
		state.job = job
		show(#pages - 1)
		timer.run = "YES"
	end

	timer = iup.timer({ TIME = "40", RUN = "NO" })
	function timer:action_cb()
		local job = state.job
		if not job then self.run = "NO" return iup.DEFAULT end
		local okc, result = pcall(job.tick, job)
		if not okc then result = { status = "error", message = "Setup failed unexpectedly.", detail = tostring(result) } end
		if result then
			self.run = "NO"
			state.job = nil
			iup.SetAttribute(bar, "MARQUEE", "NO")
			finish_job(result)
			return iup.DEFAULT
		end
		local fraction, text = job:progress()
		if fraction then
			iup.SetAttribute(bar, "MARQUEE", "NO")
			iup.SetAttribute(bar, "VALUE", tostring(fraction))
		else
			iup.SetAttribute(bar, "MARQUEE", "YES")
		end
		if text then iup.SetAttribute(status_label, "TITLE", text) end
		return iup.DEFAULT
	end

	-- ---- window ----------------------------------------------------------------
	back_btn = button(iup, "Back", false, 84)
	next_btn = button(iup, "Next", true, 84)
	cancel_btn = button(iup, "Cancel", false, 84)

	function back_btn:flat_action()
		if page_index > 1 then show(page_index - 1) end
		return iup.DEFAULT
	end
	function next_btn:flat_action()
		local id = pages[page_index].id
		if id == "done" then
			if state.result and (state.result.status == "ok" or state.result.status == "reboot")
				and is_on(iup, launch) and backend.launch then
				pcall(backend.launch, state.choices)
			end
			return iup.CLOSE
		end
		local p = pages[page_index]
		if p.can_next and not p.can_next() then return iup.DEFAULT end
		if pages[page_index + 1] and pages[page_index + 1].id == "progress" then
			if p.leave then p.leave() end
			start_work()
		else
			show(page_index + 1)
		end
		return iup.DEFAULT
	end
	function cancel_btn:flat_action() return iup.CLOSE end

	if accept then
		on_change(iup, accept, refresh_buttons)
	end

	local boxes = {}
	for _, p in ipairs(pages) do boxes[#boxes + 1] = p.box end
	boxes.EXPAND = "YES"
	zbox = iup.zbox(boxes)
	zbox.VALUEPOS = "0"

	dlg = iup.dialog({
		iup.vbox({
			iup.vbox({ zbox, MARGIN = L.margin(6, 5), EXPAND = "YES" }),
			iup.flatseparator({ ORIENTATION = "HORIZONTAL", THEMEROLE = "flatseparator" }),
			iup.hbox({
				iup.fill({}), back_btn, next_btn, cancel_btn,
				GAP = L.gap(3), MARGIN = L.margin(5, 4), ALIGNMENT = "ACENTER",
			}),
			MARGIN = "0x0", GAP = "0",
		}),
		TITLE = backend.title,
		ICON = "IUP",
		RASTERSIZE = "660x500",
		RESIZE = "NO", MAXBOX = "NO", MINBOX = "NO",
		THEMEROLE = "dialog",
	})
	function dlg:close_cb()
		if state.job then return iup.IGNORE end   -- no closing mid-install
		return iup.CLOSE
	end
	function dlg:k_any(c)
		if c == iup.K_ESC and not state.job then return iup.CLOSE end
		return iup.DEFAULT
	end

	-- Theme: dark or light with the system, like the app.
	local okt, ThemeManager = pcall(require, "core.classes.ThemeManager")
	if okt then
		local okn, tm = pcall(ThemeManager.new, ThemeManager, { iup = iup })
		if okn and tm then
			pcall(tm.setRoot, tm, dlg)
			local dark = platform.system_dark and platform.system_dark()
			pcall(tm.apply, tm, dark and "classic_dark" or "classic", { skip_save = true })
		end
	end

	if backend.icon_dir then pcall(platform.set_app_icon, backend.icon_dir) end
	if pages[1].enter then pages[1].enter() end
	refresh_buttons()
	iup.ShowXY(dlg, iup.CENTER, iup.CENTER)
	if backend.on_shown then backend.on_shown(dlg) end
	iup.MainLoop()
	iup.Destroy(dlg)
	return state
end

return M
