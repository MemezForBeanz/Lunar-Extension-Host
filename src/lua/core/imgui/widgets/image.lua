--- Image classes: `iup.imagergba`, `iup.imagergb` and `iup.image`.
--
-- An image keeps its pixels as one RGBA byte string in `st.data.pixels`; the draw
-- context uploads it to a texture the first time it is drawn (`Draw.texture`).
-- iuplua accepts the pixels as a flat table of numbers, a table of rows, or (here)
-- a binary string, which is what the SVG/PNG decoders hand over.
--
-- @module core.imgui.widgets.image
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")

local M = {}

local function bytes_from_numbers(t, channels)
	local parts, chunk = {}, {}
	local n = #t
	local i = 1
	while i <= n do
		local r, g, b = t[i] or 0, t[i + 1] or 0, t[i + 2] or 0
		local a = channels == 4 and (t[i + 3] or 255) or 255
		chunk[#chunk + 1] = string.char(r % 256, g % 256, b % 256, a % 256)
		if #chunk >= 1024 then parts[#parts + 1] = table.concat(chunk); chunk = {} end
		i = i + channels
	end
	parts[#parts + 1] = table.concat(chunk)
	return table.concat(parts)
end

local function rgb_string_to_rgba(s)
	local out = {}
	for i = 1, #s, 3 do out[#out + 1] = s:sub(i, i + 2) .. "\255" end
	return table.concat(out)
end

local function free_texture(st)
	local d = st.data
	if d.tex and d.tex_backend and d.tex_backend.texture_free then
		d.tex_backend.texture_free(d.tex)
	end
	d.tex, d.tex_backend = nil, nil
end

local function destroy_image(el, st)
	free_texture(st)
end

local function take_pixels(el, st, init, channels)
	local src = init and (init.pixels or init.PIXELS)
	if src == nil then
		local lv = st.luavals
		src = lv and (lv.pixels or lv.PIXELS)
	end
	if type(src) == "string" then
		st.data.pixels = channels == 3 and rgb_string_to_rgba(src) or src
	elseif type(src) == "table" then
		if type(src[1]) == "table" then
			local flat = {}
			for _, row in ipairs(src) do for _, v in ipairs(row) do flat[#flat + 1] = v end end
			src = flat
		end
		st.data.pixels = bytes_from_numbers(src, channels)
	end
	st.data.w = tonumber(Element.own(el, "WIDTH"))
	st.data.h = tonumber(Element.own(el, "HEIGHT"))
	if st.luavals then st.luavals.pixels, st.luavals.PIXELS = nil, nil end
end

local function set_pixels(el, st, value, channels)
	local pixels = type(value) == "string" and (channels == 3 and rgb_string_to_rgba(value) or value)
	if not pixels or pixels == st.data.pixels then return false end
	free_texture(st)
	st.data.pixels = pixels
	return false
end

local base = {
	children = 0,
	type = "image",
	transparent = true,
}

local function define(name, channels)
	local def = { name = name }
	for k, v in pairs(base) do def[k] = v end
	def.set = { PIXELS = function(el, st, value) return set_pixels(el, st, value, channels) end }
	def.destroy = destroy_image
	def.create = function(el, st, init)
		take_pixels(el, st, init, channels)
	end
	return Classes.define(def)
end

define("imagergba", 4)
define("imagergb", 3)

-- `iup.image`: 8-bit indexed rows plus colours "0".."255" (or a `colors` table).
Classes.define({
	name = "image", children = 0, type = "image", transparent = true,
	set = { PIXELS = function(el, st, value) return set_pixels(el, st, value, 4) end },
	destroy = destroy_image,
	create = function(el, st, init)
		init = init or {}
		local rows = {}
		for i = 1, #init do if type(init[i]) == "table" then rows[#rows + 1] = init[i] end end
		local flat = init.pixels or (st.luavals and st.luavals.pixels)
		local w = tonumber(Element.own(el, "WIDTH")) or (rows[1] and #rows[1]) or 0
		local h = tonumber(Element.own(el, "HEIGHT")) or #rows
		if type(flat) == "table" and #rows == 0 then
			for y = 1, h do
				local r = {}
				for x = 1, w do r[x] = flat[(y - 1) * w + x] end
				rows[y] = r
			end
		end
		local colors = init.colors or (st.luavals and st.luavals.colors) or {}
		local palette = {}
		for i = 0, 255 do
			local c = Element.own(el, tostring(i)) or colors[i + 1]
			if c == "BGCOLOR" then palette[i] = "\0\0\0\0"
			elseif c then
				local packed = Color.parse(c)
				if packed then
					local r, g, b, a = Color.unpack(packed)
					palette[i] = string.char(r, g, b, a)
				end
			end
		end
		local out = {}
		for y = 1, h do
			local row = rows[y] or {}
			for x = 1, w do out[#out + 1] = palette[row[x] or 0] or "\0\0\0\0" end
		end
		st.data.pixels = table.concat(out)
		st.data.w, st.data.h = w, h
		Element.setAttribute(el, "WIDTH", w)
		Element.setAttribute(el, "HEIGHT", h)
	end,
})

--- Build an RGBA image element directly (used by the SVG and PNG decoders).
function M.imagergba(init)
	return Element.new("imagergba", init)
end

return M
