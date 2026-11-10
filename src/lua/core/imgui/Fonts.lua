--- IUP font strings to ImGui fonts.
--
-- IUP describes a font as `"Typeface, Styles Size"`: `"Segoe UI, Bold 10"`,
-- `"IBM Plex Sans, 9"`, `"Courier New, Italic -14"` (a negative size is pixels, a
-- positive one points). ImGui 1.92 renders any size from one loaded face, so a font
-- here is a (face file, pixel size) pair; faces are loaded once and shared.
--
-- Metrics follow IUP's Windows driver: `charsize()` is (`tmAveCharWidth`, `tmHeight`),
-- which is what SIZE units and every flat control's text box are measured in.
--
-- @module core.imgui.Fonts
local Element = require("core.imgui.Element")

local M = {}

--- The backend (set by the runtime; tests set the Null backend).
M.backend = nil
--- Screen DPI. IUP converts points with the system DPI: px = pt * dpi / 72.
M.dpi = 96
--- The face used when a font string names nothing usable.
M.fallback = "Segoe UI, 9"

local Font = {}
Font.__index = Font

local by_string = {}
local face_ids = {}     -- "face|b|i" -> backend font id (or false)
local count = 0

function M.reset()
	by_string = {}
	face_ids = {}
	count = 0
end

-- iFontFindStyleName's table: a trailing word that starts one of these names is a style
-- word, and it leaves the face name even when it sits before the comma ("HPE Graphik
-- Medium, 10" is the face "HPE Graphik"; IUP then asks GDI for that name).
local STYLE_NAMES = {
	{ "Normal" }, { "Oblique", "italic" }, { "Italic", "italic" }, { "Small-Caps" }, { "Ultra-Light" },
	{ "Light" }, { "Medium" }, { "Semi-Bold", "bold" }, { "Bold", "bold" }, { "Ultra-Bold", "bold" },
	{ "Heavy" }, { "Ultra-Condensed" }, { "Extra-Condensed" }, { "Condensed" }, { "Semi-Condensed" },
	{ "Semi-Expanded" }, { "Expanded" }, { "Extra-Expanded" }, { "Ultra-Expanded" },
	{ "Underline", "underline" }, { "Strikeout", "strikeout" },
}
local function style_word(word)
	for _, e in ipairs(STYLE_NAMES) do
		-- strncmp(name, word, len) == 0: the word is a prefix of the name
		if #word <= #e[1] and e[1]:sub(1, #word) == word then return true, e[2] end
	end
	return false
end

-- atoi: leading blanks, a sign, digits; 0 when there are none.
local function atoi(word)
	local n = word:match("^%s*([+-]?%d+)")
	return n and tonumber(n) or 0
end

--- Parse a font string the way IUP does (iupGetFontInfo: iupFontParseWin, then
-- iupFontParsePango; the X form is not used on Windows).
-- @treturn table { face, size (points, or negative pixels; nil when absent), bold, italic, underline, strikeout }
function M.parse(s)
	s = tostring(s or "")
	local out = { face = nil, bold = false, italic = false, underline = false, strikeout = false, size = nil }
	-- "Typeface:STYLE,STYLE:size" (iupFontParseWin)
	if s:sub(1, 1) ~= "-" and s:find(":", 1, true) then
		local face, styles, size = s:match("^([^:]*):([^:]*):(.*)$")
		if face then
			for word in styles:gmatch("[^,]+") do
				if word == "BOLD" then out.bold = true
				elseif word == "ITALIC" then out.italic = true
				elseif word == "UNDERLINE" then out.underline = true
				elseif word == "STRIKEOUT" then out.strikeout = true end
			end
			local n = tonumber(size)
			if n and n ~= 0 and math.floor(n) == n then
				out.face = face ~= "" and face or nil
				out.size = n
				return out
			end
			out.bold, out.italic, out.underline, out.strikeout = false, false, false, false
		end
	end
	-- iupFontParsePango: words are separated by spaces and commas, read from the end.
	if s:sub(1, 1) == "-" then return out end
	-- The family as written, before IUP strips style words from it: the file to draw with
	-- is looked up by this first ("HPE Graphik Medium" names a real face).
	local written = s:match("^%s*([^,]-)%s*,")
	if written and written ~= "" then out.written = written end
	local last = #s
	local function word_before(stop)
		while stop > 0 and (s:sub(stop, stop) == " " or s:sub(stop, stop) == ",") do stop = stop - 1 end
		local start = stop
		while start > 0 and s:sub(start, start) ~= " " and s:sub(start, start) ~= "," do start = start - 1 end
		return start + 1, stop
	end
	local a, b = word_before(last)
	if b >= a then
		local size = atoi(s:sub(a, b))
		if size ~= 0 then out.size = size; last = a - 1 end
	end
	a, b = word_before(last)
	while b >= a do
		local ok, style = style_word(s:sub(a, b))
		if not ok then break end
		if style then out[style] = true end
		last = a - 1
		a, b = word_before(last)
	end
	while last > 0 and (s:sub(last, last) == " " or s:sub(last, last) == ",") do last = last - 1 end
	local first = 1
	while first <= last and (s:sub(first, first) == " " or s:sub(first, first) == ",") do first = first + 1 end
	if first <= last then out.face = s:sub(first, last) end
	return out
end

-- Fonts a process registered itself (ctx:registerFont -> platform.register_font):
-- lower-cased face name -> { regular=, bold=, italic=, bolditalic= } file paths.
local registered = {}

local function style_key(bold, italic)
	if bold and italic then return "bolditalic" elseif bold then return "bold" elseif italic then return "italic" end
	return "regular"
end

--- Make a font file's faces findable by the names it carries (family, full name).
function M.register(path)
	local B = M.backend
	local names = B and B.font_names and B.font_names(path)
	if not names then return false end
	-- GDI measures text the way IUP did (see Font:measure), so it has to know the file.
	if B.font_private then B.font_private(path) end
	local family = names[16] or names[1]
	local sub = (names[17] or names[2] or "Regular"):lower()
	local bold = sub:find("bold") ~= nil
	local italic = sub:find("italic") ~= nil or sub:find("oblique") ~= nil
	local function add(face, key)
		if not face then return end
		face = face:lower()
		registered[face] = registered[face] or {}
		registered[face][key] = registered[face][key] or path
	end
	add(family, style_key(bold, italic))
	-- "HPE Graphik Medium": the full name works as a face of its own, regular style
	add(names[4], "regular")
	if names[1] and names[1] ~= family then add(names[1], style_key(bold, italic)) end
	face_ids = {}
	by_string = {}
	return true
end

local function registered_path(face, bold, italic)
	local r = face and registered[face:lower()]
	if not r then return nil end
	return r[style_key(bold, italic)] or (bold and italic and (r.bold or r.italic)) or r.regular
end

local function face_id(face, bold, italic)
	local B = M.backend
	if not B then return 0 end
	local key = (face or "") .. "|" .. (bold and "b" or "") .. "|" .. (italic and "i" or "")
	local id = face_ids[key]
	if id ~= nil then return id or 0 end
	local path = registered_path(face, bold, italic)
		or (face and B.font_find and B.font_find(face, bold, italic))
	if not path and (bold or italic) and face then
		-- No styled file: fall back to the regular face (and remember it is synthetic).
		path = B.font_find and B.font_find(face, false, false)
	end
	local loaded = path and B.font_load and B.font_load(path)
	face_ids[key] = loaded or false
	return loaded or 0
end

--- A font object for an IUP font string.
function M.get(s)
	s = s or Element.globals.DEFAULTFONT or M.fallback
	local f = by_string[s]
	if f then return f end
	local p = M.parse(s)
	if not p.size then
		local fb = M.parse(Element.globals.DEFAULTFONT or M.fallback)
		p.size = fb.size or 9
		p.face = p.face or fb.face
	end
	if not p.face then p.face = M.parse(Element.globals.DEFAULTFONT or M.fallback).face end
	local px
	-- iupWIN_PT2PIXEL: MulDiv(size, dpi, 72), a whole number of pixels, as GDI's lfHeight.
	if p.size < 0 then px = -p.size else px = math.floor(p.size * M.dpi / 72 + 0.5) end
	f = setmetatable({
		str = s, face = p.face, bold = p.bold, italic = p.italic,
		underline = p.underline, strikeout = p.strikeout, pt = p.size, px = px,
	}, Font)
	if p.written and p.written ~= p.face and (registered_path(p.written, p.bold, p.italic)
		or (M.backend and M.backend.font_find and M.backend.font_find(p.written, p.bold, p.italic))) then
		f.id = face_id(p.written, p.bold, p.italic)
	else
		f.id = face_id(p.face, p.bold, p.italic)
	end
	-- The GDI font IUP would have created for this string (measuring only).
	local B = M.backend
	if B and B.gdi_font and p.face then f.gid = B.gdi_font(p.face, p.bold, p.italic) end
	count = count + 1
	if count > 2048 then M.reset() end
	by_string[s] = f
	return f
end

--- The font an element draws with (its FONT, inherited, else DEFAULTFONT).
function M.forElement(el)
	return M.get(Element.getAttribute(el, "FONT"))
end

--- Measure `text` (multi-line aware). `wrap` is a wrap width in pixels or nil.
function Font:measure(text, wrap)
	text = text or ""
	local B = M.backend
	if text == "" then
		local _, h = self:charsize()
		return 0, h
	end
	if self.gid and B.gdi_text_size then
		local w, h = B.gdi_text_size(self.gid, self.px, text, wrap or 0)
		if w then return w, h end
	end
	local w, h = B.text_size(self.id, self.px, text, wrap or 0)
	return math.ceil(w), math.ceil(h)
end

--- IUP character size: average width and line height in pixels.
function Font:charsize()
	if self._cw then return self._cw, self._ch end
	local B = M.backend
	local ascent, descent, line_h, avg
	if self.gid and B.gdi_metrics then ascent, descent, line_h, avg = B.gdi_metrics(self.gid, self.px) end
	if not ascent then ascent, descent, line_h, avg = B.font_metrics(self.id, self.px) end
	self._ascent, self._descent = ascent, descent
	self._cw = math.max(1, math.floor(avg + 0.5))
	self._ch = math.max(1, math.ceil(line_h))
	return self._cw, self._ch
end

function Font:ascent()
	self:charsize()
	return self._ascent
end

--- A variant of this font (used by widgets that bold a selected item).
function Font:with(opts)
	local s = (self.face or "") .. "," .. ((opts.bold or (opts.bold == nil and self.bold)) and " Bold" or "")
		.. ((opts.italic or (opts.italic == nil and self.italic)) and " Italic" or "")
		.. " " .. tostring(opts.size or self.pt)
	return M.get(s)
end

M.Font = Font

return M
