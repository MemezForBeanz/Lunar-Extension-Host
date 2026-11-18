--- The primitives: one entry per host widget kind, declared as data.
--
-- A primitive is a table:
--
--     {
--       name = "Button", class = "flatbutton",      -- the iup class it creates
--       groups = { P.common, P.control, {...} },    -- props -> attributes (core.lui.props)
--       controlAlign = true,    -- accepts align/valign for its caption
--       extra = { items = check },                  -- props handled outside the groups
--       content = "TITLE",      -- string children become this attribute (leaf controls)
--       leaf = true,            -- element children are an error
--       live = { VALUE = true },-- compare with the widget, not the last write (controlled)
--       late = { VALUE = true },-- written after the children/items exist
--       events = { onClick = { "flat_action", function(self, ...) return event end } },
--       derive = function(props, out) end,          -- extra attribute rules
--       mount = function(D, props, hrec) return handle, instance end, -- custom creation
--       update = function(D, fiber, props, old) end,                  -- custom updates
--     }
--
-- **Events.** Every handler receives one table, the same shape everywhere:
-- `{ type = "click"|"change"|"key"|"focus"|"blur"|"activate"|"close"|"show"|"draw"|
-- "mouse"|"motion"|"resize", target = widget, ... }` plus, where they apply, `value`,
-- `text`, `previous`, `key`, `x`, `y`, `button`, `pressed`, `width`, `height`. An
-- adapter returning nil drops the callback (it was not that event). A handler may
-- return `ui.CLOSE`, `ui.IGNORE` or `ui.CONTINUE`; nothing means the default.
--
-- `ui.host("flatseek")` builds a primitive for any iup class with the common props and
-- the `iup = { ... }` namespace.
--
-- @module core.lui.primitives
local P = require("core.lui.props")
local vnode = require("core.lui.vnode")

local M = {}
local T = P.TYPES

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
	def.late = def.late or {}
	index_events(def)
	setmetatable(def, { __tostring = function() return "lui." .. def.name end })
	vnode.callable(def)
	M[def.name] = def
	return def
end
M.define = define

-- Event adapters --------------------------------------------------------------------------

local function ev(type_) return function(self) return { type = type_, target = self } end end
local function key(self, c) return { type = "key", target = self, key = c } end
local function one_based(v) return v ~= nil and string.format("%d", v - 1) or nil end
local function list_check(v) return type(v) == "table", "a list of strings" end

-- Boxes ----------------------------------------------------------------------------------

define{ name = "VBox", class = "vbox", groups = { P.common, P.box, P.vbox } }
define{ name = "HBox", class = "hbox", groups = { P.common, P.box, P.hbox } }

--- Children stacked on one another; `selected` (1-based) is the one shown.
define{ name = "ZBox", class = "zbox", groups = { P.common, P.box, P.vbox, {
	selected = P.a("VALUEPOS", one_based, T.NUM),
} }, late = { VALUEPOS = true } }

--- Takes the free space along its box (or a fixed `size`).
define{ name = "Spacer", class = "fill", leaf = true }

--- A frame with a themed border. `title` is its caption.
define{ name = "Frame", class = "flatframe", groups = { P.common, P.box, {
	title = P.a("TITLE", P.str, T.STR),
} } }

--- A scroll box around one child.
define{ name = "Scroll", class = "flatscrollbox", groups = { P.common, P.box } }

--- Tabs: each child is a page, titled by its own `tabTitle`. `selected` is the 1-based
-- page shown; `onChange{ value = index, previous = index }`.
define{ name = "Tabs", class = "flattabs", groups = { P.common, P.box, {
	selected = P.a("VALUEPOS", one_based, T.NUM),
} }, live = { VALUEPOS = true }, late = { VALUEPOS = true },
	events = { onChange = { "tabchangepos_cb", function(self, new, old)
		return { type = "change", target = self, value = new + 1, previous = old + 1 }
	end } } }

--- Two panes and a sash. `direction = "row"` puts them side by side, `"column"` one
-- above the other; `ratio` (0..1) is the first pane's share; `onChange{ value = ratio }`.
local DIRECTION = { row = "VERTICAL", column = "HORIZONTAL" } -- IUP names the sash, not the panes
define{ name = "Split", class = "split", groups = { P.common, {
	direction = P.a("ORIENTATION", function(v) return DIRECTION[v] end,
		function(v) return DIRECTION[v] ~= nil, '"row" or "column"' end),
	ratio = P.a("VALUE", function(v) return string.format("%d", math.floor(v * 1000 + 0.5)) end, T.NUM),
	sashSize = P.a("BARSIZE", P.int, T.NUM),
} }, live = { VALUE = true }, late = { VALUE = true },
	events = { onChange = { "valuechanged_cb", function(self)
		return { type = "change", target = self, value = (tonumber(self.VALUE) or 0) / 1000 }
	end } } }

-- Text and controls -------------------------------------------------------------------

local TEXT = { wrap = P.a("TEXTWRAP", P.bool, T.BOOL), ellipsis = P.a("TEXTELLIPSIS", P.bool, T.BOOL) }

--- Text drawn by IUP itself (`flatlabel`): the string children are the text.
define{ name = "Text", class = "flatlabel", content = "TITLE", leaf = true, controlAlign = true,
	groups = { P.common, P.control, TEXT } }

local function left_release(self, b, pressed)
	if b == 49 and pressed == 0 then return { type = "click", target = self } end
end

--- A native label: text, or an `image`.
define{ name = "Label", class = "label", content = "TITLE", leaf = true, controlAlign = true,
	groups = { P.common, P.control, {
		wrap = P.a("WORDWRAP", P.bool, T.BOOL),
		ellipsis = P.a("ELLIPSIS", P.bool, T.BOOL),
	} },
	events = { onClick = { "button_cb", left_release } } }

--- An image: `image` is a handle name.
define{ name = "Image", class = "label", leaf = true, controlAlign = true, groups = { P.common, P.control },
	events = { onClick = { "button_cb", left_release } } }

--- A button IUP draws (`flatbutton`). The string children are the caption (`&` marks a
-- mnemonic: write `&&` for an ampersand).
local VARIANT = { primary = "primary_btn", secondary = "actionbutton", ghost = "statusbar_button" }
define{ name = "Button", class = "flatbutton", content = "TITLE", leaf = true, controlAlign = true,
	groups = { P.common, P.control, {
		ellipsis = P.a("TEXTELLIPSIS", P.bool, T.BOOL),
		variant = P.a("THEMEROLE", function(v) return VARIANT[v] end,
			function(v) return VARIANT[v] ~= nil, '"primary", "secondary" or "ghost"' end),
	} },
	events = { onClick = { "flat_action", ev("click") } } }

--- A check box or switch (`flattoggle`). `checked` makes it controlled;
-- `onChange{ value = checked }`.
define{ name = "Toggle", class = "flattoggle", content = "TITLE", leaf = true, controlAlign = true,
	groups = { P.common, P.control, {
		checked = P.a("VALUE", P.onoff, T.BOOL),
		switch = P.a("SWITCH", P.bool, T.BOOL),
	} }, live = { VALUE = true },
	events = { onChange = { "flat_action", function(self, state)
		return { type = "change", target = self, value = state == 1 or state == "ON" }
	end } } }

--- A text entry (`text`). `value` makes it controlled: VALUE is written only when it
-- differs from what the widget holds, so typing keeps the caret where it is.
define{ name = "Input", class = "text", leaf = true,
	groups = { P.common, {
		value = P.a("VALUE", P.str, T.STR),
		placeholder = P.a("CUEBANNER", P.str, T.STR),
		readonly = P.a("READONLY", P.bool, T.BOOL),
		password = P.a("PASSWORD", P.bool, T.BOOL),
		border = P.a("BORDER", P.bool, T.BOOL),
		columns = P.a("VISIBLECOLUMNS", P.int, T.NUM),
	} }, live = { VALUE = true },
	events = {
		onChange = { "valuechanged_cb", function(self) return { type = "change", target = self, value = self.VALUE or "" } end },
		onKey = { "k_any", key },
		onFocus = { "getfocus_cb", ev("focus") },
		onBlur = { "killfocus_cb", ev("blur") },
	} }

--- A line. `orientation = "horizontal"` draws across.
local ORIENT = { horizontal = "HORIZONTAL", vertical = "VERTICAL" }
define{ name = "Separator", class = "flatseparator", leaf = true, groups = { P.common, {
	orientation = P.a("ORIENTATION", function(v) return ORIENT[v] end,
		function(v) return ORIENT[v] ~= nil, '"horizontal" or "vertical"' end),
} } }

--- A list IUP draws (`flatlist`). `items` is a list of strings, `selected` the 1-based
-- selected item; `onChange{ value = index, text }`, `onActivate{ value = index, text }`
-- (double-click).
define{ name = "List", class = "flatlist", leaf = true, groups = { P.common, {
	selected = P.a("VALUE", P.int, T.NUM),
	lines = P.a("VISIBLELINES", P.int, T.NUM),
	columns = P.a("VISIBLECOLUMNS", P.int, T.NUM),
} }, extra = { items = list_check }, live = { VALUE = true }, late = { VALUE = true },
	derive = function(p, out)
		if type(p.items) == "table" then
			for i, s in ipairs(p.items) do out[tostring(i)] = tostring(s) end
		end
	end,
	events = {
		onChange = { "flat_action", function(self, text, item, state)
			if state == 1 then return { type = "change", target = self, value = item, text = text } end
		end },
		onActivate = { "dblclick_cb", function(self, item, text)
			return { type = "activate", target = self, value = item, text = text }
		end },
	} }

--- A drawing surface (`canvas`). `onDraw{}` paints (call iup.Draw* on `e.target`);
-- `onMouse{ button = 1|2|3, pressed, x, y }`, `onMotion{ x, y }`, `onResize{ width, height }`.
define{ name = "Canvas", class = "canvas", leaf = true, groups = { P.common },
	events = {
		onDraw = { "action", ev("draw") },
		onMouse = { "button_cb", function(self, b, pressed, x, y)
			return { type = "mouse", target = self, button = b - 48, pressed = pressed == 1, x = x, y = y }
		end },
		onMotion = { "motion_cb", function(self, x, y) return { type = "motion", target = self, x = x, y = y } end },
		onResize = { "resize_cb", function(self, w, h) return { type = "resize", target = self, width = w, height = h } end },
	} }

--- A dialog around one child. Mount it with `ui.mount` and show the root's widget.
-- `onKey{ key }`, `onClose{}`, `onShow{ value = state }`.
define{ name = "Dialog", class = "dialog", groups = { P.common, {
	title = P.a("TITLE", P.str, T.STR),
} },
	events = {
		onKey = { "k_any", key },
		onClose = { "close_cb", ev("close") },
		onShow = { "show_cb", function(self, state) return { type = "show", target = self, value = state } end },
	} }

-- Dropdown: a Lua widget class, not a single iup class ------------------------------

--- A themed dropdown (`core.ui.FlatDropdown`). `items`, `selected` (1-based),
-- `placeholder`, `width`, `grow` (boolean), `font`, `role`, `columns`, `lines`;
-- `onChange{ value = index, text = label }` when the user picks.
define{ name = "Dropdown", class = "dropbutton", leaf = true,
	groups = { { tooltip = P.common.tooltip, enabled = P.common.enabled, name = P.common.name } },
	extra = { items = list_check, selected = T.NUM, placeholder = T.STR, width = T.NUM, grow = T.BOOL,
		font = T.STR, role = T.STR, columns = T.NUM, lines = T.NUM, onChange = { ["function"] = true } },
	mount = function(D, props, hrec)
		local FlatDropdown = require("core.ui.FlatDropdown")
		local dd
		dd = FlatDropdown.new(D.iup, {
			items = props.items, value = props.selected, placeholder = props.placeholder,
			width = props.width, expand = props.grow == true, font = props.font,
			role = props.role, visible_columns = props.columns, max_lines = props.lines,
			on_change = function(index, label)
				local f = hrec.fiber
				local fn = f and f.props.onChange
				if fn then return fn({ type = "change", target = dd.widget, value = index, text = label }) end
			end,
		})
		return dd.widget, dd
	end,
	update = function(_, fiber, props, old)
		local dd = fiber.instance
		if props.items ~= old.items then dd:setItems(props.items or {}, props.selected)
		elseif props.selected ~= old.selected then dd:setValue(props.selected) end
	end }

--- A primitive for any iup class: the common props and the `iup = { ... }` namespace.
-- Cached per class.
local hosts = {}
function M.host(class, opts)
	opts = opts or {}
	local key_ = class .. (opts.leaf and ":leaf" or "") .. (opts.content or "")
	if hosts[key_] then return hosts[key_] end
	local def = {
		kind = "host", name = "host(" .. class .. ")", class = class,
		groups = { P.common }, events = {}, live = {}, late = {}, leaf = opts.leaf,
		content = opts.content,
	}
	index_events(def)
	setmetatable(def, { __tostring = function() return "lui.host(" .. class .. ")" end })
	vnode.callable(def)
	hosts[key_] = def
	return def
end

return M
