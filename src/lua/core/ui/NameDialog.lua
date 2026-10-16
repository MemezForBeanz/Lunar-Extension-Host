--- Modal single-line text prompt, drawn entirely with flat controls.
--
-- A themed replacement for `iup.GetText` / `iup.scanf` / `iup.GetParam`, all of
-- which build their own native window and would reintroduce the light-on-dark
-- problem the theme system exists to remove. Used for naming and renaming tab
-- groups; general enough for any short "what should this be called" question.
--
-- ### Why each control is what it is
--
-- * Buttons are `iup.flatbutton`, not `iup.button`. A native Win32 button paints
--   itself from the system theme and ignores `BGCOLOR`, so it stays light on a
--   dark theme and flashes the shell's blue on hover.
-- * The entry is `iup.text` because IUP has no flat text-entry control, but it is
--   given `BORDER="NO"` (which removes the native 3D edge) and wrapped in an
--   `iup.flatframe` that supplies a themed border instead. This is the same
--   arrangement `core.ui.FolderDialog` uses for its own prompts.
-- * `flat_action`, not `action`: that is the callback `IupFlatButton` fires.
--
-- Every control carries a `THEMEROLE` so `core.classes.ThemeManager` can colour
-- it, and the finished dialog is handed to `notify_tree_change` before it is
-- shown so the active theme is applied to the whole tree.
--
-- It is shown through `core.ui.ModalMotion` rather than `iup.Popup` directly, so
-- it dims the page behind it and rises into place like every other modal in the
-- host, and so confirming reads differently from cancelling.
--
-- @module core.ui.NameDialog

local L = require("core.lib.CarbonLayout")
local ModalMotion = require("core.ui.ModalMotion")

local NameDialog = {}

--- Show the prompt and block until the user confirms or cancels.
--
-- **opts fields:**
--
-- * `iup` `userdata` *(required)* — IUP library reference.
-- * `title` `string` *(optional)* — window caption.
-- * `label` `string` *(optional)* — text above the input.
-- * `value` `string` *(optional)* — pre-filled text, selected on open so typing replaces it.
-- * `ok` `string` *(optional)* — confirm button caption; defaults to `"OK"`.
-- * `parent` `userdata` *(optional)* — dialog handle for `PARENTDIALOG` centering.
-- * `notify_tree_change` `function(dlg)` *(optional)* — theme hook for the new dialog.
--
-- @tparam table opts Options (see above).
-- @treturn string|nil The trimmed text, or `nil` when cancelled or left empty.
function NameDialog.show(opts)
	opts = opts or {}
	local iup = assert(opts.iup, "NameDialog.show requires iup")

	local input = iup.text({
		VALUE = opts.value or "",
		EXPAND = "HORIZONTAL",
		VISIBLECOLUMNS = "28",
		FONT = "Segoe UI, 9",
		-- Drops the native sunken edge; the flatframe below draws a themed one.
		BORDER = "NO",
		THEMEROLE = "text",
		SELECTION = "ALL",
	})
	local ok_btn = iup.flatbutton({
		TITLE = opts.ok or "OK",
		THEMEROLE = "primary_btn",
		PADDING = "12x5",
	})
	local cancel_btn = iup.flatbutton({
		TITLE = "Cancel",
		THEMEROLE = "actionbutton",
		PADDING = "12x5",
	})

	local result, dlg

	local function accept()
		local text = tostring(iup.GetAttribute(input, "VALUE") or "")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		result = (text ~= "") and text or nil
		ModalMotion.result(iup, dlg, "confirm")
		return iup.CLOSE
	end

	function ok_btn:flat_action()
		return accept()
	end

	local function cancel()
		result = nil
		ModalMotion.result(iup, dlg, "cancel")
		return iup.CLOSE
	end

	function cancel_btn:flat_action()
		return cancel()
	end

	dlg = iup.dialog({
		iup.vbox({
			iup.label({
				TITLE = opts.label or "Name:",
				FONT = "Segoe UI, 9",
				THEMEROLE = "settingslabel",
			}),
			iup.flatframe({
				input,
				TITLE = "",
				MARGIN = L.margin(1),
				EXPAND = "HORIZONTAL",
				THEMEROLE = "text",
			}),
			iup.hbox({
				iup.fill({}), ok_btn, cancel_btn,
				GAP = L.gap(3), ALIGNMENT = "ACENTER",
			}),
			MARGIN = L.margin(4),
			GAP = L.gap(3),
		}),
		TITLE = opts.title or "Name",
		-- Win32 ICON RESOURCE name from assets/LunarExtensionHost.rc, so popups carry
		-- the app icon in their title bar and Alt-Tab entry too.
		ICON = "IUP",
		RASTERSIZE = "380x150",
		SHRINK = "YES",
		PARENTDIALOG = opts.parent,
		-- DEFAULTENTER/DEFAULTESC are deliberately NOT set. They appear to support
		-- flat buttons -- iup_key.c explicitly accepts IupClassMatch(bt,
		-- "flatbutton") -- but then call iupdrvActivate, which on Windows posts
		-- WM_COMMAND/BN_CLICKED to the parent: how a NATIVE button reports a click.
		-- A flatbutton is a canvas raising FLAT_ACTION from its own BUTTON_CB, so
		-- the message goes nowhere and the key silently does nothing.
	})

	-- Enter and Escape handled on the dialog, so they work from the entry too
	-- (K_ANY propagates from the focused control up to the dialog).
	function dlg:k_any(c)
		if c == iup.K_CR then return accept() end
		if c == iup.K_ESC then return cancel() end
		return iup.DEFAULT
	end

	if opts.notify_tree_change then pcall(opts.notify_tree_change, dlg) end
	ModalMotion.popup(iup, dlg)
	iup.Destroy(dlg)
	return result
end

return NameDialog
