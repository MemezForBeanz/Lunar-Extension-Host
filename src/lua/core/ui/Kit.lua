--- Small shared pieces every tool page is built from: Carbon icons that follow the
-- theme, buttons that carry them, status lines, empty states, and showing or hiding part
-- of a page safely.
--
-- A page built from these reads as one product whichever extension drew it: the same
-- glyph means the same state, and an empty pane says what it is for in the same place.
--
-- @module core.ui.Kit
local M = {}

local ok_icon, VectorIcon = pcall(require, "core.ui.VectorIcon")
if not ok_icon then VectorIcon = nil end
local ok_reactor, ThemeReactor = pcall(require, "core.ui.ThemeReactor")
if not ok_reactor then ThemeReactor = nil end

local L = require("core.lib.CarbonLayout")

M.ICON_BUTTON = 16
M.ICON_TAB = 16
M.ICON_STATUS = 16
M.ICON_EMPTY = 32

--- What each status looks like: its Carbon glyph and colour role.
M.STATUS = {
	ok = { icon = "checkmark--filled", role = "success" },
	warning = { icon = "warning--alt--filled", role = "warning" },
	error = { icon = "error--filled", role = "error" },
	info = { icon = "information--filled", role = "info" },
	idle = { icon = "circle-dash", role = "neutral" },
}

local icon_dir
local bound_iup

--- Say where the Carbon icon set lives. The host calls this once at startup.
function M.setIconDir(dir) icon_dir = dir end

--- An image handle for a Carbon icon in a theme role, or nil without an icon system.
-- @tparam userdata iup
-- @tparam string name icon file name, no extension
-- @tparam[opt=16] number size
-- @tparam[opt="neutral"] string role a `VectorIcon.roleColor` role
function M.icon(iup, name, size, role)
	if not (VectorIcon and VectorIcon.available and icon_dir) then return nil end
	local ok, handle = pcall(VectorIcon.imageHandle, iup, {
		path = icon_dir .. "/" .. name .. ".svg",
		size = size or M.ICON_BUTTON,
		color = VectorIcon.roleColor(role or "neutral"),
		offsetY = 1,   -- sits on the text's optical centre, not its line box
	})
	return ok and handle or nil
end

-- What a widget's icon is, kept on the widget: an extension's widgets are built before the
-- first theme applies, and go away on a reload, so the widget tree is the only list of them
-- that is always right.
local SPEC = "KITICON"

local function paint(iup, widget, spec)
	local name, size, role, attribute = spec:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
	if not name then return end
	local handle = M.icon(iup, name, tonumber(size), role)
	if handle then iup.SetAttribute(widget, attribute, handle) end
	-- A tab strip copies a page's image when the page is added, so a later change has to
	-- reach the strip as well.
	if handle and attribute == "TABIMAGE" and iup.GetParent(widget) and iup.GetChildPos then
		local strip = iup.GetParent(widget)
		pcall(iup.SetAttributeId, strip, "TABIMAGE", iup.GetChildPos(strip, widget), handle)
	end
	if attribute == "IMAGE" then
		local faded = M.icon(iup, name, tonumber(size), "disabled")
		if faded then iup.SetAttribute(widget, "IMAGEINACTIVE", faded) end
	end
end

local function repaint(iup, widget)
	local spec = iup.GetAttribute(widget, SPEC)
	if spec then paint(iup, widget, spec) end
	local i, child = 0, iup.GetChild(widget, 0)
	while child do
		repaint(iup, child)
		i = i + 1
		child = iup.GetChild(widget, i)
	end
end

local reactor = {}
function reactor:_onThemeApply()
	local manager = ThemeReactor and ThemeReactor.themeManager()
	local root = manager and manager._root
	if root and bound_iup then pcall(repaint, bound_iup, root) end
end
M._reactor = reactor -- the registry holds weakly
if ThemeReactor then ThemeReactor.register(reactor) end

--- Put a themed icon on a widget and keep it the right colour across theme switches.
-- @tparam userdata iup
-- @param widget
-- @tparam string name
-- @tparam[opt] table opts `size`, `role`, `attribute` (default IMAGE)
function M.bindIcon(iup, widget, name, opts)
	opts = opts or {}
	bound_iup = iup
	local attribute = opts.attribute or "IMAGE"
	local role = opts.role
	if not role then
		local widget_role = iup.GetAttribute(widget, "THEMEROLE")
		if widget_role == "primary_btn" or widget_role == "danger_solid" then role = "on_accent"
		elseif widget_role == "danger_btn" then role = "error"
		elseif attribute == "IMAGE" then role = "text"
		else role = "neutral" end
	end
	local spec = table.concat({ name, tostring(opts.size or M.ICON_BUTTON), role, attribute }, "|")
	iup.SetAttribute(widget, SPEC, spec)
	paint(iup, widget, spec)
	return widget
end

--- Hand a widget a little air on one side, so panes either side of a divider don't sit on it.
-- @tparam userdata iup
-- @param widget
-- @tparam string side "left" or "right"
-- @treturn ihandle the wrapped widget
function M.inset(iup, widget, side)
	local air = iup.fill({ RASTERSIZE = L.px(4) .. "x" })
	if side == "left" then return iup.hbox({ air, widget, EXPAND = "YES" }) end
	return iup.hbox({ widget, air, EXPAND = "YES" })
end

--- A button with a leading Carbon icon.
-- @tparam userdata iup
-- @tparam table opts `title`, `icon`, `role` (default actionbutton), `action`, `tip`,
--   `icon_role` (default: text-coloured on a primary, neutral otherwise)
-- @return flatbutton
function M.button(iup, opts)
	local btn = iup.flatbutton({
		TITLE = opts.title or "",
		TIP = opts.tip,
		THEMEROLE = opts.role or "actionbutton",
		IMAGEPOSITION = "LEFT",
		SPACING = "6",
		ACTIVE = opts.active,
		NAME = opts.name,
	})
	if opts.action then
		function btn:flat_action()
			opts.action()
			return iup.DEFAULT
		end
	end
	if opts.icon then M.bindIcon(iup, btn, opts.icon, { role = opts.icon_role }) end
	return btn
end

--- Put Carbon icons on a set of existing buttons.
-- @tparam userdata iup
-- @tparam table map `{ { button, icon_name }, ... }`; nil buttons are skipped
function M.iconize(iup, map)
	for _, pair in ipairs(map) do
		local button, name = pair[1], pair[2]
		if button then
			M.bindIcon(iup, button, name)
			iup.SetAttribute(button, "IMAGEPOSITION", "LEFT")
			iup.SetAttribute(button, "SPACING", "6")
		end
	end
end

--- A line of text led by a status glyph.
-- @tparam userdata iup
-- @tparam[opt] string kind a key of `M.STATUS`
-- @tparam[opt] string text
-- @return flatlabel
function M.statusLine(iup, kind, text)
	local line = iup.flatlabel({
		TITLE = text or "", EXPAND = "HORIZONTAL", THEMEROLE = "settingslabel",
		IMAGEPOSITION = "LEFT", SPACING = "8", ALIGNMENT = "ALEFT:ACENTER",
	})
	if kind then M.setStatus(iup, line, kind, text) end
	return line
end

--- Change what a status line says.
function M.setStatus(iup, line, kind, text)
	local status = M.STATUS[kind] or M.STATUS.idle
	M.bindIcon(iup, line, status.icon, { size = M.ICON_STATUS, role = status.role })
	if text then iup.SetAttribute(line, "TITLE", text) end
end

--- Show or hide part of a page, safely, whichever tab is in front.
--
-- A widget with VISIBLE stored on it stops inheriting from its tab, so one made visible
-- while its tab is behind shows through the tab in front, and stays there. So the attribute
-- is only ever written while the page is in front, then cleared to rejoin the tab's
-- own showing and hiding. A hide stays stored: it has to survive the tab being reselected.
-- @tparam userdata iup
-- @param widget
-- @tparam boolean visible
-- @param anchor any always-visible native control on the same page
function M.show(iup, widget, visible, anchor)
	iup.SetAttribute(widget, "FLOATING", visible and "NO" or "YES")
	if not visible then
		iup.SetAttribute(widget, "VISIBLE", "NO")
		return
	end
	local in_front = anchor and iup.GetAttribute(anchor, "VISIBLE") == "YES"
	if in_front then iup.SetAttribute(widget, "VISIBLE", "YES") end
	iup.ResetAttribute(widget, "VISIBLE")
end

--- A pane that says what it is for until it has something to show.
--
-- @tparam userdata iup
-- @tparam table opts `content` (the real widget), `icon`, `title`, `hint`
-- @treturn ihandle the pane
-- @treturn function `set_empty(boolean)`
-- @treturn ihandle the hint label, for text that changes with state
function M.emptyPane(iup, opts)
	local glyph = iup.flatlabel({ TITLE = "", THEMEROLE = "well", ALIGNMENT = "ACENTER" })
	if opts.icon then M.bindIcon(iup, glyph, opts.icon, { size = M.ICON_EMPTY, role = "neutral" }) end
	local title = iup.flatlabel({ TITLE = opts.title or "", THEMEROLE = "empty_title", ALIGNMENT = "ACENTER" })
	local hint = iup.flatlabel({ TITLE = opts.hint or "", THEMEROLE = "empty_hint", ALIGNMENT = "ACENTER" })
	local placeholder = iup.flatframe({
		iup.vbox({
			iup.fill({}),
			iup.hbox({ iup.fill({}), glyph, iup.fill({}) }),
			iup.hbox({ iup.fill({}), title, iup.fill({}) }),
			iup.hbox({ iup.fill({}), hint, iup.fill({}) }),
			iup.fill({}),
			GAP = L.gap(2), EXPAND = "YES",
		}),
		TITLE = "", THEMEROLE = "well", MARGIN = L.margin(5), EXPAND = "YES",
	})
	local pane = iup.zbox({ placeholder, opts.content, EXPAND = "YES" })
	local function set_empty(empty)
		iup.SetAttribute(pane, "VALUEPOS", empty and "0" or "1")
	end
	return pane, set_empty, hint
end

return M
