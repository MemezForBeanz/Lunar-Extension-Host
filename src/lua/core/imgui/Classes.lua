--- The class registry of the ImGui host: what each `iup.<class>` constructor builds.
--
-- A class is a table. Every field is optional except `name`:
--
--     {
--       name = "flatbutton",
--       children = 0,          -- 0: a leaf; 1: one child; -1: any number
--       defaults = { ... },    -- IUP class defaults (strings, or function(el, st))
--       noinherit = { ... },   -- extra registered names that do not inherit
--       callbacks = { ... },   -- callback names this class fires (for `el.action` reads)
--       set = { NAME = function(el, st, value, handle) end },  -- false: do not store
--       get = { NAME = function(el, st) return value end },
--       methods = { ... },     -- extra methods on the element (rare)
--       create = function(el, st, init) end,
--       destroy = function(el, st) end,
--       childAdded = function(el, st, child, pos) end,
--       childRemoved = function(el, st, child, pos) end,
--
--       type = "void",          -- IupGetClassType: "void" (no native window: boxes, split),
--                               -- "control", "canvas", "dialog", "other"
--       iupname = "canvas",     -- the IUP class it answers to, when it differs from `name`
--
--       -- layout (see core.imgui.Layout)
--       natural = function(el, st, L) return w, h[, children_expand] end, -- before SIZE/RASTERSIZE
--       place = function(el, st, L) end,  -- containers: L.place(child, x, y, w, h)
--       expandDefault = "YES" | function(el, st) end, -- a control's EXPAND when unset
--                               -- (what its IUP Create leaves in ih->expand)
--       expandOverride = function(el, st, L) return bits end, -- IupFill: decided by its box
--       childrenExpand = function(el, st, L) return bits end, -- a container's children_expand
--       userSize = function(el, st) return w, h end, -- its own SIZE/RASTERSIZE reading
--       clipsContent = true,    -- iupLayoutMinContent: gives up everything (tabs, scroll boxes)
--       stacksAlong = function(el, st, horizontal) end, -- iupLayoutMinContent: children add up
--       map = function(el, st, rt) end, -- the class's Map method
--
--       -- paint and input (see core.imgui.Runtime and core.imgui.Draw)
--       draw = function(el, st, dc, rt) end,       -- before children
--       drawAfter = function(el, st, dc, rt) end,  -- after children (borders, scrollbars)
--       clip = true,                               -- children are clipped to the rect
--       clipRect = function(el, st) return x, y, w, h end, -- where children are clipped
--                               -- and hit (a native control keeps its scroll bars apart)
--       event = function(el, st, ev, rt) return consumed end,
--       focusable = true | function(el, st) end,
--       hit = function(el, st, x, y) return inside end,
--       visibleChildren = function(el, st) return list end, -- zbox/tabs: only the current page
--     }
--
-- Classes live in `core.imgui.widgets.*`; a module is loaded the first time one of
-- its classes is constructed, so a session that never shows a seek bar never loads it.
--
-- @module core.imgui.Classes
local M = {}

local Element = require("core.imgui.Element")

local registry = {}

--- Which module defines each class.
M.MODULES = {
	hbox = "boxes", vbox = "boxes", zbox = "boxes", fill = "boxes", cbox = "boxes",
	gridbox = "boxes", normalizer = "boxes", backgroundbox = "boxes", radio = "boxes",
	sbox = "boxes", user = "boxes", frame = "boxes", spacer = "boxes",
	flatbutton = "flatbutton", flatlabel = "flatlabel", flatframe = "flatframe",
	flattoggle = "flattoggle", flatseparator = "flatseparator",
	label = "basic", button = "basic", toggle = "basic", link = "basic",
	progressbar = "basic", canvas = "canvas", dropbutton = "dropbutton",
	flattabs = "flattabs", tabs = "flattabs",
	flatlist = "flatlist", list = "list",
	flatscrollbox = "scrollbox", scrollbox = "scrollbox",
	split = "split",
	menu = "menu", item = "menu", submenu = "menu", separator = "menu",
	text = "text", multiline = "text",
	scintilla = "scintilla",
	flatrows = "flatrows", flatsegmented = "flatsegmented", flatgrid = "flatgrid", flatseek = "flatseek",
	videohost = "videohost",
	dialog = "dialog", timer = "dialog", image = "image", imagergba = "image",
	imagergb = "image", filedlg = "dialog", messagedlg = "dialog", clipboard = "dialog",
}

--- Register a class. Re-registering replaces it (tests swap stubs in).
function M.define(def)
	assert(type(def) == "table" and type(def.name) == "string", "class needs a name")
	if def.children == nil then def.children = 0 end
	def.defaults = def.defaults or {}
	for k in pairs(def.set or {}) do Element.SETTERS[k] = true end
	registry[def.name] = def
	return def
end

function M.get(name)
	local c = registry[name]
	if c then return c end
	local mod = M.MODULES[name]
	if mod then
		local ok, err = pcall(require, "core.imgui.widgets." .. mod)
		if not ok then error("iup: class '" .. name .. "' failed to load: " .. tostring(err), 0) end
		c = registry[name]
	end
	return c
end

function M.has(name) return registry[name] ~= nil or M.MODULES[name] ~= nil end

Element.setClasses(M)

return M
