--- The retained half of the ImGui host: one element per `iup.*` constructor call.
--
-- IUP keeps a widget tree in C and paints it when the OS asks. Dear ImGui keeps
-- nothing and paints everything every frame. This module is the bridge: the tree
-- IUP used to keep, held in Lua, with IUP's attribute rules (inheritance, class
-- defaults, internal `_IUP` names, handle-valued attributes) and iuplua's way of
-- binding callbacks (`function btn:flat_action() ... end`). `core.imgui.Runtime`
-- walks it every frame and issues the immediate-mode draw calls.
--
-- An element is a plain table with a metatable, so `elem.TITLE = "x"`,
-- `elem.title`, `iup.SetAttribute(elem, "TITLE", "x")` and a constructor table
-- `{ TITLE = "x" }` all land in the same store, exactly as under iuplua.
--
-- @module core.imgui.Element
local M = {}

local Classes -- set by core.imgui.Classes (avoids a require cycle)

--- Private state per element, keyed weakly so a dropped element is collected.
local STATE = setmetatable({}, { __mode = "k" })
M.STATE = STATE

local Meta = {}
M.Meta = Meta

local serial = 0
local named = {}     -- iup.SetHandle names -> element
M.named = named

--- Hooks the runtime installs: invalidate(el, what) is called after any change that
-- needs a new layout ("layout") or only a repaint ("paint").
M.hooks = { invalidate = function() end, destroyed = function() end }

local function upper(name) return string.upper(name) end

--- Attributes IUP registers as not inherited on every class. Everything else that is
-- not internal (`_IUP...`) is inherited, as IUP does with unregistered names.
-- GAP/MARGIN are here because Lunar's patch 0005 made them local.
M.NOINHERIT = { -- fallback only: core.imgui.attrs (IUP's registrations) decides first

	TITLE = true, VALUE = true, RASTERSIZE = true, SIZE = true, USERSIZE = true,
	EXPAND = true, NAME = true, MARGIN = true, GAP = true, CMARGIN = true, CGAP = true,
	NMARGIN = true, NCMARGIN = true, NGAP = true, NCGAP = true,
	ALIGNMENT = true, HOMOGENEOUS = true, NORMALIZESIZE = true, EXPANDCHILDREN = true,
	ORIENTATION = true, IMAGE = true, IMPRESS = true, IMINACTIVE = true, IMAGEINACTIVE = true,
	IMAGEPRESS = true, IMAGEHIGHLIGHT = true, TIP = true, VISIBLE = true, FLOATING = true,
	MINSIZE = true, MAXSIZE = true, POSITION = true, CX = true, CY = true, TABTITLE = true,
	TABIMAGE = true, TABVISIBLE = true, TABACTIVE = true, TABTIP = true, ACTION = true,
	THEMEROLE = false, -- an unregistered attribute: inherits, which Lunar relies on
	CANFOCUS = true, RUN = true, TIME = true, COUNT = true, VALUEPOS = true, CARETPOS = true,
	SELECTION = true, SELECTIONPOS = true, BORDER = true, CORNERRADIUS = true,
	GRADIENTCOLOR = true, GRADIENTDIRECTION = true, PADDING = true, SPACING = true,
	IMAGEPOSITION = true, TEXTALIGNMENT = true, CHILDOFFSET = true, SCROLLBAR = true,
	READONLY = true, MULTILINE = true, PASSWORD = true, CUEBANNER = true, MASK = true,
	NC = true, FILTER = true, PLACEMENT = true, SCREENPOSITION = true, MAXIMIZED = true,
	CLIENTSIZE = true, BARSIZE = true, SHOWGRIP = true, DIRECTION = true, DRAWCOLOR = true,
	DRAWSTYLE = true, DRAWFONT = true, DRAWLINEWIDTH = true, DRAWTEXTALIGNMENT = true,
	DRAWTEXTWRAP = true, DRAWTEXTELLIPSIS = true, DRAWTEXTCLIP = true, DRAWTEXTLAYOUTCENTER = true,
	DRAWTEXTORIENTATION = true, DRAWMAKEINACTIVE = true, DRAWBGCOLOR = true,
	SHOWTABS = true, TABSACTIVELINE = true, ITEMRADIUS = true, ITEMMARKERCOLOR = true,
	SWITCH = true, SWITCHPOS = true, CHECKRADIUS = true, SB_INSET = true, FITCONTENT = true,
	BORDERSHEENCOLOR = true, NATIVETEXTSCROLL = true, STYLE = true, HLCOLOR = false,
	HOSTTABOWNERID = false,
}

--- Values that are colours/fonts IUP inherits for every class (listed for clarity; the
-- default rule already inherits them).
M.INHERIT = { BGCOLOR = true, FGCOLOR = true, FONT = true, ACTIVE = true }

function M.isInternal(name) return name:sub(1, 4) == "_IUP" end

function M.setClasses(c) Classes = c end

function M.state(el) return STATE[el] end

function M.is(el) return type(el) == "table" and STATE[el] ~= nil end

--- Create an element of `class` from a constructor table (children in the array part,
-- attributes as upper-case keys, callbacks as functions).
function M.new(classname, init)
	local class = Classes and Classes.get(classname)
	if not class then error("iup: unknown class '" .. tostring(classname) .. "'", 3) end
	serial = serial + 1
	local el = setmetatable({}, Meta)
	local st = {
		class = class, classname = classname, id = serial,
		attrs = {}, handles = {}, ids = {}, cbs = {},
		children = {}, parent = nil, dialog = nil, mapped = false,
		x = 0, y = 0, w = 0, h = 0,        -- placed rect, client coords of its dialog
		nat_w = 0, nat_h = 0,              -- natural size from the last layout
		data = {},                         -- per-class scratch (scroll offsets, hover...)
	}
	STATE[el] = st
	if init then
		-- Attributes first, then children, so a child appended to a box sees the box's
		-- attributes the way IUP's C constructors set them before IupAppend.
		for k, v in pairs(init) do
			if type(k) == "string" then M.set(el, k, v) end
		end
		local n = init.n or #init
		for i = 1, n do
			local child = init[i]
			if M.is(child) then
				M.append(el, child)
			elseif type(child) == "string" or type(child) == "number" then
				-- iup.list{"a", "b"}: array strings are the items "1", "2", ...
				M.setAttribute(el, tostring(i), child)
			end
		end
	end
	if class.create then class.create(el, st, init) end
	return el
end

-- iuplua maps a lower-case key to a callback when the value is a function and to an
-- attribute otherwise, and is case-insensitive about attribute names.
function M.set(el, key, value)
	local st = STATE[el]
	if not st then error("iup: not an element", 2) end
	if type(value) == "function" then
		st.cbs[upper(key)] = value
		return
	end
	-- iuplua keeps a plain Lua value (a table, a userdata that is not a handle) on the
	-- handle's own table; extensions use that to hang state off a widget.
	if (type(value) == "table" and not M.is(value)) or type(value) == "userdata" then
		st.luavals = st.luavals or {}
		st.luavals[key] = value
		return
	end
	if st.luavals and st.luavals[key] ~= nil and value == nil then st.luavals[key] = nil; return end
	local name = upper(key)
	if value == nil and st.cbs[name] and key ~= name then
		st.cbs[name] = nil
		return
	end
	M.setAttribute(el, name, value)
end

function M.get(el, key)
	local st = STATE[el]
	if not st then return nil end
	if st.luavals and st.luavals[key] ~= nil then return st.luavals[key] end
	local name = upper(key)
	local cb = st.cbs[name]
	if cb and key ~= name then return cb end
	if key ~= name and st.class.callbacks and st.class.callbacks[name] then return cb end
	return M.getAttribute(el, name)
end

local function tostr(value)
	local t = type(value)
	if t == "string" or value == nil then return value end
	if t == "number" then
		if value == math.floor(value) and math.abs(value) < 2^53 then return string.format("%d", value) end
		return tostring(value)
	end
	if t == "boolean" then return value and "YES" or "NO" end
	return tostring(value)
end
M.tostr = tostr

local LAYOUT_ATTRS = {
	RASTERSIZE = true, SIZE = true, USERSIZE = true, EXPAND = true, MARGIN = true, GAP = true,
	CMARGIN = true, CGAP = true, NMARGIN = true, NCMARGIN = true, NGAP = true, NCGAP = true,
	ALIGNMENT = true, HOMOGENEOUS = true, NORMALIZESIZE = true, VISIBLE = true, FLOATING = true,
	MINSIZE = true, MAXSIZE = true, TITLE = true, FONT = true, PADDING = true, SPACING = true,
	IMAGE = true, VALUE = true, BARSIZE = true, SHOWTABS = true, TABTITLE = true, TABIMAGE = true,
	TABVISIBLE = true, VISIBLELINES = true, VISIBLECOLUMNS = true, TABSPADDING = true,
	TABSIMAGESPACING = true, CHILDOFFSET = true, BORDER = true, ORIENTATION = true,
	SCROLLBAR = true, EXPANDCHILDREN = true, POSITION = true, CX = true, CY = true,
	BORDERWIDTH = true, FRAMEWIDTH = true, TABSBREADTH = true, TEXTWRAP = true, WORDWRAP = true,
	CANFOCUS = false, CLIENTSIZE = true, MAXIMIZED = true, FULLSCREEN = true,
}
M.LAYOUT_ATTRS = LAYOUT_ATTRS

--- Store an attribute. Class setters (`class.set[NAME]`) run first; a setter that
-- returns `false` keeps the value out of the store (IUP's "do not store" return).
function M.setAttribute(el, name, value)
	local st = STATE[el]
	if not st then return end
	local class = st.class
	local handle
	if M.is(value) then
		handle = value
		value = st.attrs[name] or ("_EL" .. STATE[value].id)
	else
		value = tostr(value)
	end
	local common = M.commonSet[name]
	if common and common(el, st, value, handle) == false then return end
	local setter = class.set and class.set[name]
	if setter then
		local keep = setter(el, st, value, handle)
		if keep == false then
			M.hooks.invalidate(el, LAYOUT_ATTRS[name] and "layout" or "paint", name)
			return
		end
	end
	if handle then
		st.handles[name] = handle
		st.attrs[name] = value
	else
		st.handles[name] = nil
		st.attrs[name] = value
	end
	M.hooks.invalidate(el, LAYOUT_ATTRS[name] and "layout" or "paint", name)
	if M.SETTERS[name] and M.inherits(class, name) then M.notifyChildren(el, st, name, value, handle) end
end

--- Names some class (or every class) has a setter for; only these need the walk below.
M.SETTERS = {}

--- iAttribNotifyChildren (iup_attrib.c): an inheritable attribute set on an element reaches
-- each descendant that holds no value of its own, through that descendant's class setter
-- (nothing is stored there). Reading inherits by itself; this is for the setters with side
-- effects, such as the fork's split VISIBLE rule that clears the bar's own VISIBLE when a
-- tab shows its page.
function M.notifyChildren(el, st, name, value, handle)
	for _, child in ipairs(st.children) do
		local cs = STATE[child]
		if cs and cs.attrs[name] == nil and M.inherits(cs.class, name) then
			local common = M.commonSet[name]
			if common then common(child, cs, value, handle) end
			local setter = cs.class.set and cs.class.set[name]
			if setter then setter(child, cs, value, handle) end
			M.notifyChildren(child, cs, name, value, handle)
		end
	end
end

--- Setters every class shares (IUP's base class). Returning false keeps the value out of
-- the store; anything else stores it as usual.
M.commonSet = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v); M.SETTERS[k] = true end })

-- THEME / NTHEME: copy a theme user's attributes onto the element, then apply its
-- "IUP<CLASS>" sub-theme (iupAttribSetTheme). NTHEME does not inherit.
local function apply_theme(el, theme, depth)
	local ts = STATE[theme]
	if not ts or depth > 8 then return end
	local st = STATE[el]
	for name, v in pairs(ts.attrs) do
		if not M.isInternal(name) and not name:match("^IUP%u") then
			local h = ts.handles[name]
			M.setAttribute(el, name, h or v)
		end
	end
	local sub = ts.attrs["IUP" .. string.upper(st.class.iupname or st.classname)]
	if sub then
		local sh = ts.handles["IUP" .. string.upper(st.class.iupname or st.classname)] or named[sub]
		if sh then apply_theme(el, sh, depth + 1) end
	end
end

local function theme_setter(el, st, value, handle)
	local theme = handle or (value and named[value])
	if theme then apply_theme(el, theme, 0) end
end
M.commonSet.THEME = theme_setter
M.commonSet.NTHEME = theme_setter
M.NOINHERIT.NTHEME = true

-- IUP's own registrations (scripts/gen_imgui_attrs.py): defaults and inheritance per class.
local REG = require("core.imgui.attrs")
local REG_BASE = REG.base
M.REG = REG

local function registration(class, name)
	local r = REG[class.iupname or class.name]
	local e = r and r[name]
	if e then return e end
	return REG_BASE[name]
end
M.registration = registration

--- Is `name` inherited by children of this element's class? Internal names never are;
-- registered ones follow IUP's IUPAF_NO_INHERIT; unregistered ones always are.
local function inherits(class, name)
	if M.isInternal(name) then return false end
	if class.noinherit and class.noinherit[name] then return false end
	local r = registration(class, name)
	if r then return not r[2] end
	if M.NOINHERIT[name] == true and not REG_BASE[name] then return false end
	return true
end
M.inherits = inherits

--- IUP's registered default for the class, with a global-colour name resolved.
local function registered_default(class, name)
	-- iup_classbase.c registers CANFOCUS "YES" for interactive classes and "NO" for the rest
	if name == "CANFOCUS" and REG_BASE.CANFOCUS then
		local own_reg = REG[class.iupname or class.name]
		if not (own_reg and own_reg.CANFOCUS) then return class.focusable and "YES" or "NO" end
	end
	local r = registration(class, name)
	local d = r and r[1]
	if not d then return nil end
	if d:match("^%u+COLOR$") then return M.globals[d] end
	if d == "DEFAULTFONT" then return M.globals.DEFAULTFONT end
	return d
end
M.registeredDefault = registered_default

--- Read an attribute: class getter, own value, inherited value, class default.
function M.getAttribute(el, name)
	local st = STATE[el]
	if not st then return nil end
	local class = st.class
	local getter = class.get and class.get[name]
	if getter then
		local v = getter(el, st)
		if v ~= nil then return tostr(v) end
	end
	local v = st.attrs[name]
	if v ~= nil then return v end
	if inherits(class, name) then
		local p = st.parent
		while p do
			local ps = STATE[p]
			local pv = ps.attrs[name]
			if pv ~= nil then return pv end -- iAttribGetInheritRec reads every ancestor's own value
			p = ps.parent
		end
	end
	local d = class.defaults and class.defaults[name]
	if type(d) == "function" then d = d(el, st) end
	if d ~= nil then return tostr(d) end
	d = registered_default(class, name)
	if d ~= nil then return d end
	if inherits(class, name) then return M.globalDefault(name) end
	return nil
end

--- Defaults IUP takes from the driver (`DLGBGCOLOR`, `DLGFGCOLOR`, `DEFAULTFONT`).
M.globals = {}
function M.globalDefault(name)
	if name == "BGCOLOR" then return M.globals.DLGBGCOLOR end
	if name == "FGCOLOR" then return M.globals.DLGFGCOLOR end
	if name == "FONT" then return M.globals.DEFAULTFONT end
	if name == "ACTIVE" then return "YES" end
	return nil
end

--- Raw own value, without getters, inheritance or defaults (IupGetAttribute's
-- `iupAttribGet`). Used by layout for EXPAND/SIZE that must not inherit.
function M.own(el, name)
	local st = STATE[el]
	return st and st.attrs[name]
end

--- The element's name, giving it IUP's automatic one ("_IUP_NAME(...)", registered so
-- IupGetHandle finds it) when it has none: what IupGetName returns for a child a
-- VALUE attribute reports.
function M.autoName(el)
	local st = STATE[el]
	if not st then return nil end
	if st.handlename then return st.handlename end
	local name = string.format("_IUP_NAME(%016x)", st.id)
	named[name] = el
	st.handlename = name
	return name
end

function M.getHandle(el, name)
	local st = STATE[el]
	if not st then return nil end
	local h = st.handles[name]
	if h then return h end
	local v = M.getAttribute(el, name)
	if v and named[v] then return named[v] end
	return nil
end

-- Attributes with an id (`ITEM3`, `TABTITLE2`, `1` for lists): IupSetAttributeId stores
-- them as name..id, which is what IUP does too.
function M.setId(el, name, id, value)
	M.setAttribute(el, name .. tostring(id), value)
end

function M.getId(el, name, id)
	return M.getAttribute(el, name .. tostring(id))
end

-- Tree ------------------------------------------------------------------------------

local function dialogOf(el)
	local e = el
	while e do
		local st = STATE[e]
		if st.classname == "dialog" then return e end
		e = st.parent
	end
	return nil
end
M.dialogOf = dialogOf

function M.children(el)
	local st = STATE[el]
	return st and st.children or {}
end

function M.append(parent, child, ref_index)
	local ps, cs = STATE[parent], STATE[child]
	if not ps or not cs then return nil end
	if cs.parent then M.detach(child) end
	local maxc = ps.class.children
	if maxc == 0 then return nil end
	local list = ps.children
	if ref_index then table.insert(list, ref_index, child) else list[#list + 1] = child end
	cs.parent = parent
	if ps.class.childAdded then ps.class.childAdded(parent, ps, child, ref_index or #list) end
	M.hooks.invalidate(parent, "layout", "CHILD")
	return parent
end

--- iChildTreeInsert: before ref_child (the first child when nil), except that an internal
-- first child (a split's sash, a flat control's scrollbar) stays first.
function M.insert(parent, ref_child, child)
	local ps = STATE[parent]
	if not ps then return nil end
	local list = ps.children
	if #list == 0 then return M.append(parent, child) end
	ref_child = ref_child or list[1]
	local first = STATE[list[1]]
	if ref_child == list[1] and first and first.internal then return M.append(parent, child, 2) end
	local idx = 1
	for i, c in ipairs(list) do if c == ref_child then idx = i; break end end
	return M.append(parent, child, idx)
end

--- Add a child the class owns (IUP_INTERNAL): it counts in GetChild/GetChildCount like
-- IUP's, box layout skips it, and its owner sizes and places it. `first` puts it in
-- front (iChildTreeInsertFirst), otherwise it goes last (iupChildTreeAppend).
function M.appendInternal(parent, child, first)
	local ps, cs = STATE[parent], STATE[child]
	if not ps or not cs then return nil end
	if cs.parent then M.detach(child) end
	if first then table.insert(ps.children, 1, child) else ps.children[#ps.children + 1] = child end
	cs.parent = parent
	cs.internal = true
	M.hooks.invalidate(parent, "layout", "CHILD")
	return child
end

--- The children that are not internal, in order.
function M.userChildren(el)
	local st = STATE[el]
	if not st then return {} end
	local list = {}
	for _, c in ipairs(st.children) do
		local cs = STATE[c]
		if cs and not cs.internal then list[#list + 1] = c end
	end
	return list
end

function M.detach(child)
	local cs = STATE[child]
	if not cs or not cs.parent then return end
	local parent = cs.parent
	local ps = STATE[parent]
	for i, c in ipairs(ps.children) do
		if c == child then
			table.remove(ps.children, i)
			if ps.class.childRemoved then ps.class.childRemoved(parent, ps, child, i) end
			break
		end
	end
	cs.parent = nil
	M.hooks.invalidate(parent, "layout", "CHILD")
end

function M.childPos(parent, child)
	local ps = STATE[parent]
	if not ps then return -1 end
	for i, c in ipairs(ps.children) do if c == child then return i - 1 end end
	return -1
end

function M.destroy(el)
	local st = STATE[el]
	if not st or st.destroyed then return end
	st.destroying = true
	-- Children first, as IupDestroy does.
	for i = #st.children, 1, -1 do M.destroy(st.children[i]) end
	local cb = st.cbs.DESTROY_CB
	if cb then pcall(cb, el) end
	if st.class.destroy then pcall(st.class.destroy, el, st) end
	if st.parent then M.detach(el) end
	for name, h in pairs(named) do if h == el then named[name] = nil end end
	st.destroyed = true
	M.hooks.destroyed(el, st)
	STATE[el] = nil
end

-- Callbacks -------------------------------------------------------------------------

--- Call a callback by its IUP name (`ACTION`, `FLAT_ACTION`, `BUTTON_CB`...). Returns
-- the callback's result, or nil when none is set. Errors are reported through
-- `M.hooks.error` (the runtime logs them) instead of tearing down the frame loop.
function M.call(el, name, ...)
	local st = STATE[el]
	if not st then return nil end
	local cb = st.cbs[name]
	if not cb then return nil end
	local ok, r = xpcall(cb, debug.traceback, el, ...)
	if not ok then
		if M.hooks.error then M.hooks.error(el, name, r) else io.stderr:write(tostring(r), "\n") end
		return nil
	end
	return r
end

function M.hasCallback(el, name)
	local st = STATE[el]
	return st and st.cbs[name] ~= nil
end

-- Metatable --------------------------------------------------------------------------

Meta.__index = function(el, key)
	if type(key) ~= "string" then return nil end
	local st = STATE[el]
	if not st then return nil end
	local class = st.class
	local method = class.methods and class.methods[key]
	if method then return method end
	return M.get(el, key)
end

Meta.__newindex = function(el, key, value)
	if type(key) ~= "string" then return end
	M.set(el, key, value)
end

Meta.__tostring = function(el)
	local st = STATE[el]
	if not st then return "iup handle (destroyed)" end
	return string.format("iup handle: %s %d", st.classname, st.id)
end

return M
