--- The system colours of the emulated native controls.
--
-- IUP's native controls are Windows' own, so a part no IUP attribute reaches (a native
-- scroll bar, a combo box's 3D edges and button, a frame's groove) is drawn in the
-- system colours: light grey whatever the app's theme, which is how a dark theme ends
-- up with light bars. This host draws those parts itself, from this table instead of
-- constants, so they can follow the theme.
--
-- The default is Windows' light look, measured on the IUP build (pixel parity is kept
-- for the classic theme and for code that applies no theme). On every theme apply,
-- core.classes.ThemeManager derives the table from the theme's palette (`fromPalette`);
-- the classic theme restores the defaults.
--
-- @module core.imgui.syscolors
local Color = require("core.imgui.Color")

local M = {}

--- Windows' light system colours, as drawn on the IUP build.
M.LIGHT = {
	-- the Windows 11 scroll bar at rest (widgets/winscrollbar.lua)
	scroll_track = "240 240 240", scroll_edge = "255 255 255",
	scroll_thumb = "133 133 133", scroll_thumb_end = "152 152 152", scroll_disabled = "164 164 164",
	-- 3D control parts (COLOR_BTNFACE, BTNSHADOW, 3DDKSHADOW, 3DLIGHT, BTNHIGHLIGHT)
	face = "240 240 240", shadow = "160 160 160", dkshadow = "105 105 105",
	light = "227 227 227", highlight = "255 255 255",
	text = "0 0 0",            -- COLOR_BTNTEXT, COLOR_WINDOWTEXT
	window = "255 255 255",    -- COLOR_WINDOW: a field's background
	sel = "0 120 215", seltext = "255 255 255", -- COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT
	grayed = "109 109 109",    -- COLOR_GRAYTEXT
	border = "100 100 100",    -- a drop-down list's frame
	frame = "160 160 160",     -- IupFrame's groove
}

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

--- The colours in use now. Read at draw time (the table is replaced on a theme switch).
M.current = copy(M.LIGHT)

local function mix(a, b, t) return Color.tostring(Color.mix(Color.parse(a), Color.parse(b), t)) end

--- Derive the system colours from a theme palette (core.classes.Theme), or restore
-- Windows' when `palette` is nil (the classic theme). Works for light and dark themes:
-- every part takes the palette's surface, border and text roles, so a light theme's
-- controls match its own greys rather than Windows'.
function M.fromPalette(palette)
	if type(palette) ~= "table" then M.current = copy(M.LIGHT); return M.current end
	local p = palette
	local function pick(...)
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if p[v] ~= nil then return p[v] end
		end
	end
	local bg = pick("bg", "background") or M.LIGHT.window
	local surface = pick("layer01", "surface") or bg
	local raised = pick("layer02", "surface2", "layerHover01") or surface
	local subtle = pick("borderSubtle01", "border") or mix(surface, pick("text") or M.LIGHT.text, 0.15)
	local strong = pick("fieldBorder", "borderStrong01", "borderStrong") or subtle
	local text = pick("text", "listText") or M.LIGHT.text
	local muted = pick("textMuted") or mix(text, surface, 0.4)
	local accent = pick("accent") or M.LIGHT.sel
	local track = surface
	M.current = {
		scroll_track = track, scroll_edge = subtle,
		scroll_thumb = mix(muted, track, 0.25), scroll_thumb_end = mix(muted, track, 0.45),
		scroll_disabled = mix(muted, track, 0.6),
		face = raised, shadow = strong, dkshadow = subtle, light = subtle, highlight = raised,
		text = text, window = pick("well", "listBg") or surface,
		sel = accent, seltext = pick("accentText") or M.LIGHT.seltext,
		grayed = mix(muted, surface, 0.35),
		border = strong, frame = subtle,
	}
	return M.current
end

return M
