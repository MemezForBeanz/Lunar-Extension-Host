--- Feedback dialog that lets the user edit, send, copy, or save a pre-filled draft.
-- The draft template includes the app version, current Lunar address, and loaded extension list.
-- Sending submits to the configured backend via an optional `opts.submit` callback; the dialog never
-- sends anything automatically.
--
-- @module core.ui.FeedbackDialog

local L = require("core.lib.CarbonLayout")
local ModalMotion = require("core.ui.ModalMotion")

local M = {}

local function join_lines(lines)
	return table.concat(lines, "\n")
end

local function build_extension_lines(host)
	local lines = {}
	if not host or type(host.listLoadedExtensions) ~= "function" then
		return lines
	end
	for _, manifest in ipairs(host:listLoadedExtensions()) do
		lines[#lines + 1] = string.format(
			"- %s v%s (%s)",
			tostring(manifest.name or "Extension"),
			tostring(manifest.version or "?"),
			tostring(manifest.id or "?")
		)
	end
	return lines
end

local function build_template(opts)
	local app = opts.app or {}
	local host = opts.host
	local address = opts.route or ""
	if address == "" and host and host.currentRoute then
		local uri = host:currentRoute()
		if uri then
			address = uri
		end
	end

	local lines = {
		"Lunar Extension Host feedback",
		"",
		string.format("App: %s v%s", tostring(app.title or "Lunar Extension Host"), tostring(app.version or "?")),
		"Current address: " .. (address ~= "" and address or "(not available)"),
		"",
		"Loaded extensions:",
	}
	local ext_lines = build_extension_lines(host)
	if #ext_lines == 0 then
		lines[#lines + 1] = "- (none)"
	else
		for _, line in ipairs(ext_lines) do
			lines[#lines + 1] = line
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Notes:"
	lines[#lines + 1] = "- "
	return join_lines(lines)
end

local function write_text(path, text)
	local f, err = io.open(path, "wb")
	if not f then
		return nil, err
	end
	f:write(text or "")
	f:close()
	return true
end

--- Show the feedback dialog and block until the user closes it.
-- The draft is pre-filled with app info, the current route, and loaded extensions.
-- **opts fields:**
--
-- * `iup` `userdata` *(required)* — IUP library reference.
-- * `app` `table` *(optional)* — table with `title` and `version` strings for the draft header.
-- * `host` `table` *(optional)* — host object; `host:listLoadedExtensions()` populates
--   the extension list and `host:currentRoute()` populates the current address.
-- * `route` `string` *(optional)* — explicit current address override (takes precedence over
--   `host:currentRoute()`).
-- * `submit` `function(text, done)` *(optional)* — sends the draft to the backend and calls
--   `done(result, err)` when it finishes (later, without blocking the window, or at once).
--   When `nil` the Send button is disabled. `result` may be a table with a `feedback_id` field.
-- * `set_status` `function(msg)` *(optional)* — host status-bar callback for send/copy/save events.
-- * `parent` `userdata` *(optional)* — IUP dialog handle for `PARENTDIALOG`.
-- * `notify_tree_change` `function(dlg)` *(optional)* — called with the dialog handle for
--   theme-tree registration.
--
-- @tparam[opt] table opts Options (see above).
function M.show(opts)
	opts = opts or {}
	local iup = opts.iup
	if not iup then
		return
	end

	local notice = iup.label({
		TITLE = "Send stores this draft on the feedback backend with your IP address, user name, host name, app version, and current Lunar address.",
		FONT = "Segoe UI, 9",
		FGCOLOR = "120 120 120",
		EXPAND = "HORIZONTAL",
	})
	local draft = iup.text({
		MULTILINE = "YES",
		BORDER = "NO",
		EXPAND = "YES",
		VISIBLELINES = "14",
		FONT = "Consolas, 9",
		VALUE = build_template(opts),
		THEMEROLE = "text",
	})
	local send_btn = iup.flatbutton({
		TITLE = "Send Feedback",
		THEMEROLE = "primary_btn",
		PADDING = "12x6",
		ACTIVE = opts.submit and "YES" or "NO",
	})
	local copy_btn = iup.flatbutton({
		TITLE = "Copy Draft",
		THEMEROLE = "actionbutton",
		PADDING = "12x6",
	})
	local save_btn = iup.flatbutton({
		TITLE = "Save Draft...",
		THEMEROLE = "actionbutton",
		PADDING = "12x6",
	})
	local close_btn = iup.flatbutton({
		TITLE = "Close",
		THEMEROLE = "actionbutton",
		PADDING = "12x6",
	})
	local dlg
	local closed = false

	-- Called when the backend answers. The dialog may have been closed by then,
	-- in which case the outcome goes to the status bar only.
	local function sent(result, err)
		local id = type(result) == "table" and result.feedback_id or nil
		if opts.set_status then
			opts.set_status(not result and ("Feedback not sent: " .. tostring(err))
				or id and ("Feedback #" .. tostring(id) .. " sent.") or "Feedback sent.")
		end
		if closed then return end
		iup.SetAttribute(send_btn, "TITLE", "Send Feedback")
		iup.SetAttribute(send_btn, "ACTIVE", "YES")
		if not result then
			iup.Message("Feedback", "Unable to send feedback:\n" .. tostring(err))
			return
		end
		iup.Message("Feedback", id and ("Feedback #" .. tostring(id) .. " was sent.")
			or "Feedback was sent.")
		ModalMotion.result(iup, dlg, "confirm")
		iup.Hide(dlg)
	end

	function send_btn:flat_action()
		local text = iup.GetAttribute(draft, "VALUE") or ""
		if text:match("^%s*$") then
			iup.Message("Feedback", "Enter feedback before sending.")
			return iup.DEFAULT
		end
		if not opts.submit then
			iup.Message("Feedback", "No feedback backend is configured.")
			return iup.DEFAULT
		end

		iup.SetAttribute(send_btn, "ACTIVE", "NO")
		iup.SetAttribute(send_btn, "TITLE", "Sending...")
		opts.submit(text, sent)
		return iup.DEFAULT
	end

	function copy_btn:flat_action()
		local clip = iup.clipboard({})
		iup.SetAttribute(clip, "TEXT", iup.GetAttribute(draft, "VALUE") or "")
		iup.Destroy(clip)
		if opts.set_status then
			opts.set_status("Feedback draft copied to clipboard.")
		end
		return iup.DEFAULT
	end

	function save_btn:flat_action()
		local fd = iup.filedlg({
			DIALOGTYPE = "SAVE",
			TITLE = "Save Feedback Draft",
			EXTFILTER = "Text files|*.txt|Markdown files|*.md|All files|*.*|",
			FILE = "lunar-feedback.txt",
		})
		iup.Popup(fd, iup.CENTER, iup.CENTER)
		local status = iup.GetAttribute(fd, "STATUS")
		local path = iup.GetAttribute(fd, "VALUE")
		iup.Destroy(fd)
		if status == "-1" or not path or path == "" then
			return iup.DEFAULT
		end
		local ok, err = write_text(path, iup.GetAttribute(draft, "VALUE") or "")
		if not ok then
			iup.Message("Feedback", "Unable to save draft:\n" .. tostring(err))
		elseif opts.set_status then
			opts.set_status("Feedback draft saved to " .. path)
		end
		return iup.DEFAULT
	end

	function close_btn:flat_action()
		ModalMotion.result(iup, dlg, "cancel")
		return iup.CLOSE
	end

	dlg = iup.dialog({
		iup.vbox({
			notice,
			iup.flatframe({
				draft,
				TITLE = "",
				MARGIN = L.margin(2),
				EXPAND = "YES",
				THEMEROLE = "settingspanel",
			}),
			iup.hbox({
				send_btn,
				copy_btn,
				save_btn,
				iup.fill({}),
				close_btn,
				GAP = L.gap(3),
				ALIGNMENT = "ACENTER",
			}),
			MARGIN = L.margin(4),
			GAP = L.gap(3),
		}),
		TITLE = "Feedback",
		-- Win32 ICON RESOURCE name from assets/LunarExtensionHost.rc, so popups
		-- carry the app icon in their title bar and Alt-Tab entry too.
		ICON = "IUP",
		-- RASTERSIZE (pixels), NOT SIZE. IUP's SIZE is in font-relative dialog
		-- units, so "620x420" resolved to roughly 1080x840 px at Segoe UI 9 --
		-- taller than a 768p laptop screen, which pushed the button row under the
		-- taskbar and made Close unreachable.
		RASTERSIZE = "640x480",
		MINSIZE = "420x300",
		SHRINK = "YES",
		PARENTDIALOG = opts.parent,
	})

	if opts.notify_tree_change then
		opts.notify_tree_change(dlg)
	end
	ModalMotion.popup(iup, dlg, { x = iup.CENTER, y = iup.CENTER })
	closed = true
	iup.Destroy(dlg)
end

return M
