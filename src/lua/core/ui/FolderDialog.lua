--- Themed, in-app folder picker built entirely from IUP flat controls.
--
-- Replaces `iup.filedlg{ DIALOGTYPE = "DIR" }` for folder selection. The native
-- Win32 folder browser is drawn by the shell and cannot be themed from Lua, so
-- under any Lunar dark theme it opens as a bright white window. IUP 3.32 has no global that swaps the native dialog for an internal
-- one -- `IupNewFileDlgOpen` only substitutes a *newer native* Vista+ dialog --
-- so the only way to honor the active theme is to build the picker from the same
-- flat controls the rest of the app uses. Every widget here carries a THEMEROLE,
-- so `ThemeManager:themeWidget(dlg)` (invoked through `notify_tree_change`)
-- paints it like any other Lunar surface.
--
-- ### Layout
--
--     +--------------------------------------------------------------+
--     | [<] [>] [^] [refresh]   Folder [ path.......... ] [new] [pin] |
--     +----------------+---------------------------------------------+
--     | PLACES         | [search] [ filter....................... ]  |
--     |   Home         | +-----------------------------------------+ |
--     |   Documents    | | (icon) subfolder                        | |
--     | FAVOURITES     | | (icon) subfolder                        | |
--     |   * pinned     | +-----------------------------------------+ |
--     | DRIVES         |                                             |
--     |   C:\  D:\     |                                             |
--     +----------------+---------------------------------------------+
--     | status                          [Select Folder]   [Cancel]   |
--     +--------------------------------------------------------------+
--
-- The sidebar is PERSISTENT rather than a mode the main list switches into: you
-- can see your pinned folders and drives without losing sight of where you
-- currently are, which is how every mainstream picker behaves. Both panes are
-- `iup.flatlist`s, so the whole dialog is themed flat controls end to end.
--
-- ### Icons
--
-- Rendered from the Carbon SVGs in `assets/Icons` through `core.ui.VectorIcon`.
-- Icons are strictly decorative: `VectorIcon.available` is `false` whenever the
-- LuaJIT FFI / NanoSVG bridge is missing, so every button also carries a text
-- title and every row is identified by its label. Nothing here is load-bearing.
--
-- @module core.ui.FolderDialog

local lfs = require("lfs")
local L = require("core.lib.CarbonLayout")
local filescan = require("core.lib.filescan")
local VectorIcon = require("core.ui.VectorIcon")
local ModalMotion = require("core.ui.ModalMotion")
local SplitMotion = require("core.lib.SplitMotion")

local FolderDialog = {}

-- Most-recent-first, de-duplicated, and capped so settings.json cannot grow
-- without bound.
local MAX_RECENTS = 12
local MAX_FAVOURITES = 50

local ROW_ICON_SIZE = 16
local BTN_ICON_SIZE = 16

-- Carbon glyph per row kind. `share` gets the share-specific folder icon so UNC
-- paths stay in the "folder" visual family while still being distinguishable --
-- teams often work from network shares, so that distinction earns its place.
local KIND_ICON = {
	folder    = "folder.svg",
	share     = "folder--shared.svg",
	drive     = "datastore.svg",
	locked    = "locked.svg",
	favourite = "star--filled.svg",
	recent    = "recently-viewed.svg",
	home      = "home.svg",
}

-- ===========================================================================
-- PATH HELPERS (pure; unit-testable without IUP)
-- ===========================================================================

-- Strip trailing separators, but never turn a drive root into a bare letter:
-- "C:\" must stay "C:\" because lfs cannot stat "C:".
local function normalize(path)
	path = tostring(path or ""):gsub("/", "\\")
	if path:match("^%a:\\?$") then
		return path:sub(1, 2) .. "\\"
	end
	return (path:gsub("\\+$", ""))
end

local function is_dir(path)
	return path ~= "" and lfs.attributes(path, "mode") == "directory"
end

local function is_unc(path)
	return path:match("^\\\\") ~= nil
end

-- Join that tolerates a parent which already ends in a separator (drive roots).
local function join(parent, child)
	if parent:match("\\$") then
		return parent .. child
	end
	return parent .. "\\" .. child
end

-- Trailing path component, used for sidebar labels ("ROMValidation" rather than
-- the full path, like the reference pickers).
local function basename(path)
	path = normalize(path)
	if path:match("^%a:\\$") then
		return path
	end
	return path:match("([^\\]+)$") or path
end

-- Parent directory, or nil when `path` is already a root that cannot be
-- ascended: a drive root ("C:\"), a UNC share root ("\\server\share") or a
-- bare UNC host ("\\server", which is not enumerable through lfs anyway).
local function parent_of(path)
	path = normalize(path)
	if path:match("^%a:\\$") then
		return nil
	end
	if path:match("^\\\\[^\\]+\\[^\\]+$") then
		return nil
	end
	-- Bare UNC host ("\\server") or just separators: there is nothing above a host
	-- that lfs can enumerate, and splitting it would yield a lone "\".
	if path:match("^\\+[^\\]*$") then
		return nil
	end
	local up = path:match("^(.*)\\[^\\]+$")
	if not up or up == "" then
		return nil
	end
	if up:match("^%a:$") then
		return up .. "\\"
	end
	-- Never hand back a path that is only separators.
	if up:match("^\\+$") then
		return nil
	end
	return up
end

-- Windows folder-name rules. Returns nil, reason when invalid. Enforced up-front
-- because lfs.mkdir reports a bare failure, and "it didn't work" is a miserable
-- error for a name that was never legal to begin with.
local RESERVED_NAMES = {
	con = true, prn = true, aux = true, nul = true,
	com1 = true, com2 = true, com3 = true, com4 = true, com5 = true,
	com6 = true, com7 = true, com8 = true, com9 = true,
	lpt1 = true, lpt2 = true, lpt3 = true, lpt4 = true, lpt5 = true,
	lpt6 = true, lpt7 = true, lpt8 = true, lpt9 = true,
}

local function validate_folder_name(name)
	name = tostring(name or "")
	if name:match("^%s*$") then
		return nil, "Enter a folder name."
	end

	if #name > 255 then
		return nil, "That name is too long."
	end

	if name:match('[\\/:%*%?"<>|]') then
		return nil, 'A folder name cannot contain  \\ / : * ? " < > |'
	end
	if name:match("[%. ]$") then
		return nil, "A folder name cannot end with a space or a period."
	end
	-- Reserved device names are rejected with or without an extension.
	if RESERVED_NAMES[(name:match("^([^%.]+)") or name):lower()] then
		return nil, '"' .. name .. '" is a reserved Windows device name.'
	end
	return name
end

-- Drive letters that exist, WITHOUT touching any of them.
--
-- GetLogicalDrives() returns a bitmask straight out of the kernel: no I/O, no
-- network, microseconds. The obvious alternative -- stat'ing A:\ through Z:\ --
-- is a trap on this machine specifically: a stat against a DISCONNECTED MAPPED
-- NETWORK DRIVE makes Windows attempt an SMB reconnect, which blocks for seconds
-- per letter. The Log Parser's "Map Drive" button creates exactly such mappings
-- (R:, V:, P:), so the picker was reliably paying several seconds of dead time on
-- first open, on the UI thread. That is the "slow first open".
--
-- The stat loop remains only as a fallback for a build without LuaJIT FFI.
local function list_drives()
	local drives = {}

	local ok_ffi, ffi = pcall(require, "ffi")
	if ok_ffi and ffi then
		-- cdef is per-Lua-state and raises if redeclared; pcall keeps a repeat
		-- require harmless (same pattern as core.lib.filescan).
		pcall(ffi.cdef, "unsigned long GetLogicalDrives(void);")
		local ok_call, mask = pcall(function() return tonumber(ffi.C.GetLogicalDrives()) end)
		if ok_call and mask and mask > 0 then
			for i = 0, 25 do
				if math.floor(mask / 2 ^ i) % 2 == 1 then
					drives[#drives + 1] = string.char(string.byte("A") + i) .. ":\\"
				end
			end
			return drives
		end
	end

	for byte = string.byte("A"), string.byte("Z") do
		local root = string.char(byte) .. ":\\"
		if lfs.attributes(root, "mode") == "directory" then
			drives[#drives + 1] = root
		end
	end
	return drives
end

-- Subdirectories of `path`, plus whether the directory could be read at all.
--
-- `filescan.listDir` returns {} both for an empty directory and for one that
-- denied access, which made an unreadable folder look identical to an empty one
-- -- the most confusing failure this dialog had. Only when the listing comes back
-- empty do we pay for a second `lfs.dir` probe to tell the two apart; that keeps
-- the common (non-empty) case at exactly one enumeration over the network share.
local function list_subdirs(path)
	local dirs = {}
	for _, entry in ipairs(filescan.listDir(path)) do
		if entry.dir then
			dirs[#dirs + 1] = entry.name
		end
	end
	if #dirs > 0 then
		table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
		return dirs, true
	end
	local ok, iter = pcall(lfs.dir, path)
	return dirs, (ok and iter ~= nil)
end

-- Case-insensitive path identity. Windows paths are case-insensitive, so the
-- favourites/recents lists must be too or the same folder lands in them twice.
local function same_path(a, b)
	return normalize(a):lower() == normalize(b):lower()
end

local function index_of_path(list, path)
	for i, p in ipairs(list) do
		if same_path(p, path) then
			return i
		end
	end
	return nil
end

-- Push `path` onto a most-recent-first list, removing any earlier occurrence so
-- re-selecting a folder promotes it rather than duplicating it.
local function push_recent(list, path, cap)
	local existing = index_of_path(list, path)
	if existing then
		table.remove(list, existing)
	end
	table.insert(list, 1, normalize(path))
	while #list > cap do
		table.remove(list)
	end
	return list
end

-- Expose the pure helpers for tests.
FolderDialog._normalize = normalize
FolderDialog._parent_of = parent_of
FolderDialog._basename = basename
FolderDialog._validate_folder_name = validate_folder_name
FolderDialog._push_recent = push_recent
FolderDialog._index_of_path = index_of_path

-- ===========================================================================
-- DIALOG
-- ===========================================================================

--- Show a modal folder picker and block until the user selects or cancels.
--
-- **opts fields:**
--
-- * `iup` `userdata` *(required)* — IUP library reference.
-- * `title` `string` *(optional)* — dialog caption. Defaults to `"Select Folder"`.
-- * `value` `string` *(optional)* — folder to open at. Falls back to the current
--   working directory when missing or non-existent.
-- * `icon_dir` `string` *(optional)* — directory holding the Carbon `.svg` icons.
--   Icons are skipped entirely when absent or when `VectorIcon.available` is false.
-- * `settings` `table` *(optional)* — `core.classes.SettingsManager`; persists
--   `folder_favourites` and `folder_recents`. Places are in-memory only without it.
-- * `parent` `userdata` *(optional)* — IUP dialog handle for `PARENTDIALOG`.
-- * `notify_tree_change` `function(dlg)` *(optional)* — called with the dialog handle
--   so the host can theme the new widget subtree.
--
-- @tparam table opts Options (see above).
-- @treturn string|nil the selected absolute folder path, or `nil` if cancelled.
function FolderDialog.show(opts)
	opts = opts or {}
	local iup = assert(opts.iup, "FolderDialog.show requires iup")
	local settings = opts.settings

	-- This picker is built around Windows paths (drive letters, UNC shares). On
	-- other systems use the desktop's own folder chooser, which already knows the
	-- user's places and mounts.
	if not require("core.platform").is_windows then
		local fd = iup.filedlg({
			DIALOGTYPE = "DIR",
			TITLE = opts.title or "Select Folder",
			DIRECTORY = opts.value,
			PARENTDIALOG = opts.parent,
		})
		fd:popup(iup.CENTERPARENT, iup.CENTERPARENT)
		local chosen = (tonumber(fd.status) or -1) ~= -1 and fd.value or nil
		iup.Destroy(fd)
		return chosen
	end

	local start = normalize(opts.value)
	if not is_dir(start) then
		start = normalize(lfs.currentdir() or "C:\\")
	end

	-- ---- state -----------------------------------------------------------
	local st = {
		current = start,
		rows = {},             -- main list, as displayed: { {label, path, kind}, ... }
		all_rows = {},         -- unfiltered source for the current folder
		side = {},             -- sidebar entries: { {label, path, kind, header}, ... }
		history = { start },   -- visited paths, oldest first
		hist_pos = 1,
		result = nil,
	}

	local favourites, recents = {}, {}
	if settings then
		local f, r = settings:get("folder_favourites"), settings:get("folder_recents")
		if type(f) == "table" then for _, p in ipairs(f) do favourites[#favourites + 1] = p end end
		if type(r) == "table" then for _, p in ipairs(r) do recents[#recents + 1] = p end end
	end

	local function persist()
		if not settings then return end
		settings:set("folder_favourites", favourites)
		settings:set("folder_recents", recents)
		pcall(function() settings:save() end)
	end

	-- ---- icon helpers ----------------------------------------------------
	local icons_on = VectorIcon.available and opts.icon_dir and opts.icon_dir ~= ""

	-- Returns an IUP image handle name, or nil when icons are unavailable. Every
	-- caller must tolerate nil -- that is the no-FFI fallback path.
	local function icon(file, size, rotation)
		if not icons_on then return nil end
		local ok, handle = pcall(VectorIcon.imageHandle, iup, {
			path = opts.icon_dir .. "\\" .. file,
			size = size or ROW_ICON_SIZE,
			color = VectorIcon.roleColor("neutral"),
			rotation = rotation,
		})
		return ok and handle or nil
	end

	-- ---- widgets ---------------------------------------------------------
	local path_text = iup.text({
		VALUE = st.current,
		EXPAND = "HORIZONTAL",
		-- Natural width driver. Keep it modest: with a large value the row's natural
		-- width exceeds the dialog and IUP shrinks/clips whatever sits to its right.
		VISIBLECOLUMNS = "30",
		FONT = "Consolas, 9",
		-- BORDER="NO" is what makes this stop looking like a native Win32 edit box:
		-- the flatframe below draws the (themed) border, and without this the
		-- control's own sunken OS border is drawn inside it as well.
		BORDER = "NO",
		THEMEROLE = "text",
	})
	local path_frame = iup.flatframe({
		path_text, TITLE = "", MARGIN = L.margin(1),
		EXPAND = "HORIZONTAL", THEMEROLE = "text",
	})

	local filter_text = iup.text({
		VALUE = "", EXPAND = "HORIZONTAL", VISIBLECOLUMNS = "20",
		FONT = "Segoe UI, 9", BORDER = "NO", THEMEROLE = "text",
	})
	local filter_frame = iup.flatframe({
		filter_text, TITLE = "", MARGIN = L.margin(1),
		EXPAND = "HORIZONTAL", THEMEROLE = "text",
	})

	-- Both panes are single-selection flatlists. FLATSCROLLBAR supplies the
	-- owner-drawn bar; the native SCROLLBAR stays OFF or a white Win32 bar stacks
	-- on top of it (the same trap as QueuePanel).
	-- VISIBLELINES is deliberately SMALL.
	--
	-- A dialog's natural size is computed purely from its child's natural size
	-- (iDialogComputeNaturalSizeMethod), and when that exceeds RASTERSIZE the
	-- dialog GROWS to fit rather than clipping -- which pushed Select/Cancel off
	-- the bottom of the screen. VISIBLELINES is what drives a list's natural
	-- height, and with 16px row icons each row is taller than a plain text row, so
	-- 16 rows blew past the 560px target on their own.
	--
	-- Both lists are EXPAND="YES", so this number does not limit how many rows are
	-- actually shown: it only sets the floor the dialog is sized from, and the
	-- lists stretch to fill whatever height RASTERSIZE gives them. Keeping it low
	-- means the dialog always opens at the size asked for.
	local function make_list(themerole, lines, cols)
		return iup.flatlist({
			EXPAND = "YES",
			VISIBLELINES = tostring(lines),
			VISIBLECOLUMNS = tostring(cols),
			FONT = "Segoe UI, 9",
			FLATSCROLLBAR = "YES",
			SCROLLBAR = "NO",
			THEMEROLE = themerole,
		})
	end
	-- The sidebar uses the borderless list role so it reads as a panel rather than
	-- a second boxed control next to the folder list.
	local side_list = make_list("list_plain", 8, 18)
	local dir_list = make_list("flatlist", 8, 34)

	local status_lbl = iup.label({
		TITLE = "", EXPAND = "HORIZONTAL",
		FONT = "Segoe UI, 9", THEMEROLE = "settingslabel_muted",
	})

	local function set_status(msg)
		pcall(iup.SetAttribute, status_lbl, "TITLE", msg or "")
	end

	-- Toolbar button: icon when available, text title otherwise, tooltip always.
	local function tool_btn(tip, icon_file, rotation)
		local handle = icon(icon_file, BTN_ICON_SIZE, rotation or 0)
		local btn = iup.flatbutton({
			TITLE = handle and "" or tip,
			TIP = tip,
			THEMEROLE = "actionbutton",
			PADDING = handle and "7x5" or "10x5",
		})
		if handle then pcall(iup.SetAttribute, btn, "IMAGE", handle) end
		return btn
	end

	local back_btn    = tool_btn("Back", "arrow--left.svg")
	local fwd_btn     = tool_btn("Forward", "arrow--right.svg")
	-- No arrow--up.svg in the icon set; VectorIcon caches per rotation, so the left
	-- arrow turned 90 degrees clockwise is a real up arrow at no extra asset cost.
	local up_btn      = tool_btn("Up one level", "arrow--left.svg", 90)
	local refresh_btn = tool_btn("Refresh", "renew.svg")
	local newdir_btn  = tool_btn("New folder", "folder--add.svg")
	local star_btn    = tool_btn("Pin this folder", "star.svg")

	local select_btn = iup.flatbutton({
		TITLE = "Select Folder", THEMEROLE = "primary_btn", PADDING = "14x6",
	})
	local cancel_btn = iup.flatbutton({
		TITLE = "Cancel", THEMEROLE = "actionbutton", PADDING = "14x6",
	})

	local dlg

	local function set_active(btn, on)
		pcall(iup.SetAttribute, btn, "ACTIVE", on and "YES" or "NO")
	end

	-- ---- sidebar ---------------------------------------------------------
	-- Section headings are ordinary rows flagged `header`; clicks on them are
	-- ignored. One list with inert headings is far less machinery than three
	-- stacked lists that would each need their selections cleared against the
	-- others, and it renders identically.
	local function rebuild_sidebar()
		st.side = {}
		local function add(label, path, kind, header)
			st.side[#st.side + 1] = { label = label, path = path, kind = kind, header = header }
		end

		add("PLACES", nil, nil, true)
		local home = os.getenv("USERPROFILE")
		if home and is_dir(home) then
			add("  Home", home, "home")
			for _, name in ipairs({ "Desktop", "Documents", "Downloads" }) do
				local p = join(home, name)
				if is_dir(p) then add("  " .. name, p, "folder") end
			end
		end

		if #favourites > 0 then
			add("FAVOURITES", nil, nil, true)
			for _, p in ipairs(favourites) do
				add("  " .. basename(p), p, "favourite")
			end
		end

		if #recents > 0 then
			add("RECENT", nil, nil, true)
			for _, p in ipairs(recents) do
				if not index_of_path(favourites, p) then
					add("  " .. basename(p), p, "recent")
				end
			end
		end

		add("DRIVES", nil, nil, true)
		for _, root in ipairs(list_drives()) do
			add("  " .. root, root, "drive")
		end

		pcall(iup.SetAttribute, side_list, "REMOVEITEM", "ALL")
		for i, entry in ipairs(st.side) do
			iup.SetAttribute(side_list, "APPENDITEM", entry.label)
			if not entry.header then
				local handle = icon(KIND_ICON[entry.kind] or KIND_ICON.folder)
				if handle then pcall(iup.SetAttributeId, side_list, "IMAGE", i, handle) end
			end
			-- Full path on hover: the label is only the trailing component.
			if entry.path then
				pcall(iup.SetAttributeId, side_list, "ITEMTIP", i, entry.path)
			end
		end
		pcall(iup.SetAttribute, side_list, "VALUE", "0")
	end

	-- ---- main list -------------------------------------------------------
	local function render_rows()
		pcall(iup.SetAttribute, dir_list, "REMOVEITEM", "ALL")
		for i, entry in ipairs(st.rows) do
			iup.SetAttribute(dir_list, "APPENDITEM", entry.label)
			local handle = icon(KIND_ICON[entry.kind] or KIND_ICON.folder)
			if handle then pcall(iup.SetAttributeId, dir_list, "IMAGE", i, handle) end
		end
		pcall(iup.SetAttribute, dir_list, "VALUE", "0")
	end

	-- Apply the filter box to `st.all_rows` and repaint. Filtering runs over the
	-- already-listed rows, so typing never re-enumerates the directory -- which
	-- matters on the network shares this tool browses.
	local function apply_filter()
		local needle = (iup.GetAttribute(filter_text, "VALUE") or ""):lower()
		if needle == "" then
			st.rows = st.all_rows
		else
			local kept = {}
			for _, entry in ipairs(st.all_rows) do
				if entry.label:lower():find(needle, 1, true) then
					kept[#kept + 1] = entry
				end
			end
			st.rows = kept
		end
		render_rows()
	end

	local function count_text()
		local shown, total = #st.rows, #st.all_rows
		if shown ~= total then
			return string.format("%d of %d subfolder(s) (filtered)", shown, total)
		end
		return string.format("%d subfolder(s)", total)
	end

	-- Reflect "is the current folder pinned?" on the star button.
	local function sync_star()
		local pinned = index_of_path(favourites, st.current) ~= nil
		local handle = icon(pinned and "star--filled.svg" or "star.svg", BTN_ICON_SIZE, 0)
		if handle then
			pcall(iup.SetAttribute, star_btn, "IMAGE", handle)
		else
			pcall(iup.SetAttribute, star_btn, "TITLE", pinned and "Unpin" or "Pin")
		end
		pcall(iup.SetAttribute, star_btn, "TIP", pinned and "Unpin this folder" or "Pin this folder")
	end

	local function sync_nav_buttons()
		set_active(back_btn, st.hist_pos > 1)
		set_active(fwd_btn, st.hist_pos < #st.history)
		set_active(up_btn, parent_of(st.current) ~= nil)
	end

	-- Navigate to `path`. `record` appends to the history stack (Back/Forward
	-- themselves navigate with record=false so they move through it instead of
	-- rewriting it).
	local function navigate(path, record, quiet)
		path = normalize(path)
		if not is_dir(path) then
			if not quiet then set_status("Folder not found: " .. path) end
			return false
		end

		local names, readable = list_subdirs(path)
		st.current = path
		st.all_rows = {}
		local child_kind = is_unc(path) and "share" or "folder"
		for _, name in ipairs(names) do
			st.all_rows[#st.all_rows + 1] = {
				label = name, path = join(path, name), kind = child_kind,
			}
		end

		if record then
			-- Truncate any forward history: navigating somewhere new from the middle
			-- of the stack discards what used to be ahead, like a browser.
			for i = #st.history, st.hist_pos + 1, -1 do
				table.remove(st.history, i)
			end
			if not same_path(st.history[#st.history] or "", path) then
				st.history[#st.history + 1] = path
			end
			st.hist_pos = #st.history
		end

		pcall(iup.SetAttribute, path_text, "VALUE", st.current)
		apply_filter()
		sync_nav_buttons()
		sync_star()

		if not readable then
			-- Distinct from "empty": the folder exists but denied enumeration.
			set_status("Cannot read this folder (access denied). You can still select it.")
		elseif #st.all_rows == 0 then
			set_status("No subfolders here. 'Select Folder' uses the path above.")
		else
			set_status(count_text() .. ". Double-click to open.")
		end
		return true
	end

	-- ---- small themed prompt (New Folder) --------------------------------
	-- A local dialog rather than iup.GetParam: GetParam builds its own unthemed
	-- window, which would reintroduce exactly the light-on-dark problem this module
	-- exists to remove.
	local function prompt_name(caption)
		local input = iup.text({
			VALUE = "", EXPAND = "HORIZONTAL", VISIBLECOLUMNS = "28",
			FONT = "Segoe UI, 9", BORDER = "NO", THEMEROLE = "text",
		})
		local ok_btn = iup.flatbutton({
			TITLE = "Create", THEMEROLE = "primary_btn", PADDING = "12x5",
		})
		local no_btn = iup.flatbutton({
			TITLE = "Cancel", THEMEROLE = "actionbutton", PADDING = "12x5",
		})
		local answer, prompt_dlg

		function ok_btn:flat_action()
			answer = iup.GetAttribute(input, "VALUE") or ""
			return iup.CLOSE
		end
		function no_btn:flat_action()
			answer = nil
			return iup.CLOSE
		end
		function input:k_any(c)
			if c == iup.K_CR then
				answer = iup.GetAttribute(input, "VALUE") or ""
				return iup.CLOSE
			end
			return iup.DEFAULT
		end

		prompt_dlg = iup.dialog({
			iup.vbox({
				iup.label({ TITLE = caption, FONT = "Segoe UI, 9", THEMEROLE = "settingslabel" }),
				iup.flatframe({ input, TITLE = "", MARGIN = L.margin(1),
					EXPAND = "HORIZONTAL", THEMEROLE = "text" }),
				iup.hbox({ iup.fill({}), ok_btn, no_btn, GAP = L.gap(3), ALIGNMENT = "ACENTER" }),
				MARGIN = L.margin(4), GAP = L.gap(3),
			}),
			TITLE = "New Folder",
			-- Win32 ICON RESOURCE name from assets/Lunar.rc, so popups
			-- carry the app icon in their title bar and Alt-Tab entry too.
			ICON = "IUP",
			RASTERSIZE = "380x150",
			SHRINK = "YES",
			PARENTDIALOG = dlg,
			-- DEFAULTESC is NOT set: it does not work with a flat button. IUP's key
			-- handler accepts one (iup_key.c tests IupClassMatch(bt, "flatbutton"))
			-- but then calls iupdrvActivate, which on Windows posts
			-- WM_COMMAND/BN_CLICKED to the parent -- how a NATIVE button reports a
			-- click. A flatbutton is a canvas raising FLAT_ACTION from its own
			-- BUTTON_CB, so the message goes nowhere and Escape did nothing.
		})

		function prompt_dlg:k_any(c)
			if c == iup.K_ESC then
				answer = nil
				return iup.CLOSE
			end
			return iup.DEFAULT
		end
		if opts.notify_tree_change then opts.notify_tree_change(prompt_dlg) end
		ModalMotion.popup(iup, prompt_dlg)
		iup.Destroy(prompt_dlg)
		return answer
	end

	-- ---- callbacks -------------------------------------------------------
	function dir_list:dblclick_cb(index)
		local entry = st.rows[tonumber(index) or 0]
		if entry and entry.path then navigate(entry.path, true) end
		return iup.DEFAULT
	end

	-- Single click only previews the highlighted row in the status line; it
	-- deliberately does NOT navigate, so selecting the folder you are already in
	-- stays possible.
	function dir_list:flat_action(text, _, state)
		if state == 1 and text then
			set_status("Highlighted: " .. tostring(text) .. "  (double-click to open)")
		end
		return iup.DEFAULT
	end

	-- The sidebar navigates on a SINGLE click. These are destinations, not a tree
	-- to explore, and every reference picker behaves this way.
	function side_list:flat_action(_, index, state)
		if state ~= 1 then return iup.DEFAULT end
		local entry = st.side[tonumber(index) or 0]
		if not entry or entry.header or not entry.path then
			return iup.DEFAULT
		end
		if not navigate(entry.path, true) then
			set_status("That location is no longer available: " .. entry.path)
		end
		return iup.DEFAULT
	end

	function back_btn:flat_action()
		if st.hist_pos > 1 then
			st.hist_pos = st.hist_pos - 1
			navigate(st.history[st.hist_pos], false, true)
		end
		return iup.DEFAULT
	end

	function fwd_btn:flat_action()
		if st.hist_pos < #st.history then
			st.hist_pos = st.hist_pos + 1
			navigate(st.history[st.hist_pos], false, true)
		end
		return iup.DEFAULT
	end

	function up_btn:flat_action()
		local up = parent_of(st.current)
		if up then navigate(up, true) end
		return iup.DEFAULT
	end

	function refresh_btn:flat_action()
		rebuild_sidebar()
		navigate(st.current, false, true)
		return iup.DEFAULT
	end

	function newdir_btn:flat_action()
		local raw = prompt_name("New folder in:  " .. st.current)
		if raw == nil then return iup.DEFAULT end
		local name, reason = validate_folder_name(raw)
		if not name then
			set_status(reason)
			return iup.DEFAULT
		end
		local target = join(st.current, name)
		if lfs.attributes(target, "mode") ~= nil then
			set_status('"' .. name .. '" already exists here.')
			return iup.DEFAULT
		end
		local made, err = lfs.mkdir(target)
		if not made then
			set_status("Could not create folder: " .. tostring(err or "access denied"))
			return iup.DEFAULT
		end
		navigate(target, true)
		set_status('Created "' .. name .. '".')
		return iup.DEFAULT
	end

	function star_btn:flat_action()
		local at = index_of_path(favourites, st.current)
		if at then
			table.remove(favourites, at)
			set_status("Unpinned " .. st.current)
		else
			if #favourites >= MAX_FAVOURITES then
				set_status("Favourites are full (" .. MAX_FAVOURITES .. "). Unpin one first.")
				return iup.DEFAULT
			end
			favourites[#favourites + 1] = normalize(st.current)
			set_status("Pinned " .. st.current)
		end
		persist()
		sync_star()
		rebuild_sidebar()
		return iup.DEFAULT
	end

	function filter_text:valuechanged_cb()
		apply_filter()
		set_status(count_text())
		return iup.DEFAULT
	end

	-- Typing a path and pressing Enter jumps straight there.
	function path_text:k_any(c)
		if c == iup.K_CR then
			navigate(iup.GetAttribute(path_text, "VALUE") or "", true)
			return iup.IGNORE
		end
		return iup.DEFAULT
	end

	function select_btn:flat_action()
		-- Trust the text box over `st.current`: the user may have typed a path
		-- without pressing Enter, and silently discarding it would be surprising.
		local typed = normalize(iup.GetAttribute(path_text, "VALUE") or "")
		if not is_dir(typed) then
			set_status("Folder not found: " .. typed)
			return iup.DEFAULT
		end
		push_recent(recents, typed, MAX_RECENTS)
		persist()
		st.result = typed
		ModalMotion.result(iup, dlg, "confirm")
		return iup.CLOSE
	end

	function cancel_btn:flat_action()
		st.result = nil
		ModalMotion.result(iup, dlg, "cancel")
		return iup.CLOSE
	end

	-- ---- layout ----------------------------------------------------------
	local search_icon = icon("search.svg", BTN_ICON_SIZE, 0)
	local filter_lead = search_icon
		and iup.label({ IMAGE = search_icon })
		or iup.label({ TITLE = "Filter", FONT = "Segoe UI, 9", THEMEROLE = "settingslabel" })

	-- Toolbar and path share one row (as in the references), but the path box is
	-- the only element that flexes -- the buttons keep their natural width, so
	-- none of them can be the one that gets clipped when the dialog narrows.
	local toolbar = iup.hbox({
		back_btn, fwd_btn, up_btn, refresh_btn,
		iup.flatseparator({ ORIENTATION = "VERTICAL", STYLE = "LINE", BARSIZE = "1" }),
		path_frame,
		iup.flatseparator({ ORIENTATION = "VERTICAL", STYLE = "LINE", BARSIZE = "1" }),
		newdir_btn, star_btn,
		GAP = L.gap(2), ALIGNMENT = "ACENTER",
	})

	local sidebar = iup.vbox({
		side_list,
		MARGIN = L.margin(0), GAP = L.gap(0), EXPAND = "YES",
	})

	local main_pane = iup.vbox({
		iup.hbox({ filter_lead, filter_frame, GAP = L.gap(3), ALIGNMENT = "ACENTER" }),
		iup.flatframe({
			dir_list, TITLE = "", MARGIN = L.margin(2),
			EXPAND = "YES", THEMEROLE = "settingspanel",
		}),
		GAP = L.gap(3), EXPAND = "YES",
	})

	-- Draggable divider, like the reference pickers. A real (unlocked) split is
	-- fine here -- the cursor-capture problem QueuePanel documents came from a
	-- split LOCKED via MINMAX to a fixed ratio, which claimed the resize cursor
	-- while refusing to actually resize.
	local body = iup.split({ sidebar, main_pane })
	body.ORIENTATION = "VERTICAL"
	body.VALUE = "270"          -- ~27% to the sidebar
	body.MINMAX = "150:450"
	body.SHOWGRIP = "YES"
	body.EXPAND = "YES"
	SplitMotion.attach(iup, body)

	dlg = iup.dialog({
		iup.vbox({
			toolbar,
			body,
			status_lbl,
			iup.hbox({
				iup.fill({}), select_btn, cancel_btn,
				GAP = L.gap(3), ALIGNMENT = "ACENTER",
			}),
			MARGIN = L.margin(4), GAP = L.gap(3),
		}),
		TITLE = opts.title or "Select Folder",
		-- Win32 ICON RESOURCE name from assets/Lunar.rc, so popups
		-- carry the app icon in their title bar and Alt-Tab entry too.
		ICON = "IUP",
		-- RASTERSIZE, not SIZE: IUP's SIZE is in font-relative dialog units, which is
		-- how the Feedback dialog ended up taller than a laptop screen. Sized to fit
		-- a sidebar plus a comfortable list, still inside a 1366x768 screen.
		RASTERSIZE = "860x560",
		MINSIZE = "620x400",
		-- Same attribute set as KnowledgeDialog / RunDeltaDialog, the two popups in
		-- this codebase whose RASTERSIZE is known to be honored. Worth matching
		-- exactly rather than inventing a variation.
		MINBOX = "YES",
		MAXBOX = "YES",
		RESIZE = "YES",
		SHRINK = "YES",
		PARENTDIALOG = opts.parent,
		-- DEFAULTESC is NOT set: it does not work with a flat button (see the
		-- prompt above, and core.ui.NameDialog). Escape is handled below instead.
	})

	-- Only Escape. Enter is deliberately left alone: it already means "open the
	-- highlighted folder" in the path entry and the list, and hijacking it for the
	-- Select button would change behaviour rather than restore it.
	function dlg:k_any(c)
		if c == iup.K_ESC then
			st.result = nil
			ModalMotion.result(iup, dlg, "cancel")
			return iup.CLOSE
		end
		return iup.DEFAULT
	end

	if opts.notify_tree_change then
		opts.notify_tree_change(dlg)
	end

	rebuild_sidebar()
	navigate(st.current, false, true)
	-- iup.CENTER, matching the other themed popups. CENTERPARENT only changes
	-- placement, never size, so this is purely for consistency with them.
	ModalMotion.popup(iup, dlg, { x = iup.CENTER, y = iup.CENTER })
	iup.Destroy(dlg)
	return st.result
end

return FolderDialog
