--- Modal dialog for opening a `lunar://` addressable view or plugin action.
-- Presents a text input pre-filled with an optional default value, a status label
-- for error feedback, and Open/Cancel buttons.  The dialog dispatches the entered
-- address through `host:dispatchRoute` and closes only on success; errors are
-- surfaced in the status label so the user can correct the address without reopening.
--
-- @module core.ui.AddressDialog

local L = require("core.lib.CarbonLayout")
local ModalMotion = require("core.ui.ModalMotion")

local AddressDialog = {}

--- Show the address dialog and block until the user opens or cancels.
-- **opts fields:**
--
-- * `iup` `userdata` *(required)* — IUP library reference.
-- * `host` `table` *(required)* — host object with a `dispatchRoute(uri)` method.
-- * `value` `string` *(optional)* — pre-filled text in the input box.
-- * `parent` `userdata` *(optional)* — IUP dialog handle for `PARENTDIALOG` centering.
-- * `notify_tree_change` `function(dlg)` *(optional)* — called with the new dialog
--   handle so the host can register it for theme-tree updates.
--
-- @tparam table opts Options (see above).
function AddressDialog.show(opts)
	opts = opts or {}
	local iup = assert(opts.iup, "AddressDialog.show requires iup")
	local host = assert(opts.host, "AddressDialog.show requires host")
	-- Flat controls throughout: a native IupButton paints itself from the system
	-- theme and ignores BGCOLOR, so it stays light (and flashes the shell's blue
	-- on hover) under every dark Lunar theme. The entry drops its native sunken
	-- border and takes a themed one from a flatframe instead -- IUP has no flat
	-- text-entry control, so this is how the rest of the host themes an input
	-- (see core.ui.FolderDialog, core.ui.NameDialog).
	local input = iup.text({
		VALUE = opts.value or "",
		EXPAND = "HORIZONTAL",
		VISIBLECOLUMNS = "72",
		FONT = "Segoe UI, 9",
		BORDER = "NO",
		THEMEROLE = "text",
	})
	local status = iup.label({
		TITLE = "Enter a lunar:// address.",
		EXPAND = "HORIZONTAL",
		THEMEROLE = "settingslabel",
	})
	local open_btn = iup.flatbutton({
		TITLE = "Open", THEMEROLE = "primary_btn", PADDING = "12x5",
	})
	local cancel_btn = iup.flatbutton({
		TITLE = "Cancel", THEMEROLE = "actionbutton", PADDING = "12x5",
	})
	local dlg

	local function try_open()
		local ok, result = host:dispatchRoute(iup.GetAttribute(input, "VALUE") or "")
		if ok then
			ModalMotion.result(iup, dlg, "confirm")
			iup.Hide(dlg)
		else
			status.TITLE = result and result.message or "Unable to open address."
			iup.Refresh(status)
		end
		return iup.DEFAULT
	end

	local function cancel()
		ModalMotion.result(iup, dlg, "cancel")
		iup.Hide(dlg)
		return iup.DEFAULT
	end

	-- flat_action, not action: that is the callback IupFlatButton fires.
	function open_btn:flat_action()
		return try_open()
	end

	function cancel_btn:flat_action()
		return cancel()
	end

	dlg = iup.dialog({
		iup.vbox({
			iup.label({
				TITLE = "Open an addressable Lunar view or plugin action.",
				THEMEROLE = "settingslabel",
			}),
			iup.flatframe({
				input, TITLE = "", MARGIN = L.margin(1),
				EXPAND = "HORIZONTAL", THEMEROLE = "text",
			}),
			status,
			iup.hbox({ iup.fill({}), open_btn, cancel_btn, GAP = L.gap(3), ALIGNMENT = "ACENTER" }),
			MARGIN = L.margin(5),
			GAP = L.gap(4),
		}),
		TITLE = "Open Lunar Address",
		-- Win32 ICON RESOURCE name from assets/Lunar.rc, so popups
		-- carry the app icon in their title bar and Alt-Tab entry too.
		ICON = "IUP",
		DIALOGFRAME = "YES",
		RESIZE = "NO",
		PARENTDIALOG = opts.parent,
		-- DEFAULTENTER/DEFAULTESC are deliberately NOT set.
		--
		-- They look like they support flat buttons -- iup_key.c explicitly accepts
		-- IupClassMatch(bt, "flatbutton") -- but they then call iupdrvActivate,
		-- which on Windows posts WM_COMMAND/BN_CLICKED to the parent. That is how a
		-- NATIVE button reports a click. A flatbutton is a canvas and raises
		-- FLAT_ACTION from its own BUTTON_CB, so the message goes nowhere and the
		-- key silently does nothing. The dialog handles both keys itself below.
	})

	function dlg:k_any(c)
		if c == iup.K_CR then return try_open() end
		if c == iup.K_ESC then return cancel() end
		return iup.DEFAULT
	end

	if opts.notify_tree_change then opts.notify_tree_change(dlg) end
	ModalMotion.popup(iup, dlg)
	iup.Destroy(dlg)
end

return AddressDialog
