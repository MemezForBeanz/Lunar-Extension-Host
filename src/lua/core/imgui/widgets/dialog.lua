--- Dialog-level classes: `dialog`, `timer`, `filedlg`, `messagedlg`, `clipboard`, and the
-- stock dialogs behind `iup.Message`, `iup.Alarm`, `iup.GetText` and `iup.GetParam`.
--
-- The first dialog shown owns the OS window; the rest are drawn inside it as floating
-- panels (see `core.imgui.Runtime`). The stock dialogs are built from flat controls
-- and take the current theme's colours, where IUP showed unthemed system boxes.
--
-- @module core.imgui.widgets.dialog
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")

local M = {}

local function rt() return require("core.imgui.Runtime") end
local function backend() return rt().backend() end
local function is_main(el) return rt().mainDialog() == el end
local function tray_target(el) return is_main(el) or not rt().mainDialog() end

local function parse_size(s)
	if not s then return nil end
	local w, h = tostring(s):match("^(%d*)x(%d*)$")
	return tonumber(w), tonumber(h)
end

local function menubar(el)
	local menu = Element.getHandle(el, "MENU")
	if not menu then return nil end
	local ok, Menu = pcall(require, "core.imgui.widgets.menu")
	if not ok or not Menu.menubarHeight then return nil end
	return menu, Menu
end

Classes.define({
	name = "dialog",
	children = 1,
	type = "dialog",
	opaque = true,
	defaults = {
		RESIZE = "YES", MAXBOX = "YES", MINBOX = "YES", MENUBOX = "YES", BORDER = "YES",
		SHRINK = "NO", CANFOCUS = "NO",
	},
	noinherit = { MENU = true, PARENTDIALOG = true, DEFAULTENTER = true, DEFAULTESC = true,
		STARTFOCUS = true, PLACEMENT = true, ICON = true, TOPMOST = true, MODAL = true,
		SHOWNOFOCUS = true, SHOWNOACTIVATE = true, HIDETASKBAR = true, CUSTOMFRAME = true },
	callbacks = { CLOSE_CB = true, SHOW_CB = true, RESIZE_CB = true, MOVE_CB = true,
		MAP_CB = true, UNMAP_CB = true, DESTROY_CB = true, K_ANY = true, FOCUS_CB = true,
		DROPFILES_CB = true, TRAYCLICK_CB = true },

	set = {
		TITLE = function(el, st, value)
			if is_main(el) and backend() and backend().alive() then backend().window("title", value or "") end
		end,
		RASTERSIZE = function(el, st, value)
			-- the base rule (RASTERSIZE replaces SIZE) until the window is up
			if not st.data.shown then st.attrs.SIZE = nil end
			local w, h = parse_size(value)
			if st.data.shown and w and h then
				if is_main(el) then backend().window("size", w, h)
				else st.w, st.h = w, h end
			end
		end,
		PLACEMENT = function(el, st, value)
			if is_main(el) and backend() and backend().alive() then
				if value == "MAXIMIZED" then backend().window("maximize")
				elseif value == "MINIMIZED" then backend().window("minimize")
				elseif value == "FULL" then backend().window("fullscreen", true)
				else backend().window("restore") end
			end
		end,
		FULLSCREEN = function(el, st, value)
			if is_main(el) and backend() and backend().alive() then
				backend().window("fullscreen", value == "YES")
			end
		end,
		VISIBLE = function(el, st, value)
			if value == "NO" then rt().hide(el) elseif value == "YES" then rt().show(el) end
			return false
		end,
		BRINGFRONT = function(el, st, value)
			if value == "YES" and st.data.shown then
				if is_main(el) then backend().window("focus") else rt().show(el) end
			end
			return false
		end,
		SHOWMINIMIZED = function() return false end,
		TRAY = function(el, st, value)
			st.data.tray_shown = value == "YES" and nil or false
			if tray_target(el) and backend() and backend().window then
				backend().window("tray", value == "YES")
				st.data.tray_shown = value == "YES"
			end
		end,
		TRAYIMAGE = function(el, st, value)
			if tray_target(el) and backend() and backend().window then backend().window("tray_image", value) end
		end,
		TRAYTIP = function(el, st, value)
			if tray_target(el) and backend() and backend().window then backend().window("traytip", value or "") end
		end,
		TRAYTIPBALLOON = function(el, st, value)
			if tray_target(el) and backend() and backend().window then backend().window("tray_balloon", value) end
		end,
		TRAYTIPBALLOONTITLE = function(el, st, value)
			if tray_target(el) and backend() and backend().window then backend().window("tray_balloon_title", value) end
		end,
		TRAYTIPBALLOONTITLEICON = function(el, st, value)
			if tray_target(el) and backend() and backend().window then backend().window("tray_balloon_icon", value) end
		end,
	},

	get = {
		MAXIMIZED = function(el, st)
			if is_main(el) and backend() and backend().alive() then
				return backend().window("is_maximized") and "YES" or "NO"
			end
			return "NO"
		end,
		MINIMIZED = function(el, st)
			if is_main(el) and backend() and backend().alive() then
				return backend().window("is_minimized") and "YES" or "NO"
			end
			return "NO"
		end,
		VISIBLE = function(el, st) return st.data.shown and "YES" or "NO" end,
		MODAL = function(el, st) return st.data.modal and "YES" or "NO" end,
		CLIENTSIZE = function(el, st)
			local top = 0
			local menu, Menu = menubar(el)
			if menu then top = Menu.menubarHeight(menu, Fonts.forElement(el)) end
			return string.format("%dx%d", st.w, math.max(0, st.h - top))
		end,
		CLIENTOFFSET = function(el, st)
			local menu, Menu = menubar(el)
			local top = menu and Menu.menubarHeight(menu, Fonts.forElement(el)) or 0
			return string.format("0x%d", top)
		end,
		ACTIVEWINDOW = function(el, st)
			local ds = rt().dialogs()
			return ds[#ds] == el and "YES" or "NO"
		end,
		BORDERSIZE = function() return "0" end,
		CAPTIONHEIGHT = function() return "0" end,
	},

	natural = function(el, st, L)
		local child = st.children[1]
		local w, h = 0, 0
		if child and L.visible(child) then w, h = L.natural(child) end
		local menu, Menu = menubar(el)
		if menu then h = h + Menu.menubarHeight(menu, L.font(el)) end
		return w, h
	end,

	place = function(el, st, L)
		local top = 0
		local menu, Menu = menubar(el)
		if menu then top = Menu.menubarHeight(menu, L.font(el)) end
		local child = st.children[1]
		if child then L.place(child, st.x, st.y + top, st.w, math.max(0, st.h - top)) end
	end,

	draw = function(el, st, dc, R)
		local B = backend()
		-- TRAY set before the window existed: apply it once the window draws
		if st.attrs.TRAY == "YES" and not st.data.tray_shown and B and B.window and tray_target(el) then
			st.data.tray_shown = true
			if st.attrs.TRAYTIP then B.window("traytip", st.attrs.TRAYTIP) end
			B.window("tray", true)
		end
		if B and B.window and is_main(el) then B.window("videohost_frame") end
		dc:fill(st.x, st.y, st.w, st.h, Element.getAttribute(el, "BGCOLOR") or Element.globals.DLGBGCOLOR)
		local menu, Menu = menubar(el)
		if menu and Menu.drawMenubar then Menu.drawMenubar(menu, dc, st.x, st.y, st.w, R) end
	end,

	event = function(el, st, ev, R)
		local menu, Menu = menubar(el)
		if menu and Menu.menubarEvent then return Menu.menubarEvent(menu, ev, R) end
		return false
	end,
})

-- Timer -----------------------------------------------------------------------------------
Classes.define({
	name = "timer",
	children = 0,
	type = "void",
	transparent = true,
	defaults = { TIME = "1000", RUN = "NO" },
	callbacks = { ACTION_CB = true },
	set = {
		RUN = function(el, st, value)
			if value == "YES" then rt().timerStart(el) else rt().timerStop(el) end
		end,
		TIME = function(el, st, value)
			-- the new interval applies from the next RUN=YES, as in IUP
		end,
	},
	get = {
		RUN = function(el) return rt().timerRunning(el) and "YES" or "NO" end,
		ELAPSEDTIME = function(el, st)
			if not st.data.started then return "0" end
			return string.format("%d", (rt().now() - st.data.started) * 1000)
		end,
	},
	destroy = function(el) rt().timerStop(el) end,
})

-- Clipboard --------------------------------------------------------------------------------
Classes.define({
	name = "clipboard",
	children = 0,
	type = "void",
	set = {
		TEXT = function(el, st, value) rt().clipboard_set(value or ""); return false end,
	},
	get = {
		TEXT = function() return rt().clipboard_get() end,
		TEXTAVAILABLE = function() local t = rt().clipboard_get(); return (t and t ~= "") and "YES" or "NO" end,
		IMAGEAVAILABLE = function() return "NO" end,
	},
})

-- File dialog ---------------------------------------------------------------------------------
local function filters(el)
	local ext = Element.getAttribute(el, "EXTFILTER")
	if ext and ext ~= "" then return ext end
	local filter = Element.getAttribute(el, "FILTER")
	if filter and filter ~= "" then
		local info = Element.getAttribute(el, "FILTERINFO") or filter
		return info .. "|" .. filter .. "|"
	end
	return nil
end

Classes.define({
	name = "filedlg",
	children = 0,
	type = "dialog",
	defaults = { DIALOGTYPE = "OPEN", ALLOWNEW = function(el) return Element.getAttribute(el, "DIALOGTYPE") == "SAVE" and "YES" or "NO" end },
	popup = function(el, st, R)
		local B = R.backend()
		local kind = (Element.getAttribute(el, "DIALOGTYPE") or "OPEN"):upper()
		local multiple = Element.getAttribute(el, "MULTIPLEFILES") == "YES"
		local res = B.file_dialog and B.file_dialog({
			type = kind,
			title = Element.getAttribute(el, "TITLE"),
			filter = filters(el),
			directory = Element.getAttribute(el, "DIRECTORY"),
			file = Element.getAttribute(el, "FILE"),
			multiple = multiple,
			allownew = Element.getAttribute(el, "ALLOWNEW") == "YES",
			overwrite_prompt = Element.getAttribute(el, "NOOVERWRITEPROMPT") ~= "YES",
		})
		if res == nil or res == false or res == "" then
			Element.setAttribute(el, "STATUS", "-1")
			Element.setAttribute(el, "VALUE", nil)
			return 0
		end
		if type(res) == "table" then
			if #res == 1 then
				Element.setAttribute(el, "VALUE", res[1])
			else
				local dir = res[1]:match("^(.*)[/\\][^/\\]*$") or ""
				local parts = { dir }
				for i, p in ipairs(res) do
					parts[#parts + 1] = p:match("[^/\\]+$") or p
					Element.setAttribute(el, "MULTIVALUE" .. i, p)
				end
				Element.setAttribute(el, "MULTIVALUE0", dir)
				Element.setAttribute(el, "MULTIVALUECOUNT", #res + 1)
				Element.setAttribute(el, "VALUE", table.concat(parts, "|") .. "|")
			end
			res = res[1]
		else
			Element.setAttribute(el, "VALUE", res)
		end
		local exists = false
		local f = io.open(res, "rb")
		if f then f:close(); exists = true end
		if kind == "DIR" then Element.setAttribute(el, "STATUS", "0")
		else Element.setAttribute(el, "STATUS", exists and "0" or "1") end
		local dir = res:match("^(.*)[/\\][^/\\]*$")
		if dir then Element.setAttribute(el, "DIRECTORY", dir) end
		return 0
	end,
})

-- Stock dialogs ------------------------------------------------------------------------------
local function iup() return require("core.imgui.iup") end

--- Colours for a stock dialog: whatever the main window wears.
local function theme_of()
	local main = rt().mainDialog()
	local bg = main and Element.getAttribute(main, "BGCOLOR") or Element.globals.DLGBGCOLOR
	local fg = main and Element.getAttribute(main, "FGCOLOR") or Element.globals.DLGFGCOLOR
	return bg, fg
end

local function themed(dlg)
	local ok, Reactor = pcall(require, "core.ui.ThemeReactor")
	local tm = ok and Reactor.themeManager and Reactor.themeManager()
	if tm and tm.applyTo then pcall(tm.applyTo, tm, dlg) end
end

local function build(title, body, buttons, default_index)
	local I = iup()
	local bg, fg = theme_of()
	local result = 0
	local row = { I.fill({}) }
	local made = {}
	for i, label in ipairs(buttons) do
		local b = I.flatbutton({
			TITLE = label, PADDING = "16x6", THEMEROLE = i == (default_index or 1) and "primary_btn" or "actionbutton",
			RASTERSIZE = "88x", CANFOCUS = "YES", BORDER = "YES", CORNERRADIUS = "4",
		})
		b.flat_action = function()
			result = i
			I.Hide(I.GetDialog(b))
			return I.DEFAULT
		end
		made[i] = b
		row[#row + 1] = b
	end
	row.GAP = "8"
	local content = { body, I.hbox(row), MARGIN = "20x16", GAP = "16" }
	local dlg = I.dialog({
		I.vbox(content),
		TITLE = title or "", BGCOLOR = bg, FGCOLOR = fg, RESIZE = "NO", MINBOX = "NO", MAXBOX = "NO",
	})
	if made[default_index or 1] then I.SetAttribute(dlg, "DEFAULTENTER", made[default_index or 1]) end
	if made[#made] then I.SetAttribute(dlg, "DEFAULTESC", made[#made]) end
	themed(dlg)
	return dlg, function() return result end
end

function M.message(R, title, message)
	local I = iup()
	local body = I.flatlabel({ TITLE = message or "", EXPAND = "HORIZONTAL" })
	local dlg = build(title, body, { "OK" }, 1)
	I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
	I.Destroy(dlg)
	return 0
end

function M.alarm(R, title, message, b1, b2, b3)
	local I = iup()
	local body = I.flatlabel({ TITLE = message or "", EXPAND = "HORIZONTAL" })
	local buttons = { b1 or "OK" }
	if b2 then buttons[2] = b2 end
	if b3 then buttons[3] = b3 end
	local dlg, result = build(title, body, buttons, 1)
	I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
	local r = result()
	I.Destroy(dlg)
	if r == 0 then r = #buttons end
	return r
end

function M.getText(R, title, text)
	local I = iup()
	local field = I.text({ VALUE = text or "", EXPAND = "HORIZONTAL", VISIBLECOLUMNS = "30" })
	local dlg, result = build(title, field, { "OK", "Cancel" }, 1)
	I.SetAttribute(dlg, "STARTFOCUS", field)
	I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
	local r = result()
	local value = I.GetAttribute(field, "VALUE")
	I.Destroy(dlg)
	if r == 1 then return value end
	return nil
end

--- A small GetParam: one line per parameter ("Label: %s", "%i", "%r", "%b[No,Yes]", "%l|a|b|").
function M.getParam(R, title, action, format, ...)
	local I = iup()
	local values = { ... }
	local fields, lines = {}, {}
	local idx = 0
	for line in tostring(format or ""):gmatch("([^\n]+)") do
		local label, kind = line:match("^(.-)%%(%a)")
		if label and kind ~= "t" and kind ~= "u" then
			idx = idx + 1
			local v = values[idx]
			local field
			if kind == "b" then
				field = I.flattoggle({ TITLE = label, VALUE = (v == 1 or v == true) and "ON" or "OFF" })
			elseif kind == "l" then
				local items = {}
				for item in line:match("|(.*)|$"):gmatch("([^|]+)") do items[#items + 1] = item end
				local init = { DROPDOWN = "YES", VALUE = tostring((tonumber(v) or 0) + 1), EXPAND = "HORIZONTAL" }
				for i, it in ipairs(items) do init[tostring(i)] = it end
				field = I.list(init)
			else
				field = I.text({ VALUE = v ~= nil and tostring(v) or "", EXPAND = "HORIZONTAL", VISIBLECOLUMNS = "24" })
			end
			fields[idx] = { field = field, kind = kind }
			if kind == "b" then lines[#lines + 1] = field
			else lines[#lines + 1] = I.hbox({ I.flatlabel({ TITLE = label:gsub(":%s*$", "") .. ":", RASTERSIZE = "120x" }), field, ALIGNMENT = "ACENTER", GAP = "8" }) end
		end
	end
	lines.GAP = "8"
	local dlg, result = build(title, I.vbox(lines), { "OK", "Cancel" }, 1)
	I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
	local r = result()
	local out = {}
	for i, f in ipairs(fields) do
		local raw = I.GetAttribute(f.field, "VALUE")
		if f.kind == "b" then out[i] = raw == "ON" and 1 or 0
		elseif f.kind == "i" or f.kind == "l" then out[i] = (tonumber(raw) or 0) - (f.kind == "l" and 1 or 0)
		elseif f.kind == "r" or f.kind == "R" or f.kind == "a" then out[i] = tonumber(raw) or 0
		else out[i] = raw end
	end
	I.Destroy(dlg)
	if r ~= 1 then return false end
	return true, unpack(out, 1, #fields)
end

function M.scanf(R, format, ...)
	-- IupScanf: first line is the title, then "label%fmt\n" lines.
	local title, rest = tostring(format or ""):match("^([^\n]*)\n(.*)$")
	local ok, a, b, c, d, e = M.getParam(R, title, nil, (rest or ""):gsub("%%%d*%.?%d*([dixfgs])", "%%%1"), ...)
	if not ok then return -1 end
	return a, b, c, d, e
end

function M.listDialog(R, kind, title, size, list, op, max_col, max_lin, marks)
	local I = iup()
	local init = { EXPAND = "YES", VISIBLELINES = tostring(math.min(size or 8, 12)), VALUE = tostring(op or 1) }
	for i, item in ipairs(list or {}) do init[tostring(i)] = item end
	local l = I.flatlist(init)
	local dlg, result = build(title, l, { "OK", "Cancel" }, 1)
	I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
	local r = result()
	local v = tonumber(I.GetAttribute(l, "VALUE")) or 0
	I.Destroy(dlg)
	if r ~= 1 then return -1 end
	return v
end

-- messagedlg ------------------------------------------------------------------------------------
local BUTTONS = {
	OK = { "OK" }, OKCANCEL = { "OK", "Cancel" }, RETRYCANCEL = { "Retry", "Cancel" },
	YESNO = { "Yes", "No" }, YESNOCANCEL = { "Yes", "No", "Cancel" },
}

Classes.define({
	name = "messagedlg",
	children = 0,
	type = "dialog",
	defaults = { DIALOGTYPE = "MESSAGE", BUTTONS = "OK", BUTTONDEFAULT = "1" },
	popup = function(el, st, R)
		local I = iup()
		local body = I.flatlabel({ TITLE = Element.getAttribute(el, "VALUE") or "", EXPAND = "HORIZONTAL" })
		local buttons = BUTTONS[(Element.getAttribute(el, "BUTTONS") or "OK"):upper()] or BUTTONS.OK
		local dlg, result = build(Element.getAttribute(el, "TITLE"), body, buttons, tonumber(Element.getAttribute(el, "BUTTONDEFAULT")) or 1)
		I.Popup(dlg, I.CENTERPARENT, I.CENTERPARENT)
		local r = result()
		I.Destroy(dlg)
		if r == 0 then r = #buttons end
		Element.setAttribute(el, "BUTTONRESPONSE", tostring(r))
		return 0
	end,
})

return M
