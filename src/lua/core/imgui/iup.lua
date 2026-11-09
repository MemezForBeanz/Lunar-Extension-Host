--- The `iup` table of the ImGui host: IUP's Lua API over a virtual widget tree.
--
-- Code written for iuplua (the host's own UI and every extension) runs against this
-- table unchanged: the same constructors, functions, constants, key codes and
-- callback conventions. Instead of creating native controls, each constructor builds
-- an element (`core.imgui.Element`), and `core.imgui.Runtime` lays the tree out and
-- draws it with Dear ImGui every frame.
--
-- @module core.imgui.iup
local Element = require("core.imgui.Element")
local Classes = require("core.imgui.Classes")

local iup = {}

local Runtime -- loaded lazily: the runtime needs a backend, the API does not
local function rt()
	if not Runtime then Runtime = require("core.imgui.Runtime") end
	return Runtime
end
iup._runtime = rt

local Draw
local function draw()
	if not Draw then Draw = require("core.imgui.Draw") end
	return Draw
end

-- Return codes and position constants (iup.h) --------------------------------------
iup.DEFAULT, iup.IGNORE, iup.CLOSE, iup.CONTINUE = -2, -1, -3, -4
iup.NOERROR, iup.ERROR, iup.OPENED, iup.INVALID = 0, 1, -1, -1
iup.CENTER, iup.LEFT, iup.RIGHT, iup.MOUSEPOS = 0xFFFF, 0xFFFE, 0xFFFD, 0xFFFC
iup.CURRENT, iup.CENTERPARENT, iup.LEFTPARENT, iup.RIGHTPARENT = 0xFFFB, 0xFFFA, 0xFFF9, 0xFFF8
iup.TOP, iup.BOTTOM, iup.TOPPARENT, iup.BOTTOMPARENT = 0xFFFE, 0xFFFD, 0xFFF9, 0xFFF8
iup.BUTTON1, iup.BUTTON2, iup.BUTTON3, iup.BUTTON4, iup.BUTTON5 = 49, 50, 51, 52, 53
iup.SHOW, iup.RESTORE, iup.MINIMIZE, iup.MAXIMIZE, iup.HIDE = 0, 1, 2, 3, 4
iup.PRIMARY, iup.SECONDARY = -1, -2

-- Key codes (iupkey.h) ----------------------------------------------------------------
local K = {
	SP = 32, exclam = 33, quotedbl = 34, numbersign = 35, dollar = 36, percent = 37,
	ampersand = 38, apostrophe = 39, parentleft = 40, parentright = 41, asterisk = 42,
	plus = 43, comma = 44, minus = 45, period = 46, slash = 47, colon = 58,
	semicolon = 59, less = 60, equal = 61, greater = 62, question = 63, at = 64,
	bracketleft = 91, backslash = 92, bracketright = 93, circum = 94, underscore = 95,
	grave = 96, braceleft = 123, bar = 124, braceright = 125, tilde = 126,
	BS = 8, TAB = 9, LF = 10, CR = 13,
	PAUSE = 0xFF13, ESC = 0xFF1B, HOME = 0xFF50, LEFT = 0xFF51, UP = 0xFF52,
	RIGHT = 0xFF53, DOWN = 0xFF54, PGUP = 0xFF55, PGDN = 0xFF56, END = 0xFF57,
	MIDDLE = 0xFF0B, Print = 0xFF61, INS = 0xFF63, Menu = 0xFF67, DEL = 0xFFFF,
	LSHIFT = 0xFFE1, RSHIFT = 0xFFE2, LCTRL = 0xFFE3, RCTRL = 0xFFE4,
	LALT = 0xFFE9, RALT = 0xFFEA, NUM = 0xFF7F, SCROLL = 0xFF14, CAPS = 0xFFE5,
	CLEAR = 0xFFD2, HELP = 0xFFD3, ["KP_Enter"] = 0xFF8D,
}
for i = 1, 12 do K["F" .. i] = 0xFFBE + i - 1 end
for c = 0, 9 do K[tostring(c)] = 48 + c end
for c = 65, 90 do K[string.char(c)] = c; K[string.char(c + 32)] = c + 32 end
iup.KEYS = K

local SHIFT, CTRL, ALT, SYS = 0x10000000, 0x20000000, 0x40000000, 0x80000000
iup.XKEY_SHIFT, iup.XKEY_CTRL, iup.XKEY_ALT, iup.XKEY_SYS = SHIFT, CTRL, ALT, SYS
local bit = require("bit")
function iup.XkeyBase(c) return bit.band(c, 0x0FFFFFFF) end
function iup.XkeyShift(c) return bit.bor(c, SHIFT) end
function iup.XkeyCtrl(c) return bit.bor(c, CTRL) end
function iup.XkeyAlt(c) return bit.bor(c, ALT) end
function iup.XkeySys(c) return bit.bor(c, SYS) end
function iup.isShiftXkey(c) return bit.band(c, SHIFT) ~= 0 end
function iup.isCtrlXkey(c) return bit.band(c, CTRL) ~= 0 end
function iup.isAltXkey(c) return bit.band(c, ALT) ~= 0 end
function iup.isSysXkey(c) return bit.band(c, SYS) ~= 0 end
function iup.isXkey(c) return c >= 128 end
function iup.isprint(c) return c > 31 and c < 127 end

for name, code in pairs(K) do iup["K_" .. name] = code end
-- The full set, modifier variants included, exactly as iupkey.h defines them.
for name, code in pairs(require("core.imgui.keys")) do iup[name] = code end

-- Mouse status strings (iupdef.h iup_isshift & co): 10 characters,
-- [1]=S shift [2]=C ctrl [3]=1 [4]=2 [5]=3 [6]=D double [7]=A alt [8]=Y sys [9]=4 [10]=5.
function iup.isshift(s) return type(s) == "string" and s:sub(1, 1) == "S" end
function iup.iscontrol(s) return type(s) == "string" and s:sub(2, 2) == "C" end
function iup.isbutton1(s) return type(s) == "string" and s:sub(3, 3) == "1" end
function iup.isbutton2(s) return type(s) == "string" and s:sub(4, 4) == "2" end
function iup.isbutton3(s) return type(s) == "string" and s:sub(5, 5) == "3" end
function iup.isdouble(s) return type(s) == "string" and s:sub(6, 6) == "D" end
function iup.isalt(s) return type(s) == "string" and s:sub(7, 7) == "A" end
function iup.issys(s) return type(s) == "string" and s:sub(8, 8) == "Y" end
function iup.isbutton4(s) return type(s) == "string" and s:sub(9, 9) == "4" end
function iup.isbutton5(s) return type(s) == "string" and s:sub(10, 10) == "5" end

--- Build a status string from flags (used by the runtime when firing BUTTON_CB/MOTION_CB).
function iup._status(m)
	m = m or {}
	return table.concat({
		m.shift and "S" or " ", m.ctrl and "C" or " ", m.b1 and "1" or " ",
		m.b2 and "2" or " ", m.b3 and "3" or " ", m.double and "D" or " ",
		m.alt and "A" or " ", m.sys and "Y" or " ", m.b4 and "4" or " ", m.b5 and "5" or " ",
	})
end

-- Constructors ----------------------------------------------------------------------
local ALIASES = { gauge = "progressbar" }

local function constructor(classname)
	return function(init)
		if type(init) ~= "table" then init = {} end
		return Element.new(ALIASES[classname] or classname, init)
	end
end

for name in pairs(Classes.MODULES) do iup[name] = constructor(name) end
iup.gauge = constructor("gauge")

-- iuplua's positional box helpers -------------------------------------------------------
function iup.Hbox(...) return iup.hbox({ ... }) end
function iup.Vbox(...) return iup.vbox({ ... }) end

-- Attributes ------------------------------------------------------------------------
local function check(h, fname)
	if not Element.is(h) then
		error("bad argument #1 to '" .. fname .. "' (iup handle expected, got " .. type(h) .. ")", 3)
	end
	return h
end

function iup.SetAttribute(h, name, value)
	check(h, "SetAttribute")
	Element.setAttribute(h, name, value)
end
iup.StoreAttribute = iup.SetAttribute
iup.SetStrAttribute = iup.SetAttribute

function iup.SetAttributeHandle(h, name, handle)
	check(h, "SetAttributeHandle")
	Element.setAttribute(h, name, handle)
end

function iup.GetAttribute(h, name)
	if not Element.is(h) then return nil end
	return Element.getAttribute(h, name)
end

function iup.GetAttributeHandle(h, name)
	if not Element.is(h) then return nil end
	return Element.getHandle(h, name)
end

function iup.SetAttributeId(h, name, id, value)
	check(h, "SetAttributeId")
	Element.setId(h, name, id, value)
end
iup.StoreAttributeId = iup.SetAttributeId

function iup.GetAttributeId(h, name, id)
	if not Element.is(h) then return nil end
	return Element.getId(h, name, id)
end

function iup.SetAttributeId2(h, name, lin, col, value)
	check(h, "SetAttributeId2")
	Element.setAttribute(h, name .. tostring(lin) .. ":" .. tostring(col), value)
end

function iup.GetAttributeId2(h, name, lin, col)
	return iup.GetAttribute(h, name .. tostring(lin) .. ":" .. tostring(col))
end

function iup.ResetAttribute(h, name)
	check(h, "ResetAttribute")
	Element.setAttribute(h, name, nil)
end

--- `iup.SetAttributes(h, "A=1, B=two")`
function iup.SetAttributes(h, list)
	check(h, "SetAttributes")
	for name, value in tostring(list):gmatch("([%w_]+)%s*=%s*\"?([^,\"]*)\"?") do
		Element.setAttribute(h, name, value)
	end
	return h
end

function iup.GetAllAttributes(h)
	local st = Element.state(h)
	local out = {}
	if not st then return out end
	for name in pairs(st.attrs) do
		if not Element.isInternal(name) then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

function iup.SetGlobal(name, value) rt().setGlobal(name, value) end
iup.StoreGlobal = iup.SetGlobal
function iup.GetGlobal(name) return rt().getGlobal(name) end

-- Names -------------------------------------------------------------------------------
function iup.SetHandle(name, h)
	if h == nil then Element.named[name] = nil; return end
	Element.named[name] = h
	local st = Element.state(h)
	if st then st.handlename = name end
end

function iup.GetHandle(name) return Element.named[name] end

function iup.GetName(h)
	local st = Element.state(h)
	return st and st.handlename or nil
end

function iup.GetClassName(h)
	local st = Element.state(h)
	if not st then return nil end
	return st.class.iupname or st.classname
end

function iup.GetClassType(h)
	local st = Element.state(h)
	if not st then return nil end
	return st.class.type or (st.class.children ~= 0 and "container" or "control")
end

-- Tree ----------------------------------------------------------------------------
function iup.Append(parent, child)
	check(parent, "Append"); check(child, "Append")
	return Element.append(parent, child)
end

function iup.Insert(parent, ref, child)
	check(parent, "Insert"); check(child, "Insert")
	return Element.insert(parent, ref, child)
end

function iup.Detach(child)
	if Element.is(child) then Element.detach(child) end
end

function iup.Reparent(child, new_parent, ref)
	check(child, "Reparent"); check(new_parent, "Reparent")
	Element.detach(child)
	if ref then Element.insert(new_parent, ref, child) else Element.append(new_parent, child) end
	rt().reparented(child)
	return 0
end

function iup.Destroy(h)
	if Element.is(h) then rt().destroy(h) end
end

function iup.GetParent(h)
	local st = Element.state(h)
	return st and st.parent or nil
end

function iup.GetChild(h, pos)
	local st = Element.state(h)
	if not st then return nil end
	return st.children[(pos or 0) + 1]
end

function iup.GetChildPos(h, child) return Element.childPos(h, child) end

function iup.GetChildCount(h)
	local st = Element.state(h)
	return st and #st.children or 0
end

function iup.GetNextChild(h, child)
	local st = Element.state(h)
	if not st then return nil end
	if child == nil then return st.children[1] end
	local i = Element.childPos(h, child)
	if i < 0 then return nil end
	return st.children[i + 2]
end

function iup.GetBrother(h)
	local st = Element.state(h)
	if not st or not st.parent then return nil end
	return iup.GetNextChild(st.parent, h)
end

function iup.GetDialog(h)
	if not Element.is(h) then return nil end
	return Element.dialogOf(h)
end

--- Find a child by NAME anywhere under the dialog of `h`.
function iup.GetDialogChild(h, name)
	local root = Element.dialogOf(h) or h
	local function walk(e)
		local st = Element.state(e)
		if not st then return nil end
		if st.attrs.NAME == name then return e end
		for _, c in ipairs(st.children) do
			local f = walk(c)
			if f then return f end
		end
		return nil
	end
	return walk(root)
end

-- Lifecycle, layout and loop (the runtime owns these) -------------------------------
function iup.Map(h) check(h, "Map"); return rt().map(h) end
function iup.Unmap(h) if Element.is(h) then rt().unmap(h) end end
function iup.Show(h) check(h, "Show"); return rt().show(h) end
function iup.ShowXY(h, x, y) check(h, "ShowXY"); return rt().show(h, x, y) end
function iup.Hide(h) if Element.is(h) then return rt().hide(h) end end
function iup.Popup(h, x, y) check(h, "Popup"); return rt().popup(h, x, y) end
function iup.Refresh(h) if Element.is(h) then rt().refresh(h) end end
function iup.RefreshChildren(h) if Element.is(h) then rt().refresh(h) end end
function iup.Update(h) if Element.is(h) then rt().redraw(h) end end
function iup.UpdateChildren(h) if Element.is(h) then rt().redraw(h) end end
function iup.Redraw(h) if Element.is(h) then rt().redraw(h) end end
function iup.SetFocus(h) return rt().setFocus(h) end
function iup.GetFocus() return rt().getFocus() end
function iup.MainLoop() return rt().mainLoop() end
function iup.MainLoopLevel() return rt().loopLevel() end
function iup.ExitLoop() return rt().exitLoop() end
function iup.LoopStep() return rt().loopStep(false) end
function iup.LoopStepWait() return rt().loopStep(true) end
function iup.Flush() return rt().flush() end
function iup.NextField(h) return rt().nextField(h, 1) end
function iup.PreviousField(h) return rt().nextField(h, -1) end
function iup.ConvertXYToPos(h, x, y) return rt().convertXYToPos(h, x, y) end
function iup.Open() return 0 end
function iup.Close() rt().close() end
function iup.Version() return "3.32" end
function iup.GetLanguage() return "ENGLISH" end
function iup.SetLanguage() end

-- Predefined dialogs (built from flat controls; see core.imgui.widgets.dialog) ---------
function iup.Message(title, message) return rt().message(title, message) end
function iup.MessageError(parent, message) return rt().message("Error", message) end
function iup.Alarm(title, message, b1, b2, b3) return rt().alarm(title, message, b1, b2, b3) end
function iup.GetText(title, text) return rt().getText(title, text) end
function iup.GetParam(title, action, format, ...) return rt().getParam(title, action, format, ...) end
function iup.scanf(format, ...) return rt().scanf(format, ...) end
function iup.ListDialog(...) return rt().listDialog(...) end

-- Drawing (valid inside a canvas ACTION callback; see core.imgui.Draw) ---------------
for _, name in ipairs({
	"DrawBegin", "DrawEnd", "DrawSetClipRect", "DrawGetClipRect", "DrawResetClip",
	"DrawParentBackground", "DrawLine", "DrawRectangle", "DrawArc", "DrawPolygon",
	"DrawText", "DrawImage", "DrawSelectRect", "DrawFocusRect", "DrawGetSize",
	"DrawGetTextSize", "DrawGetImageInfo", "DrawEllipse", "DrawPixel", "DrawRoundedRectangle",
}) do
	iup[name] = function(...) return draw()[name](...) end
end

-- Element methods iuplua gives every handle --------------------------------------------
Element.Meta.methods = nil
local methods = {
	show = function(h) return iup.Show(h) end,
	showxy = function(h, x, y) return iup.ShowXY(h, x, y) end,
	popup = function(h, x, y) return iup.Popup(h, x, y) end,
	hide = function(h) return iup.Hide(h) end,
	destroy = function(h) return iup.Destroy(h) end,
	map = function(h) return iup.Map(h) end,
	unmap = function(h) return iup.Unmap(h) end,
	append = function(h, c) return iup.Append(h, c) end,
	insert = function(h, ref, c) return iup.Insert(h, ref, c) end,
	detach = function(h) return iup.Detach(h) end,
	refresh = function(h) return iup.Refresh(h) end,
	update = function(h) return iup.Update(h) end,
	redraw = function(h) return iup.Redraw(h) end,
	getparent = function(h) return iup.GetParent(h) end,
	getchild = function(h, i) return iup.GetChild(h, i) end,
	getdialog = function(h) return iup.GetDialog(h) end,
	setfocus = function(h) return iup.SetFocus(h) end,
}
Element.METHODS = methods
local raw_index = Element.Meta.__index
Element.Meta.__index = function(el, key)
	local m = methods[key]
	if m then return m end
	return raw_index(el, key)
end

--- Is this value a handle of this host?
function iup.ihandle(v) return Element.is(v) end
iup.isihandle = iup.ihandle

iup._Element = Element
iup._Classes = Classes
iup._IMGUI = true

return iup
