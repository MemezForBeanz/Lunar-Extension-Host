--- Typed props and the attributes they become.
--
-- A primitive lists the prop groups it accepts (`core.lui.primitives`); each group is a
-- table `propName -> { ATTRIBUTE, converter }`. `attributes(def, props)` turns a props
-- table into the attribute map the widget should have, and the reconciler writes only
-- the entries that differ from the last map it wrote. Nothing in here touches a widget.
--
-- Converters take the prop value (and the primitive, for direction-dependent ones) and
-- return the attribute string, or nil for "leave unset". Strings always pass through
-- untouched, so `gap = L.gap(3)` and `gap = 8` both work.
--
-- Escape hatches: an UPPERCASE prop is a raw attribute (numbers become integers,
-- booleans YES/NO); a lower-case `*_cb` function prop is a raw callback.
--
-- @module core.lui.props
local M = {}

local fmt = string.format

-- Converters ---------------------------------------------------------------------------

local function num(v)
	if v == math.floor(v) then return fmt("%d", v) end
	return tostring(v)
end

function M.str(v)
	if v == nil then return nil end
	if type(v) == "number" then return num(v) end
	return tostring(v)
end

function M.int(v)
	if type(v) == "number" then return fmt("%d", math.floor(v + 0.5)) end
	return M.str(v)
end

function M.bool(v)
	if v == nil then return nil end
	if type(v) == "string" then return v end
	return v and "YES" or "NO"
end

--- `true`/`false`, or "ON"/"OFF" values of toggles.
function M.onoff(v)
	if v == nil then return nil end
	if type(v) == "string" then return v end
	return v and "ON" or "OFF"
end

local EXPAND = {
	horizontal = "HORIZONTAL", vertical = "VERTICAL", both = "YES", none = "NO",
	horizontalfree = "HORIZONTALFREE", verticalfree = "VERTICALFREE",
}
function M.expand(v)
	if v == nil then return nil end
	if v == true then return "YES" elseif v == false then return "NO" end
	return EXPAND[v] or tostring(v)
end

--- `{ w, h }`, `"WxH"`; either part may be nil/false ("" in the string).
function M.size(v)
	if v == nil then return nil end
	if type(v) == "table" then
		local w, h = v[1] or v.w, v[2] or v.h
		return (w and M.int(w) or "") .. "x" .. (h and M.int(h) or "")
	end
	if type(v) == "number" then return M.int(v) .. "x" .. M.int(v) end
	return tostring(v)
end

--- A margin or padding: a number for both axes, `{ x, y }`, or "XxY".
function M.spacing(v)
	if v == nil then return nil end
	if type(v) == "number" then return M.int(v) .. "x" .. M.int(v) end
	if type(v) == "table" then return M.int(v[1] or v.x or 0) .. "x" .. M.int(v[2] or v.y or 0) end
	return tostring(v)
end

-- Colours -------------------------------------------------------------------------------

local palette_fn
--- Where palette tokens resolve. `core.ui.ThemeReactor.palette` unless replaced.
function M.setPalette(fn) palette_fn = fn end
function M.palette()
	if palette_fn then return palette_fn() end
	local ok, TR = pcall(require, "core.ui.ThemeReactor")
	if ok and TR then palette_fn = TR.palette; return TR.palette() end
	return {}
end

--- Set while computing a fiber's attributes: whether a palette token was read.
M.token_used = false

local function hex(s)
	local r, g, b = s:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		local r1, g1, b1 = s:match("^#(%x)(%x)(%x)$")
		if not r1 then return nil end
		r, g, b = r1 .. r1, g1 .. g1, b1 .. b1
	end
	return fmt("%d %d %d", tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

--- `"r g b"`, `{ r, g, b }`, `"#rrggbb"`, `"#rgb"`, or a palette token name
-- (`"text_secondary"`), resolved through the active theme and re-resolved on each
-- theme switch. A token the palette lacks leaves the attribute unset;
-- `ui.token(name, fallback)` gives it a fallback.
function M.color(v)
	if v == nil then return nil end
	local t = type(v)
	if t == "table" then
		if v.token then
			M.token_used = true
			local p = M.palette()
			local c = p and p[v.token]
			if c == nil or c == "" then return v.fallback and M.color(v.fallback) or nil end
			return tostring(c)
		end
		return fmt("%d %d %d", v[1] or v.r or 0, v[2] or v.g or 0, v[3] or v.b or 0)
	end
	v = tostring(v)
	if v:match("^%d+%s+%d+%s+%d+") then return v end
	if v:sub(1, 1) == "#" then return hex(v) or v end
	if v:match("^[%a_][%w_]*$") then return M.color({ token = v }) end
	return v
end

--- `ui.token(name, fallback)`: an explicit palette token with a fallback colour.
function M.token(name, fallback) return { token = name, fallback = fallback } end

-- Alignment: words per box direction ---------------------------------------------------

local ALIGN = {
	h = { start = "ATOP", top = "ATOP", center = "ACENTER", ["end"] = "ABOTTOM", bottom = "ABOTTOM" },
	v = { start = "ALEFT", left = "ALEFT", center = "ACENTER", ["end"] = "ARIGHT", right = "ARIGHT" },
	-- a control's text: "left", "center", "right", or "left:center" style pairs
	c = { left = "ALEFT", center = "ACENTER", right = "ARIGHT", top = "ATOP", bottom = "ABOTTOM",
		start = "ALEFT", ["end"] = "ARIGHT" },
}
local function align_for(dir)
	local words = ALIGN[dir]
	return function(v)
		if v == nil then return nil end
		v = tostring(v)
		if v:match("^A%u") then return v end
		if dir == "c" and v:find(":") then
			local a, b = v:match("^(%w+):(%w+)$")
			return (words[a] or a) .. ":" .. (words[b] or b)
		end
		return words[v] or v
	end
end
M.alignH, M.alignV, M.alignC = align_for("h"), align_for("v"), align_for("c")

local ORIENT = { horizontal = "HORIZONTAL", vertical = "VERTICAL" }
function M.orientation(v) if v == nil then return nil end return ORIENT[v] or tostring(v) end

-- Groups ---------------------------------------------------------------------------------

local function a(attr, conv) return { attr, conv } end

--- Props every primitive accepts.
M.common = {
	visible = a("VISIBLE", M.bool),
	enabled = a("ACTIVE", M.bool),
	tip = a("TIP", M.str),
	font = a("FONT", M.str),
	bg = a("BGCOLOR", M.color),
	fg = a("FGCOLOR", M.color),
	role = a("THEMEROLE", M.str),
	name = a("NAME", M.str),
	expand = a("EXPAND", M.expand),
	minSize = a("MINSIZE", M.size),
	maxSize = a("MAXSIZE", M.size),
	canFocus = a("CANFOCUS", M.bool),
	tabTitle = a("TABTITLE", M.str),
	tabImage = a("TABIMAGE", M.str),
	cursor = a("CURSOR", M.str),
}

--- Boxes: hbox, vbox, zbox, frames, scroll boxes.
M.box = {
	gap = a("GAP", M.int),
	padding = a("MARGIN", M.spacing),
	homogeneous = a("HOMOGENEOUS", M.bool),
}
M.hbox = { align = a("ALIGNMENT", M.alignH) }
M.vbox = { align = a("ALIGNMENT", M.alignV) }

--- Controls that draw a caption (buttons, labels, toggles).
M.control = {
	padding = a("PADDING", M.spacing),
	align = a("ALIGNMENT", M.alignC),
	image = a("IMAGE", M.str),
	spacing = a("SPACING", M.int),
	imagePosition = a("IMAGEPOSITION", function(v) return v and tostring(v):upper() end),
}

--- Composite rules: props that become more than one attribute, or that share one.
-- Each is `fn(props, out)`, run after the per-prop table.
M.composite = {
	-- `size = { w, h }`, `width`, `height`: RASTERSIZE (either part may be left natural)
	function(p, out)
		local s = p.size
		if s ~= nil and type(s) ~= "table" then out.RASTERSIZE = M.size(s); return end
		local w = p.width or (s and (s[1] or s.w)) or nil
		local h = p.height or (s and (s[2] or s.h)) or nil
		if w == nil and h == nil then return end
		out.RASTERSIZE = (w and M.int(w) or "") .. "x" .. (h and M.int(h) or "")
	end,
	-- `hidden = true`: out of the layout as well as invisible (FLOATING + VISIBLE), the
	-- pattern the shell uses to hide something without leaving a gap. `hidden = false`
	-- writes both back.
	function(p, out)
		if p.hidden == nil then return end
		out.FLOATING = p.hidden and "YES" or "NO"
		out.VISIBLE = p.hidden and "NO" or "YES"
	end,
}

--- Attributes the layout depends on: a change to one of these asks for an `iup.Refresh`.
M.LAYOUT = {
	RASTERSIZE = true, SIZE = true, EXPAND = true, MARGIN = true, GAP = true, ALIGNMENT = true,
	HOMOGENEOUS = true, VISIBLE = true, FLOATING = true, MINSIZE = true, MAXSIZE = true,
	TITLE = true, FONT = true, PADDING = true, SPACING = true, IMAGE = true, BORDER = true,
	ORIENTATION = true, TABTITLE = true, TABIMAGE = true, VALUEPOS = true, CMARGIN = true,
	CGAP = true, NMARGIN = true, NGAP = true, VISIBLECOLUMNS = true, VISIBLELINES = true,
	WORDWRAP = true, TEXTWRAP = true, IMAGEPOSITION = true, CHILDOFFSET = true,
}

--- Is `k` a raw attribute name (UPPERCASE, digits allowed: `TABTITLE0`, `1`)?
function M.isRaw(k)
	return type(k) == "string" and k:match("^[%u%d_]+$") ~= nil and k:match("%u") ~= nil
end

local function raw(v)
	local t = type(v)
	if t == "number" then return num(v) end
	if t == "boolean" then return v and "YES" or "NO" end
	return v -- strings and handles
end

--- The attribute map `props` asks for on primitive `def`.
-- @treturn table `{ ATTR = value }`
-- @treturn boolean whether a palette token was read
-- @tparam[opt] string text the element's text children, for a primitive with `content`
-- @treturn table|nil the attributes that came from palette tokens (`{ BGCOLOR = true }`)
function M.attributes(def, props, text)
	local out, tokens = {}, nil
	if text ~= nil and def.content then out[def.content] = text end
	for _, group in ipairs(def.groups) do
		for k, spec in pairs(group) do
			local v = props[k]
			if v ~= nil then
				M.token_used = false
				local s = spec[2](v, def)
				if s ~= nil then out[spec[1]] = s end
				if M.token_used then tokens = tokens or {}; tokens[spec[1]] = true end
			end
		end
	end
	for _, rule in ipairs(M.composite) do rule(props, out) end
	if def.derive then def.derive(props, out) end
	-- raw attributes win: they are the escape hatch
	for k, v in pairs(props) do
		if M.isRaw(k) and type(v) ~= "function" then out[k] = raw(v) end
	end
	M.token_used = false
	return out, tokens
end

return M
