--- The tool rail: a group's tools down the left of its pane instead of along the top.
--
-- A rail is an ordinary strip with its tabs on the left, so selecting, overflow, dragging
-- and the context menu are the strip's own. There is one per pane: the open group's strip
-- in the main pane (whose groups live in the top bar), and the root strip of any other pane.
-- A group inside a group keeps a horizontal strip in its page, so no pane ever grows a
-- second rail.
--
-- Every rail is the same width, so moving between groups never moves the page. Narrow shows
-- the same rows without their labels: the icons stay put because the left padding centres
-- them in the narrow width.
--
-- @classmod core.ui.ToolRail

local ToolRail = {}
ToolRail.__index = ToolRail

ToolRail.WIDE = 176
ToolRail.NARROW = 48
--- A pane narrower than this gets the narrow rail, whatever the saved choice.
ToolRail.FULL_FROM = 1280

-- The buttons at the foot of a rail, numbered from the bottom as the strip stacks them.
local ADD, FOCUS, COLLAPSE = 1, 2, 3
local SETTING = "tool_rail_collapsed"

--- Which width a rail takes. Pure, so it's testable without a window.
-- @tparam boolean collapsed the user's choice
-- @tparam number pane_width
-- @treturn boolean narrow
function ToolRail.isNarrow(collapsed, pane_width)
	return collapsed == true or (pane_width or 0) < ToolRail.FULL_FROM
end

--- @tparam table opts
-- @tparam userdata opts.iup
-- @tparam table opts.groups `core.classes.TabGroups`
-- @tparam table opts.panes `core.classes.PaneGrid`
-- @tparam userdata opts.main the main strip
-- @tparam[opt] table opts.settings `core.classes.SettingsManager`
-- @tparam function opts.icon `(name, size) -> image handle` in the theme's colours
-- @tparam[opt] function opts.notify themes a widget tree
function ToolRail.new(opts)
	local self = setmetatable({
		_iup = opts.iup, _groups = opts.groups, _panes = opts.panes, _main = opts.main,
		_settings = opts.settings, _icon = opts.icon, _notify = opts.notify,
		_state = {},
	}, ToolRail)
	self._collapsed = opts.settings and opts.settings:get(SETTING) == true or false
	return self
end

--- Is this strip a rail? Depends only on where it sits in the tree.
function ToolRail:owns(strip)
	local iup, groups = self._iup, self._groups
	if groups:_isRoot(strip) then
		return not require("core.lib.handle").same(iup, strip, self._main)
	end
	return groups:isGroupStrip(strip) and groups:depthOf(strip) == 1
end

-- Every strip that should be a rail, and every one that was and has stopped.
function ToolRail:_strips()
	local rails, others = {}, {}
	for _, strip in ipairs(self._groups:stripsDeepestFirst()) do
		if self:owns(strip) then
			rails[#rails + 1] = strip
		elseif not self._groups:_isRoot(strip) then
			others[#others + 1] = strip
		end
	end
	return rails, others
end

local function width_of(iup, strip)
	return tonumber(tostring(iup.GetAttribute(strip, "RASTERSIZE") or ""):match("^(%d+)x"))
end

-- The width a pane has, measured on the pane's root: a rail in a hidden tab reports nothing.
function ToolRail:_paneWidth(strip)
	return width_of(self._iup, self._groups:rootOf(strip) or strip) or 0
end

function ToolRail:_decorate(strip, narrow)
	local iup = self._iup
	local tip = narrow and "Expand sidebar (Ctrl+B)" or "Collapse sidebar (Ctrl+B)"
	iup.SetAttributeId(strip, "EXTRATIP", ADD, "New tab group")
	iup.SetAttributeId(strip, "EXTRATIP", FOCUS, "Focus or restore pane (Esc to restore)")
	iup.SetAttributeId(strip, "EXTRATIP", COLLAPSE, tip)
	for id = ADD, COLLAPSE do iup.SetAttributeId(strip, "EXTRAALIGNMENT", id, "ALEFT:ACENTER") end
	local icons = { [ADD] = "add", [FOCUS] = "view", [COLLAPSE] = narrow and "chevron--right" or "chevron--left" }
	for id, name in pairs(icons) do
		local image = self._icon(name, 16)
		if image then iup.SetAttributeId(strip, "EXTRAIMAGE", id, image) end
	end
	-- Every row needs an icon: the narrow rail has nothing else to show. An extension's tab
	-- may not have one, and a group in a group never does.
	for i, page in ipairs(self._groups:_children(strip)) do
		local pos = i - 1
		local title = iup.GetAttributeId(strip, "TABTITLE", pos) or ""
		iup.SetAttributeId(strip, "TABTIP", pos, title)
		if not iup.GetAttributeId(strip, "TABIMAGE", pos) then
			local image = self._icon(self._groups:isGroupStrip(page) and "folder" or "task", 16)
			if image then iup.SetAttributeId(strip, "TABIMAGE", pos, image) end
		end
	end
end

--- Bring every strip in line with its place in the tree and the pane's width.
-- @treturn boolean anything changed, so the caller needs a layout pass
function ToolRail:apply()
	local iup, changed = self._iup, false
	local rails, others = self:_strips()
	local split = self._panes:isSplit()
	local active_root = self._groups:activeRoot()
	local handle = require("core.lib.handle")
	local accent = require("core.ui.ThemeReactor").palette().accent

	for _, strip in ipairs(rails) do
		local id = handle.id(iup, strip)
		local narrow = ToolRail.isNarrow(self._collapsed, self:_paneWidth(strip))
		local shape = table.concat({ narrow and "n" or "w", #self._groups:_children(strip), self._generation or 0 }, "|")
		if self._state[id] ~= shape then
			local first = self._state[id] == nil
			self._state[id] = shape
			changed = true
			iup.SetAttribute(strip, "SHOWTABS", "YES")
			iup.SetAttribute(strip, "TABTYPE", "LEFT")
			iup.SetAttribute(strip, "TABSBREADTH", tostring(narrow and ToolRail.NARROW or ToolRail.WIDE))
			iup.SetAttribute(strip, "TABSHIDETITLE", narrow and "YES" or "NO")
			iup.SetAttribute(strip, "TABSTEXTELLIPSIS", "YES")
			iup.SetAttribute(strip, "TABSALIGNMENT", "ALEFT:ACENTER")
			iup.SetAttribute(strip, "EXTRABUTTONS", tostring(COLLAPSE))
			self:_decorate(strip, narrow)
			if first then
				iup.SetAttribute(strip, "THEMEROLE", "tool_rail")
				if self._notify then self._notify(strip) end
			end
		end
		iup.SetAttributeId(strip, "EXTRAACTIVE", FOCUS, split and "YES" or "NO")
		-- With panes open, only the rail being worked in carries the accent.
		local here = not split or handle.same(iup, self._groups:rootOf(strip), active_root)
		iup.SetAttribute(strip, "TABSACTIVELINE", here and accent or nil)
	end

	for _, strip in ipairs(others) do
		local id = handle.id(iup, strip)
		if self._state[id] then
			self._state[id] = nil
			changed = true
			iup.SetAttribute(strip, "TABTYPE", "TOP")
			iup.SetAttribute(strip, "TABSBREADTH", nil)
			iup.SetAttribute(strip, "TABSHIDETITLE", nil)
			iup.SetAttribute(strip, "THEMEROLE", "flattabs_sub")
			self._groups:_prepareStrip(strip)
			if self._notify then self._notify(strip) end
		end
	end
	return changed
end

--- What a button at the foot of a rail does.
-- @treturn boolean it was one of this rail's
function ToolRail:press(strip, id)
	if id == ADD then
		self._groups:_newGroup(self._groups:rootOf(strip))
	elseif id == FOCUS then
		self._panes:toggleFocus(strip)
	elseif id == COLLAPSE then
		self:toggle()
	else
		return false
	end
	return true
end

--- Collapse or expand every rail, and remember it. A thin pane stays narrow either way.
function ToolRail:toggle()
	self._collapsed = not self._collapsed
	if self._settings then
		self._settings:set(SETTING, self._collapsed)
		self._settings:save()
	end
	self:refresh()
end

--- Apply, and lay out if that changed anything.
function ToolRail:refresh()
	if self:apply() then pcall(self._iup.Refresh, self._panes:widget()) end
end

--- A theme pass has repainted the icons and reset the accent.
function ToolRail:themeChanged()
	self._generation = (self._generation or 0) + 1
end

--- The strip of the pane being worked in: where a number key goes.
function ToolRail:activeStrip()
	local iup, groups = self._iup, self._groups
	local root = groups:activeRoot()
	if self:owns(root) then return root end
	local page = iup.GetAttribute(root, "VALUE_HANDLE")
	if page and groups:isGroupStrip(page) and self:owns(page) then return page end
	return nil
end

--- Show the `n`th tool of the rail being worked in.
-- @treturn boolean there was one
function ToolRail:jump(n)
	local strip = self:activeStrip()
	local page = strip and self._groups:_children(strip)[n]
	if not page then return false end
	return self._groups:reveal(page)
end

return ToolRail
