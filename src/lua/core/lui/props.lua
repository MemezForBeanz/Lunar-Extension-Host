--- Typed props and the attributes they become.
--
-- A primitive lists the prop groups it accepts (`core.lui.primitives`); each group is a
-- table `propName -> { ATTRIBUTE, converter, types }`. `attributes(def, props)` turns a
-- props table into the attribute map the widget should have, and the reconciler writes
-- only the entries that differ from the last map it wrote. Nothing in here touches a
-- widget.
--
-- The names are Lunar's, not IUP's: `hidden` / `invisible`, `grow`, `tooltip`,
-- `focusable`, `selected`. IUP attributes and callbacks are reachable only through the
-- explicit compatibility namespace `iup = { RASTERSIZE = "40x", k_any = fn }`.
--
-- In development mode (the default; `ui.setDevMode(false)` or `LUNAR_LUI_DEV=0` turns it
-- off) `validate` rejects an unknown prop, a value of the wrong type, a typed prop and a
-- raw attribute that set the same attribute, and a theme `role` combined with a palette
-- token colour (see "Styling ownership" in docs/lunar-ui.md).
--
-- @module core.lui.props
local M = {}

local fmt = string.format

M.dev = os.getenv("LUNAR_LUI_DEV") ~= "0"

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
	return v and "YES" or "NO"
end

function M.onoff(v)
	if v == nil then return nil end
	return v and "ON" or "OFF"
end

--- `grow`: does the element take a share of its box's free space? `true` both ways,
-- `"x"` horizontally, `"y"` vertically, `false` never. Unset: the primitive's own
-- default (boxes and controls do not grow; entries, lists and tabs grow across).
local GROW = { x = "HORIZONTAL", y = "VERTICAL" }
function M.grow(v)
	if v == nil then return nil end
	if v == true then return "YES" elseif v == false then return "NO" end
	return GROW[v]
end
local function grow_ok(v) return v == true or v == false or GROW[v] ~= nil, 'true, false, "x" or "y"' end

--- `{ w, h }` (either may be nil: natural on that axis).
function M.size(v)
	if v == nil then return nil end
	local w, h = v[1] or v.w, v[2] or v.h
	return (w and M.int(w) or "") .. "x" .. (h and M.int(h) or "")
end

--- A margin or padding: a number for both axes, or `{ x, y }`.
function M.spacing(v)
	if v == nil then return nil end
	if type(v) == "number" then return M.int(v) .. "x" .. M.int(v) end
	return M.int(v[1] or v.x or 0) .. "x" .. M.int(v[2] or v.y or 0)
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

--- Set while converting one prop: whether a palette token was read.
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

local function is_token(v)
	return (type(v) == "table" and v.token ~= nil)
		or (type(v) == "string" and v:match("^[%a_][%w_]*$") ~= nil)
end
M.isToken = is_token

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

-- Alignment -------------------------------------------------------------------------------

-- A box aligns its children across its own direction.
local BOX_ALIGN = {
	h = { start = "ATOP", center = "ACENTER", ["end"] = "ABOTTOM" },
	v = { start = "ALEFT", center = "ACENTER", ["end"] = "ARIGHT" },
}
local function box_align(dir)
	local words = BOX_ALIGN[dir]
	return function(v) return words[v] end, function(v) return words[v] ~= nil, '"start", "center" or "end"' end
end
local hconv, hok = box_align("h")
local vconv, vok = box_align("v")

-- A control aligns its text and image: `align` across, `valign` down.
local H = { left = "ALEFT", center = "ACENTER", right = "ARIGHT" }
local V = { top = "ATOP", center = "ACENTER", bottom = "ABOTTOM" }
local function h_ok(v) return H[v] ~= nil, '"left", "center" or "right"' end
local function v_ok(v) return V[v] ~= nil, '"top", "center" or "bottom"' end

local POSITION = { left = "LEFT", right = "RIGHT", top = "TOP", bottom = "BOTTOM" }
local function pos_ok(v) return POSITION[v] ~= nil, '"left", "right", "top" or "bottom"' end

-- Groups ---------------------------------------------------------------------------------

-- { attribute, converter, types (a set of Lua types, or a check function) }
local function a(attr, conv, types) return { attr, conv, types } end
local NUM_STR = { number = true, string = true }
local NUM = { number = true }
local STR = { string = true }
local BOOL = { boolean = true }
local SIZE = { table = true }
local SPACE = { number = true, table = true }
local COLOR = { string = true, table = true }
M.TYPES = { NUM_STR = NUM_STR, NUM = NUM, STR = STR, BOOL = BOOL, SIZE = SIZE, SPACE = SPACE, COLOR = COLOR }
M.a = a

--- Props every primitive accepts.
M.common = {
	enabled = a("ACTIVE", M.bool, BOOL),
	tooltip = a("TIP", M.str, STR),
	font = a("FONT", M.str, STR),
	bg = a("BGCOLOR", M.color, COLOR),
	fg = a("FGCOLOR", M.color, COLOR),
	role = a("THEMEROLE", M.str, STR),
	name = a("NAME", M.str, STR),
	grow = a("EXPAND", M.grow, grow_ok),
	minSize = a("MINSIZE", M.size, SIZE),
	maxSize = a("MAXSIZE", M.size, SIZE),
	focusable = a("CANFOCUS", M.bool, BOOL),
	tabTitle = a("TABTITLE", M.str, STR),
	tabImage = a("TABIMAGE", M.str, STR),
	cursor = a("CURSOR", M.str, STR),
}

--- Boxes: hbox, vbox, zbox, frames, scroll boxes.
M.box = {
	gap = a("GAP", M.int, NUM),
	padding = a("MARGIN", M.spacing, SPACE),
	uniform = a("HOMOGENEOUS", M.bool, BOOL),
}
M.hbox = { align = a("ALIGNMENT", hconv, hok) }
M.vbox = { align = a("ALIGNMENT", vconv, vok) }

--- Controls that draw a caption (buttons, labels, toggles). `align`/`valign` are
-- combined by the `derive` rule below.
M.control = {
	padding = a("PADDING", M.spacing, SPACE),
	image = a("IMAGE", M.str, STR),
	spacing = a("SPACING", M.int, NUM),
	imagePosition = a("IMAGEPOSITION", function(v) return POSITION[v] end, pos_ok),
}
M.controlAlign = { align = h_ok, valign = v_ok }

--- Props that become more than one attribute, or share one. `{ keys, check, rule }`.
M.composite = {
	-- size = { w, h }, width, height: RASTERSIZE (either part may be left natural)
	{ keys = { size = SIZE, width = NUM, height = NUM }, rule = function(p, out)
		local s = p.size
		local w = p.width or (s and (s[1] or s.w)) or nil
		local h = p.height or (s and (s[2] or s.h)) or nil
		if w == nil and h == nil then return end
		out.RASTERSIZE = (w and M.int(w) or "") .. "x" .. (h and M.int(h) or "")
	end },
	-- hidden: not displayed and takes no space (FLOATING + VISIBLE); invisible: not
	-- drawn but keeps its space (VISIBLE). `false` writes them back.
	{ keys = { hidden = BOOL, invisible = BOOL }, rule = function(p, out)
		if p.hidden ~= nil then
			out.FLOATING = p.hidden and "YES" or "NO"
			out.VISIBLE = p.hidden and "NO" or "YES"
		end
		if p.invisible ~= nil and not p.hidden then
			out.VISIBLE = p.invisible and "NO" or "YES"
		end
	end },
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

local function raw(v)
	local t = type(v)
	if t == "number" then return num(v) end
	if t == "boolean" then return v and "YES" or "NO" end
	return v -- strings and handles
end

-- Validation ---------------------------------------------------------------------------

local RESERVED = { children = true, key = true, ref = true, iup = true }

local function check_type(name, prim, v, types)
	if types == nil then return end
	if type(types) == "function" then
		local ok, want = types(v)
		if not ok then error(fmt("lui: %s.%s must be %s, got %s", prim, name, want, tostring(v)), 0) end
		return
	end
	if not types[type(v)] then
		local list = {}
		for t in pairs(types) do list[#list + 1] = t end
		table.sort(list)
		error(fmt("lui: %s.%s must be a %s, got %s", prim, name, table.concat(list, " or "), type(v)), 0)
	end
end

-- The closest known name, for "did you mean".
local function suggest(name, known)
	local lname = name:lower()
	for k in pairs(known) do if k:lower() == lname then return k end end
	for k in pairs(known) do
		if #lname > 2 and (k:lower():find(lname, 1, true) or lname:find(k:lower(), 1, true)) then return k end
	end
	return nil
end

--- The props a primitive knows, as a set (cached on the definition).
function M.known(def)
	if def._known then return def._known end
	local k = {}
	for name in pairs(RESERVED) do k[name] = true end
	for _, group in ipairs(def.groups) do for name in pairs(group) do k[name] = true end end
	for _, c in ipairs(M.composite) do for name in pairs(c.keys) do k[name] = true end end
	if def.controlAlign then for name in pairs(M.controlAlign) do k[name] = true end end
	for name in pairs(def.events) do k[name] = true end
	for name in pairs(def.extra or {}) do k[name] = true end
	def._known = k
	return k
end

--- Development-mode checks of one element's props (see the module header).
function M.validate(def, props)
	if not M.dev then return end
	local known = M.known(def)
	local prim = def.name
	for name, v in pairs(props) do
		if type(name) == "string" and not known[name] then
			local s = suggest(name, known)
			local hint = s and (" (did you mean `" .. s .. "`?)") or ""
			if name:match("^[%u%d_]+$") or name:match("_cb$") then
				hint = " (IUP attributes and callbacks go in `iup = { " .. name .. " = ... }`)"
			end
			error(fmt("lui: %s has no prop `%s`%s", prim, name, hint), 0)
		end
	end
	for _, group in ipairs(def.groups) do
		for name, spec in pairs(group) do
			if props[name] ~= nil then check_type(name, prim, props[name], spec[3]) end
		end
	end
	for _, c in ipairs(M.composite) do
		for name, types in pairs(c.keys) do
			if props[name] ~= nil then check_type(name, prim, props[name], types) end
		end
	end
	if def.controlAlign then
		for name, chk in pairs(M.controlAlign) do
			if props[name] ~= nil then check_type(name, prim, props[name], chk) end
		end
	end
	for name, extra in pairs(def.extra or {}) do
		if props[name] ~= nil then check_type(name, prim, props[name], extra) end
	end
	for name in pairs(def.events) do
		if props[name] ~= nil and type(props[name]) ~= "function" then
			error(fmt("lui: %s.%s must be a function, got %s", prim, name, type(props[name])), 0)
		end
	end
	local rawt = props.iup
	if rawt ~= nil then
		if type(rawt) ~= "table" then error(fmt("lui: %s.iup must be a table of IUP attributes and callbacks", prim), 0) end
		-- a typed prop and a raw attribute naming the same attribute: which one wins is
		-- not obvious, so say so
		local typed = M.attributes(def, props, nil, true)
		for k, v in pairs(rawt) do
			if type(v) ~= "function" and typed[k] ~= nil then
				error(fmt("lui: %s sets %s twice: from a typed prop and from iup.%s; keep one", prim, k, k), 0)
			end
		end
	end
	if props.role ~= nil and (is_token(props.bg) or is_token(props.fg)) then
		error(fmt("lui: %s has a theme role and a palette token colour; a widget's colours "
			.. "belong to the theme (role) or to the component (token), not both", prim), 0)
	end
end

--- The attribute map `props` asks for on primitive `def`.
-- @tparam[opt] string text the element's text children, for a primitive with `content`
-- @tparam[opt] boolean typed_only leave out the `iup` namespace (for validation)
-- @treturn table `{ ATTR = value }`
-- @treturn table|nil the attributes that came from palette tokens (`{ BGCOLOR = true }`)
function M.attributes(def, props, text, typed_only)
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
	for _, c in ipairs(M.composite) do c.rule(props, out) end
	if def.controlAlign and (props.align ~= nil or props.valign ~= nil) then
		local h, v = H[props.align], V[props.valign]
		if v then out.ALIGNMENT = (h or "ACENTER") .. ":" .. v else out.ALIGNMENT = h end
	end
	if def.derive then def.derive(props, out) end
	if not typed_only and type(props.iup) == "table" then
		for k, v in pairs(props.iup) do
			if type(v) ~= "function" then out[k] = raw(v) end
		end
	end
	M.token_used = false
	return out, tokens
end

return M
