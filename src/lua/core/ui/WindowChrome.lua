--- The window frame and native menus follow the theme.
--
-- A dark app under a white title bar and white popup menus reads as two products.
-- Windows paints both outside anything IUP's flat controls reach, so this asks DWM to
-- colour the caption (Windows 11; Windows 10 gets the dark frame only) and uxtheme to
-- theme popup menus. On any other platform, or a build without these calls, every
-- function here does nothing and the window keeps its system frame.
--
-- @module core.ui.WindowChrome
local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
local windows = ok_ffi and ffi.os == "Windows"

local DWMWA_USE_IMMERSIVE_DARK_MODE = 20
local DWMWA_BORDER_COLOR = 34
local DWMWA_CAPTION_COLOR = 35
local DWMWA_TEXT_COLOR = 36

-- uxtheme exports these by ordinal only; stable since Windows 10 1903.
local ORDINAL_SET_PREFERRED_APP_MODE = 135
local ORDINAL_FLUSH_MENU_THEMES = 136
local APP_MODE_FORCE_DARK, APP_MODE_FORCE_LIGHT = 2, 3

--- Turn a theme colour into a Win32 COLORREF (0x00BBGGRR).
-- @tparam string|table colour `"#rrggbb"`, or IUP's `"r g b"`
-- @treturn number|nil
function M.colorref(colour)
	local text = tostring(colour or "")
	local r, g, b = text:match("^#(%x%x)(%x%x)(%x%x)$")
	if r then
		r, g, b = tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
	else
		r, g, b = text:match("^(%d+)%s+(%d+)%s+(%d+)")
		if not r then return nil end
		r, g, b = tonumber(r), tonumber(g), tonumber(b)
	end
	return r + g * 256 + b * 65536
end

-- Each declaration on its own: another module may already have made one of them.
local function declare()
	if M._declared then return end
	M._declared = true
	pcall(ffi.cdef, "int DwmSetWindowAttribute(void*, unsigned long, const void*, unsigned long);")
	pcall(ffi.cdef, "void* LoadLibraryA(const char*);")
	pcall(ffi.cdef, "void* GetProcAddress(void*, const char*);")
end

-- Native popup menus (the app menu and every right-click menu).
local function theme_menus(dark)
	local kernel32 = ffi.load("kernel32")
	local uxtheme = kernel32.LoadLibraryA("uxtheme.dll")
	if uxtheme == nil then return end
	local function export(ordinal)
		return kernel32.GetProcAddress(uxtheme, ffi.cast("const char*", ffi.cast("intptr_t", ordinal)))
	end
	local set_mode, flush = export(ORDINAL_SET_PREFERRED_APP_MODE), export(ORDINAL_FLUSH_MENU_THEMES)
	if set_mode == nil or flush == nil then return end
	ffi.cast("int (__stdcall*)(int)", set_mode)(dark and APP_MODE_FORCE_DARK or APP_MODE_FORCE_LIGHT)
	ffi.cast("void (__stdcall*)(void)", flush)()
end

--- Colour one mapped dialog's frame.
-- @tparam userdata iup
-- @tparam userdata dialog a mapped dialog
-- @tparam table theme the active theme (`isDark()`, `palette()`)
function M.applyFrame(iup, dialog, theme)
	if not windows or not theme then return end
	pcall(function()
		declare()
		local IupFFI = require("core.classes.IupFFI")
		local hwnd = IupFFI.getptr(IupFFI.ptr(dialog), "HWND")
		if hwnd == nil then return end
		local dwm, palette = ffi.load("dwmapi"), theme:palette() or {}
		local function set(attribute, value)
			dwm.DwmSetWindowAttribute(hwnd, attribute, ffi.new("int[1]", value), 4)
		end
		set(DWMWA_USE_IMMERSIVE_DARK_MODE, theme:isDark() and 1 or 0)
		-- The caption continues the tab strip below it, so the two read as one band.
		local rules = theme:rules() or {}
		local strip = rules.flattabs and rules.flattabs.tabsbg
		local caption, text = M.colorref(strip or palette.bg), M.colorref(palette.text)
		if caption then
			set(DWMWA_CAPTION_COLOR, caption)
			set(DWMWA_BORDER_COLOR, caption)
		end
		if text then set(DWMWA_TEXT_COLOR, text) end
	end)
end

--- Follow the theme on the main window and on popup menus.
-- @tparam userdata iup
-- @tparam userdata dialog the mapped main dialog
-- @tparam table theme_mgr core.classes.ThemeManager
function M.follow(iup, dialog, theme_mgr)
	if not windows then return end
	M._theme_mgr = theme_mgr
	theme_mgr:onApply(function()
		local theme = theme_mgr:activeTheme()
		M.applyFrame(iup, dialog, theme)
		pcall(function()
			declare()
			if theme then theme_menus(theme:isDark()) end
		end)
	end)
end

--- Colour a dialog that opens after the main window (a modal, say) to match.
-- @tparam userdata iup
-- @tparam userdata dialog a mapped dialog
function M.adopt(iup, dialog)
	local mgr = M._theme_mgr
	if mgr then M.applyFrame(iup, dialog, mgr:activeTheme()) end
end

return M
