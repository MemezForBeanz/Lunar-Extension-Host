--- Testing components the way a user meets them: rendered, clicked, typed into.
--
-- ```lua
-- local T = require("core.lui.test")
-- local r = T.render(Counter, { start = 1 })
-- r:click(r:getByText("Add"))
-- assert.equal("Clicked 2 times", r:attr(r:getByRole("counter_text"), "TITLE"))
-- r:unmount()
-- ```
--
-- `render` starts `core.imgui.Runtime` on a fresh Null backend (no window), mounts the
-- element in a dialog (or shows it, when it is a `Dialog`), lays it out and paints one
-- frame. Input goes through the backend's event queue, so clicks hit-test the laid-out
-- widgets and fire the same callbacks a real click would. Queries walk the iup tree.
--
-- @module core.lui.test
local M = {}

local Screen = {}
Screen.__index = Screen

local function boot(opts)
	local Null = require("core.imgui.backend.Null")
	local Runtime = require("core.imgui.Runtime")
	local B = Null.new({ w = opts.w or 800, h = opts.h or 600 })
	Runtime.init(B)
	local Element = require("core.imgui.Element")
	Element.globals.DEFAULTFONT = Element.globals.DEFAULTFONT or "Segoe UI, 9"
	return require("core.imgui.iup"), Runtime, B, Element
end
M.boot = boot

--- Render a component (or an element) into a fresh headless host.
-- @param what an element, or a component with `props`
-- @tparam[opt] table props
-- @tparam[opt] table opts `{ w, h, onError, mount = { ... extra ui.mount opts } }`
function M.render(what, props, opts)
	opts = opts or {}
	local ui = require("core.lui")
	local iup, Runtime, B, Element = boot(opts)
	local el = what
	if not ui.isElement(el) then el = ui.h(what, props or {}) end
	local errors = {}
	local mopts = { iup = iup, theme = false, onError = opts.onError or function(msg) errors[#errors + 1] = msg end }
	for k, v in pairs(opts.mount or {}) do mopts[k] = v end
	local self = setmetatable({ iup = iup, runtime = Runtime, backend = B, Element = Element, errors = errors }, Screen)
	local prim = require("core.lui.primitives")
	if el.type == prim.Dialog then
		self.root = ui.mount(el, mopts)
		self.dialog = self.root:widget()
	else
		local box = iup.vbox({ MARGIN = "0x0", GAP = "0" })
		self.dialog = iup.dialog({ box, RASTERSIZE = (opts.w or 800) .. "x" .. (opts.h or 600) })
		self.container = box
		mopts.parent = box
		self.root = ui.mount(el, mopts)
	end
	if self.dialog then iup.Show(self.dialog) end
	Runtime.frame()
	return self
end

--- Flush pending updates and paint a frame.
function Screen:flush()
	require("core.lui").flushSync()
	self.root:flush()
	self.runtime.frame()
	return self
end

--- Render the root again with new props (or a new element).
function Screen:rerender(x)
	self.root:update(x)
	self.runtime.frame()
	return self
end

function Screen:attr(h, name) return self.iup.GetAttribute(h, name) end

local function walk(iup, h, fn)
	if fn(h) then return true end
	local n = iup.GetChildCount(h) or 0
	for i = 0, n - 1 do
		if walk(iup, iup.GetChild(h, i), fn) then return true end
	end
	return false
end

--- Every handle under the dialog for which `pred(handle)` is true, in tree order.
function Screen:queryAll(pred)
	local out = {}
	walk(self.iup, self.dialog, function(h) if pred(h) then out[#out + 1] = h end end)
	return out
end

local function one(self, list, what)
	if #list == 0 then error("lui.test: no element " .. what, 3) end
	if #list > 1 then error("lui.test: " .. #list .. " elements " .. what .. "; use queryAll", 3) end
	return list[1]
end

--- By visible text: TITLE (or VALUE, for entries). A string matches exactly; a
-- pattern can be given as `{ pattern = "..." }`.
function Screen:queryAllByText(text)
	local iup = self.iup
	return self:queryAll(function(h)
		local t = iup.GetAttribute(h, "TITLE")
		local cls = iup.GetClassName(h)
		if (cls == "text" or cls == "multiline") then t = iup.GetAttribute(h, "VALUE") end
		if t == nil then return false end
		if type(text) == "table" then return tostring(t):match(text.pattern) ~= nil end
		return t == text
	end)
end
function Screen:getByText(text) return one(self, self:queryAllByText(text), "with text '" .. tostring(type(text) == "table" and text.pattern or text) .. "'") end

--- By THEMEROLE (the `role` prop) set on the element itself.
function Screen:queryAllByRole(role)
	local Element = self.Element
	return self:queryAll(function(h) return Element.own(h, "THEMEROLE") == role end)
end
function Screen:getByRole(role) return one(self, self:queryAllByRole(role), "with role '" .. role .. "'") end

--- By NAME (the `name` prop).
function Screen:queryAllByName(name)
	local Element = self.Element
	return self:queryAll(function(h) return Element.own(h, "NAME") == name end)
end
function Screen:getByName(name) return one(self, self:queryAllByName(name), "named '" .. name .. "'") end

--- By iup class name ("flatbutton").
function Screen:queryAllByClass(class)
	local iup = self.iup
	return self:queryAll(function(h) return iup.GetClassName(h) == class end)
end

--- The rectangle a handle was laid out at (dialog client pixels).
function Screen:rect(h)
	local st = self.Element.state(h)
	return st.x, st.y, st.w, st.h
end

--- Click the middle of `h` with the left button: move, press and release, one frame.
function Screen:click(h, opts)
	opts = opts or {}
	self.runtime.frame() -- lay out anything pending, so the click lands where it is drawn
	local x, y, w, hh = self:rect(h)
	if w <= 0 or hh <= 0 then error("lui.test: cannot click an element with no size (hidden?)", 2) end
	local cx, cy = math.floor(x + w / 2), math.floor(y + hh / 2)
	self.backend.queue({ events = {
		{ type = "move", x = cx, y = cy },
		{ type = "press", button = opts.button or 1, x = cx, y = cy, double = opts.double },
		{ type = "release", button = opts.button or 1, x = cx, y = cy },
	} })
	self.runtime.frame()
	return self
end

--- Focus `h` (by clicking it) and type `text`, one character event each.
function Screen:type(h, text)
	self:click(h)
	local evs = {}
	for ch in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do evs[#evs + 1] = { type = "char", char = ch } end
	self.backend.queue({ events = evs })
	self.runtime.frame()
	return self
end

--- Press a key (an iup code, `iup.K_CR`) on whatever has the focus.
function Screen:key(code)
	self.backend.queue({ keys = { { code = code, down = true } } })
	self.runtime.frame()
	return self
end

function Screen:unmount()
	self.root:unmount()
	if self.dialog and self.iup.ihandle(self.dialog) then self.iup.Destroy(self.dialog) end
end

return M
