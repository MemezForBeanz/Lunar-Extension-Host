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

--- Parse a font string into its parts.
-- @treturn table { face, size (points, or negative pixels), bold, italic, underline, strikeout }
function M.parse(s)
	s = tostring(s or "")
	local face, rest = s:match("^%s*([^,]*),%s*(.*)$")
	if not face then
		-- "Face::size" (old Windows form) or just a face/size
		local f2, sz = s:match("^%s*(.-)::%s*(-?%d+)%s*$")
		if f2 then face, rest = f2, sz else face, rest = s, "" end
	end
	local out = { face = face ~= "" and face or nil, bold = false, italic = false,
		underline = false, strikeout = false, size = nil }
	for word in rest:gmatch("%S+") do
		local n = tonumber(word)
		if n then out.size = n
		else
			local w = word:lower()
			if w == "bold" then out.bold = true
			elseif w == "italic" then out.italic = true
			elseif w == "underline" then out.underline = true
			elseif w == "strikeout" then out.strikeout = true
			end
		end
	end
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
	if p.size < 0 then px = -p.size else px = p.size * M.dpi / 72 end
	f = setmetatable({
		str = s, face = p.face, bold = p.bold, italic = p.italic,
		underline = p.underline, strikeout = p.strikeout, pt = p.size, px = px,
	}, Font)
	f.id = face_id(p.face, p.bold, p.italic)
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
	local w, h = B.text_size(self.id, self.px, text, wrap or 0)
	return math.ceil(w), math.ceil(h)
end

--- IUP character size: average width and line height in pixels.
function Font:charsize()
	if self._cw then return self._cw, self._ch end
	local B = M.backend
	local ascent, descent, line_h, avg = B.font_metrics(self.id, self.px)
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
