--- Modal single-line text prompt, drawn entirely with flat controls.
--
-- A themed replacement for `iup.GetText` / `iup.scanf` / `iup.GetParam`, all of
-- which build their own native window and would reintroduce the light-on-dark
-- problem the theme system exists to remove. Used for naming and renaming tab
-- groups; general enough for any short "what should this be called" question.
--
-- ### Why each control is what it is
--
-- * Buttons are flat buttons (`ui.Button`), not `iup.button`. A native Win32 button
--   paints itself from the system theme and ignores `BGCOLOR`, so it stays light on a
--   dark theme and flashes the shell's blue on hover.
-- * The entry is `iup.text` (`ui.Input`) because IUP has no flat text-entry control,
--   but it is given `BORDER="NO"` (which removes the native 3D edge) and wrapped in a
--   flat frame that supplies a themed border instead. This is the same arrangement
--   `core.ui.FolderDialog` uses for its own prompts.
--
-- Every control carries a theme role so `core.classes.ThemeManager` can colour it, and
-- the finished dialog is handed to `notify_tree_change` before it is shown so the
-- active theme is applied to the whole tree.
--
-- It is shown through `core.ui.ModalMotion` rather than `iup.Popup` directly, so
-- it dims the page behind it and rises into place like every other modal in the
-- host, and so confirming reads differently from cancelling.
--
-- @module core.ui.NameDialog

local L = require("core.lib.CarbonLayout")
local ModalMotion = require("core.ui.ModalMotion")
local ui = require("core.lui")

local NameDialog = {}

local FONT = "Segoe UI, 11"

--- The prompt as a component. `p.finish(kind, text)` closes it ("confirm" or "cancel").
function NameDialog.Prompt(p)
	local value, setValue = ui.useState(p.value or "")
	local function accept() return p.finish("confirm", value) end
	local function cancel() return p.finish("cancel") end
	return ui.Dialog{
		title = p.title or "Name",
		-- Win32 ICON RESOURCE name from assets/Lunar.rc, so popups carry
		-- the app icon in their title bar and Alt-Tab entry too.
		ICON = "IUP", RASTERSIZE = "380x150", SHRINK = "YES", PARENTDIALOG = p.parent,
		-- DEFAULTENTER/DEFAULTESC are deliberately NOT set: on Windows IUP activates a
		-- default button by posting BN_CLICKED, which a flat button never receives.
		-- Enter and Escape are handled here instead, so they work from the entry too
		-- (K_ANY propagates from the focused control up to the dialog).
		onKey = function(c)
			if c == p.iup.K_CR then return accept() end
			if c == p.iup.K_ESC then return cancel() end
		end,
		ui.VBox{ padding = L.margin(4), gap = L.gap(3),
			ui.Label{ p.label or "Name:", font = FONT, role = "settingslabel" },
			ui.Frame{ title = "", padding = L.margin(1), expand = "horizontal", role = "text",
				-- SELECTION=ALL on open, so typing replaces the pre-filled text
				ui.Input{ value = value, onChange = setValue, expand = "horizontal", columns = 28,
					font = FONT, border = false, role = "text", SELECTION = "ALL" },
			},
			ui.HBox{ gap = L.gap(3), align = "center",
				ui.Spacer{},
				ui.Button{ p.ok or "OK", role = "primary_btn", padding = { 12, 5 }, onClick = accept },
				ui.Button{ "Cancel", role = "actionbutton", padding = { 12, 5 }, onClick = cancel },
			},
		},
	}
end

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
	local result, dlg
	local props = {}
	for k, v in pairs(opts) do props[k] = v end
	function props.finish(kind, text)
		if kind == "confirm" then
			text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
			result = (text ~= "") and text or nil
		else
			result = nil
		end
		ModalMotion.result(iup, dlg, kind)
		return iup.CLOSE
	end
	local root = ui.mount(NameDialog.Prompt, { iup = iup, props = props, theme = false })
	dlg = root:widget()
	if opts.notify_tree_change then pcall(opts.notify_tree_change, dlg) end
	ModalMotion.popup(iup, dlg)
	root:unmount()
	return result
end

return NameDialog
