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
function M.rowList(iup, opts) return require("core.ui.RowList").new(iup, opts) end
function M.segmented(iup, opts) return require("core.ui.RowList").segmented(iup, opts) end
function M.cellGrid(iup, opts) return require("core.ui.CellGrid").new(iup, opts) end
function M.seekBar(iup, opts) return require("core.ui.SeekBar").new(iup, opts) end

--- The edge a row list sits in: the look of a bordered list, and room for its rounded corners.
function M.rowFrame(iup, widget)
	return iup.flatframe({ widget, TITLE = "", EXPAND = "YES", MARGIN = "4x4", THEMEROLE = "list_bordered" })
end

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
		path = (name:find("[/\\]") and name or (icon_dir .. "/" .. name)) .. ".svg",
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
	local air = iup.fill({ RASTERSIZE = L.px(3) .. "x" })   -- 8 + the sash + 8: one 16px gutter
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
	iup.SetAttribute(line, "IMAGEPOSITION", "LEFT")
	iup.SetAttribute(line, "SPACING", "8")
	M.bindIcon(iup, line, status.icon, { size = M.ICON_STATUS, role = status.role })
	if text then iup.SetAttribute(line, "TITLE", text) end
end

local function keep_hidden(iup, widget)
	if not iup.GetChild then return end
	local i, child = 0, iup.GetChild(widget, 0)
	while child do
		if iup.GetAttribute(child, "FLOATING") == "YES" then
			iup.SetAttribute(child, "VISIBLE", "NO")
		else
			keep_hidden(iup, child)
		end
		i = i + 1
		child = iup.GetChild(widget, i)
	end
end

--- Show or hide part of a page, safely, whichever tab is in front.
--
-- A widget with VISIBLE stored on it stops inheriting from its tab, so one made visible
-- while its tab is behind shows through the tab in front, and stays there. So the attribute
-- is only ever written while the page is in front, then cleared to rejoin the tab's
-- own showing and hiding. A hide stays stored: it has to survive the tab being reselected.
-- Clearing the attribute on a box clears it all the way down, so the hidden parts inside a
-- box being shown are hidden again here.
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
	keep_hidden(iup, widget)
end

--- One line that says whether a page is ready to use.
--
-- A page with prerequisites used to spend a card on them, a row each, whether or not
-- anything was wrong. This is one line: ready, or the first blocker with the action that
-- clears it. `Details` lists every item with its action, so nothing is hidden.
--
-- @tparam userdata iup
-- @tparam[opt] table opts `ready` (text when all is well), `anchor` (see `M.show`)
-- @treturn table `{ widget, anchor, blocker, set = function(items[, ready]) }`. `blocker` is the
--   first item in the way, if any; `ready` replaces the text for when all is well; `anchor` is
--   a native control that is always on the page. Each item: `label`, `ok`, `problem` (what is
--   wrong), `action_title`, `action`, `optional` (never blocks; listed in Details).
function M.requirements(iup, opts)
	opts = opts or {}
	local line = M.statusLine(iup, "idle", "")
	iup.SetAttribute(line, "EXPAND", "NO")   -- its action sits right after the words
	local act = iup.flatbutton({ TITLE = "", THEMEROLE = "primary_btn", CANFOCUS = "YES" })
	local more = iup.flatbutton({ TITLE = "Details", THEMEROLE = "link_btn", CANFOCUS = "YES" })
	local list = iup.vbox({ GAP = L.gap(2), MARGIN = L.margin(0), EXPAND = "HORIZONTAL" })
	local rows, current, ready_text, open = {}, nil, nil, false
	for i = 1, 8 do
		local row = { line = M.statusLine(iup, "idle", "") }
		row.act = iup.flatbutton({ TITLE = "", THEMEROLE = "link_btn", CANFOCUS = "YES" })
		function row.act:flat_action()
			if row.item and row.item.action then row.item.action() end
			return iup.DEFAULT
		end
		row.box = iup.hbox({ row.line, row.act, GAP = L.gap(3), ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" })
		rows[i] = row
		iup.Append(list, row.box)
		M.show(iup, row.box, false)
	end
	M.show(iup, list, false)
	local strip = { anchor = line, widget = iup.vbox({
		iup.hbox({ line, act, more, iup.fill({}), iup.vbox({ RASTERSIZE = L.size(1, 32) }), GAP = L.gap(3),
			ALIGNMENT = "ACENTER", EXPAND = "HORIZONTAL" }),
		list, GAP = L.gap(2), EXPAND = "HORIZONTAL",
	}) }

	local function refresh()
		local items, blocker, unmet = current or {}, nil, 0
		for _, item in ipairs(items) do
			if not item.ok then
				if not item.optional then
					unmet = unmet + 1
					blocker = blocker or item
				end
			end
		end
		if blocker then
			M.setStatus(iup, line, "warning", blocker.label .. ": " .. (blocker.problem or "not ready"))
		else
			M.setStatus(iup, line, "ok", ready_text or opts.ready or "Ready")
		end
		local has_action = blocker and blocker.action_title
		if has_action then iup.SetAttribute(act, "TITLE", blocker.action_title) end
		strip.blocker = blocker
		M.show(iup, act, has_action and true or false, line)
		M.show(iup, more, #items > 1, line)
		M.show(iup, list, open, line)
		for i, row in ipairs(rows) do
			local item = items[i]
			row.item = item
			if item and open then
				M.setStatus(iup, row.line, item.ok and "ok" or (item.optional and "idle" or "warning"),
					item.label .. (item.ok and "" or (": " .. (item.problem or "not ready"))))
				iup.SetAttribute(row.act, "TITLE", item.action_title or "")
			end
			M.show(iup, row.act, (item and open and item.action_title) and true or false, line)
			M.show(iup, row.box, (item and open) and true or false, line)
		end
		if iup.Refresh then pcall(iup.Refresh, strip.widget) end
	end

	function act:flat_action()
		if strip.blocker and strip.blocker.action then strip.blocker.action() end
		return iup.DEFAULT
	end
	function more:flat_action()
		open = not open
		iup.SetAttribute(more, "TITLE", open and "Hide details" or "Details")
		refresh()
		return iup.DEFAULT
	end
	--- Replace the list of requirements.
	function strip.set(items, ready)
		current, ready_text = items, ready
		refresh()
	end
	return strip
end

--- A pane that says what it is for until it has something to show.
--
-- @tparam userdata iup
-- @tparam table opts `content` (the real widget), `icon`, `title`, `hint`, and `action`
--   (`{ title, run }`), the one thing to do next, as the page's primary button
-- @treturn ihandle the pane
-- @treturn function `set_empty(boolean)`
-- @treturn ihandle the hint label, for text that changes with state
function M.emptyPane(iup, opts)
	local glyph = iup.flatlabel({ TITLE = "", THEMEROLE = "well", ALIGNMENT = "ACENTER" })
	if opts.icon then M.bindIcon(iup, glyph, opts.icon, { size = M.ICON_EMPTY, role = "neutral" }) end
	local title = iup.flatlabel({ TITLE = opts.title or "", THEMEROLE = "empty_title", ALIGNMENT = "ACENTER" })
	local hint = iup.flatlabel({ TITLE = opts.hint or "", THEMEROLE = "empty_hint", ALIGNMENT = "ACENTER" })
	local kids = {
		iup.fill({}),
		iup.hbox({ iup.fill({}), glyph, iup.fill({}) }),
		iup.hbox({ iup.fill({}), title, iup.fill({}) }),
		iup.hbox({ iup.fill({}), hint, iup.fill({}) }),
	}
	if opts.action then
		kids[#kids + 1] = iup.fill({ RASTERSIZE = "x" .. L.px(3) })
		kids[#kids + 1] = iup.hbox({ iup.fill({}), M.button(iup, {
			title = opts.action.title, role = "primary_btn", icon = opts.action.icon,
			action = opts.action.run,
		}), iup.fill({}) })
	end
	kids[#kids + 1] = iup.fill({})
	kids.GAP, kids.EXPAND = L.gap(2), "YES"
	local placeholder = iup.flatframe({
		iup.vbox(kids),
		TITLE = "", THEMEROLE = "well", MARGIN = L.margin(5), EXPAND = "YES",
	})
	local pane = iup.zbox({ placeholder, opts.content, EXPAND = "YES" })
	local function set_empty(empty)
		iup.SetAttribute(pane, "VALUEPOS", empty and "0" or "1")
	end
	return pane, set_empty, hint
end

return M
