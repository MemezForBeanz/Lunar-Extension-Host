--- The primitives: one entry per host widget kind, declared as data.
--
-- A primitive is a table:
--
--     {
--       name = "Button", class = "flatbutton",      -- the iup class it creates
--       groups = { P.common, P.control, {...} },    -- props -> attributes (core.lui.props)
--       content = "TITLE",      -- string children become this attribute (leaf controls)
--       leaf = true,            -- element children are an error
--       live = { VALUE = true },-- compare with the widget, not the last write (controlled)
--       events = { onClick = { "flat_action", function(fn, self, ...) return fn() end } },
--       derive = function(props, out) end,          -- extra attribute rules
--       mount = function(D, props, fiber) return handle, instance end, -- custom creation
--       update = function(D, fiber, props, old) end,                    -- custom updates
--     }
--
-- `ui.host("flatseek")` builds a primitive for any iup class with the common props,
-- raw attributes and raw callbacks.
--
-- @module core.lui.primitives
local P = require("core.lui.props")
local vnode = require("core.lui.vnode")

local M = {}

-- callback name -> { { event, adapter }, ... }, for the trampolines
local function index_events(def)
	def.cbEvents = {}
	for ev, spec in pairs(def.events) do
		local list = def.cbEvents[spec[1]] or {}
		list[#list + 1] = { ev, spec[2] }
		def.cbEvents[spec[1]] = list
	end
end
M.indexEvents = index_events

local function define(def)
	def.kind = "host"
	def.groups = def.groups or { P.common }
	def.events = def.events or {}
	def.live = def.live or {}
	index_events(def)
	setmetatable(def, { __tostring = function() return "lui." .. def.name end })
	vnode.callable(def)
	M[def.name] = def
	return def
end
M.define = define

-- Event adapters: how an iup callback's arguments become the handler's.
local function none(fn) return fn() end
local function key(fn, _, c) return fn(c) end

-- Boxes ----------------------------------------------------------------------------------

define{ name = "VBox", class = "vbox", groups = { P.common, P.box, P.vbox } }
define{ name = "HBox", class = "hbox", groups = { P.common, P.box, P.hbox } }

--- Children stacked on one another; `value` (1-based) is the one shown.
define{ name = "ZBox", class = "zbox", groups = { P.common, P.box, P.vbox, {
	value = { "VALUEPOS", function(v) return string.format("%d", v - 1) end },
} } }

--- `iup.fill`: takes the free space along its box (or a fixed `size`).
define{ name = "Spacer", class = "fill", leaf = true }

--- A frame with a themed border (`iup.flatframe`). `title` is its caption.
define{ name = "Frame", class = "flatframe", groups = { P.common, P.box, {
	title = { "TITLE", P.str },
} } }

--- A scroll box (`iup.flatscrollbox`) around one child.
define{ name = "Scroll", class = "flatscrollbox", groups = { P.common, P.box } }

--- Tabs (`iup.flattabs`): each child is a page, titled by its own `tabTitle` prop.
-- `value` is the 1-based page shown; `onChange(index, previous)`.
define{ name = "Tabs", class = "flattabs", groups = { P.common, P.box, {
	value = { "VALUEPOS", function(v) return string.format("%d", v - 1) end },
} }, live = { VALUEPOS = true },
	events = { onChange = { "tabchangepos_cb", function(fn, _, new, old) return fn(new + 1, old + 1) end } } }

--- Two panes and a sash (`iup.split`). `orientation = "vertical"` puts them side by side
-- (IUP's naming); `value` is the sash position in 0..1000; `onChange(value)`.
define{ name = "Split", class = "split", groups = { P.common, {
	orientation = { "ORIENTATION", P.orientation },
	value = { "VALUE", P.int },
	barSize = { "BARSIZE", P.int },
} }, live = { VALUE = true },
	events = { onChange = { "valuechanged_cb", function(fn, self) return fn(tonumber(self.VALUE)) end } } }

-- Text and controls -------------------------------------------------------------------

--- Text drawn by IUP itself (`iup.flatlabel`): the string children are the text.
define{ name = "Text", class = "flatlabel", content = "TITLE", leaf = true,
	groups = { P.common, P.control, {
		wrap = { "TEXTWRAP", P.bool },
		ellipsis = { "TEXTELLIPSIS", P.bool },
	} } }

--- A native label (`iup.label`): text, or an `image`.
define{ name = "Label", class = "label", content = "TITLE", leaf = true,
	groups = { P.common, P.control, {
		wrap = { "WORDWRAP", P.bool },
		ellipsis = { "ELLIPSIS", P.bool },
	} },
	events = { onClick = { "button_cb", function(fn, _, b, pressed) if b == 49 and pressed == 0 then return fn() end end } } }

--- An image (`iup.label` with IMAGE): `image` is a handle name or a handle.
define{ name = "Image", class = "label", leaf = true, groups = { P.common, P.control },
	events = { onClick = { "button_cb", function(fn, _, b, pressed) if b == 49 and pressed == 0 then return fn() end end } } }

--- A button IUP draws (`iup.flatbutton`). The string children are the caption (a `&`
-- marks a mnemonic, as in IUP: write `&&` for an ampersand). `onClick()`.
define{ name = "Button", class = "flatbutton", content = "TITLE", leaf = true,
	groups = { P.common, P.control, {
		ellipsis = { "TEXTELLIPSIS", P.bool },
		variant = { "THEMEROLE", function(v)
			local roles = { primary = "primary_btn", secondary = "actionbutton", ghost = "statusbar_button" }
			return roles[v] or tostring(v)
		end },
	} },
	events = { onClick = { "flat_action", none } } }

--- A check box or switch (`iup.flattoggle`). `checked` makes it controlled;
-- `onChange(checked)`.
define{ name = "Toggle", class = "flattoggle", content = "TITLE", leaf = true,
	groups = { P.common, P.control, {
		checked = { "VALUE", P.onoff },
		switch = { "SWITCH", P.bool },
	} }, live = { VALUE = true },
	events = { onChange = { "flat_action", function(fn, _, state) return fn(state == 1 or state == "ON") end } } }

--- A text entry (`iup.text`). `value` makes it controlled: VALUE is written only when
-- it differs from what the widget holds, so typing keeps the caret where it is.
-- `onChange(value)`, `onKey(code)`, `onFocus()`, `onBlur()`.
define{ name = "Input", class = "text", leaf = true,
	groups = { P.common, {
		value = { "VALUE", P.str },
		placeholder = { "CUEBANNER", P.str },
		readonly = { "READONLY", P.bool },
		password = { "PASSWORD", P.bool },
		border = { "BORDER", P.bool },
		columns = { "VISIBLECOLUMNS", P.int },
	} }, live = { VALUE = true },
	events = {
		onChange = { "valuechanged_cb", function(fn, self) return fn(self.VALUE or "") end },
		onKey = { "k_any", key },
		onFocus = { "getfocus_cb", none },
		onBlur = { "killfocus_cb", none },
	} }

--- A line (`iup.flatseparator`). `orientation = "horizontal"` draws across.
define{ name = "Separator", class = "flatseparator", leaf = true, groups = { P.common, {
	orientation = { "ORIENTATION", P.orientation },
} } }

--- A list IUP draws (`iup.flatlist`). `items` is a list of strings, `value` the 1-based
-- selected item; `onChange(index, text)`, `onActivate(index, text)` (double-click).
define{ name = "List", class = "flatlist", leaf = true, groups = { P.common, {
	value = { "VALUE", P.int },
	lines = { "VISIBLELINES", P.int },
	columns = { "VISIBLECOLUMNS", P.int },
} }, live = { VALUE = true },
	derive = function(p, out)
		if type(p.items) == "table" then
			for i, s in ipairs(p.items) do out[tostring(i)] = tostring(s) end
		end
	end,
	events = {
		onChange = { "flat_action", function(fn, _, text, item, state) if state == 1 then return fn(item, text) end end },
		onActivate = { "dblclick_cb", function(fn, _, item, text) return fn(item, text) end },
	} }

--- A drawing surface (`iup.canvas`). `onDraw(handle)` is ACTION; `onMouse(button,
-- pressed, x, y, status)`, `onMotion(x, y, status)`, `onResize(w, h)`.
define{ name = "Canvas", class = "canvas", leaf = true, groups = { P.common },
	events = {
		onDraw = { "action", function(fn, self) return fn(self) end },
		onMouse = { "button_cb", function(fn, _, ...) return fn(...) end },
		onMotion = { "motion_cb", function(fn, _, ...) return fn(...) end },
		onResize = { "resize_cb", function(fn, _, ...) return fn(...) end },
	} }

--- A dialog (`iup.dialog`) around one child. Mount it with `ui.mount` and show the
-- root's widget with `iup.Popup`/`ModalMotion`. `onKey(code)`, `onClose()`.
define{ name = "Dialog", class = "dialog", groups = { P.common, {
	title = { "TITLE", P.str },
} },
	events = {
		onKey = { "k_any", key },
		onClose = { "close_cb", none },
		onShow = { "show_cb", function(fn, _, state) return fn(state) end },
	} }

-- Dropdown: a Lua widget class, not a single iup class ------------------------------

--- A themed dropdown (`core.ui.FlatDropdown`). `items`, `value` (1-based),
-- `placeholder`, `width`, `expand` (boolean), `font`, `role`; `onChange(index, label)`
-- when the user picks.
define{ name = "Dropdown", class = "dropbutton", leaf = true, groups = { P.common },
	mount = function(D, props, fiber)
		local FlatDropdown = require("core.ui.FlatDropdown")
		local dd = FlatDropdown.new(D.iup, {
			items = props.items, value = props.value, placeholder = props.placeholder,
			width = props.width, expand = props.expand == true, font = props.font,
			role = props.role, visible_columns = props.columns, max_lines = props.lines,
			on_change = function(index, label)
				local fn = fiber.props.onChange
				if fn then return fn(index, label) end
			end,
		})
		return dd.widget, dd
	end,
	-- only tip/visible/enabled/name map onto the button; the rest are FlatDropdown's
	attributes = function(props)
		local out = {}
		if props.tip ~= nil then out.TIP = P.str(props.tip) end
		if props.enabled ~= nil then out.ACTIVE = P.bool(props.enabled) end
		if props.name ~= nil then out.NAME = P.str(props.name) end
		if props.hidden ~= nil then out.FLOATING = props.hidden and "YES" or "NO"; out.VISIBLE = props.hidden and "NO" or "YES" end
		return out
	end,
	update = function(_, fiber, props, old)
		local dd = fiber.instance
		if props.items ~= old.items then dd:setItems(props.items or {}, props.value)
		elseif props.value ~= old.value then dd:setValue(props.value) end
	end }

--- A primitive for any iup class: the common props, raw UPPERCASE attributes and raw
-- `*_cb` callbacks. Cached per class.
local hosts = {}
function M.host(class, opts)
	opts = opts or {}
	local key_ = class .. (opts.leaf and ":leaf" or "")
	if hosts[key_] then return hosts[key_] end
	local def = {
		kind = "host", name = "host:" .. class, class = class,
		-- padding is ambiguous for an unknown class (MARGIN or PADDING): use the raw name
		groups = { P.common, { gap = P.box.gap } }, events = {}, live = {}, leaf = opts.leaf,
		content = opts.content,
	}
	index_events(def)
	setmetatable(def, { __tostring = function() return "lui.host(" .. class .. ")" end })
	vnode.callable(def)
	hosts[key_] = def
	return def
end

return M
