--- The left toolbar: an independent view of root tabs, never a group's child strip.
-- @classmod core.ui.ToolRail
local StripView = require("core.ui.TabStripView")
local winbatch = require("core.lib.winbatch")
local ToolRail = {}
ToolRail.__index = ToolRail
ToolRail.WIDE = 176
ToolRail.NARROW = 48
-- Titles show once the rail is this wide (extending: from about a third of the way).
ToolRail.TITLES_FROM = ToolRail.NARROW + 56
local SETTING = "tool_rail_collapsed"

--- What a row should say about its tab's background work. Running wins: it's still going,
-- and a failure that hasn't been seen waits for it.
-- @tparam table items `core.classes.Activity:list()`
-- @param tab the tab's id
-- @treturn string|nil `"running"`, `"failed"` or nil
function ToolRail.statusOf(items, tab)
	local status
	if tab == nil then return nil end
	for _, item in ipairs(items) do
		if item.tab == tab then
			if item.state == "running" then return "running" end
			if item.state == "failed" and not item.viewed then status = "failed" end
		end
	end
	return status
end

function ToolRail.new(opts)
	local iup = opts.iup
	local self = setmetatable({ _iup = iup, _root = opts.main, _settings = opts.settings,
		_icon = opts.icon, _is_settings = opts.is_settings, _motion = opts.motion,
		_on_width = opts.on_width, _anim = {} }, ToolRail)
	self._collapsed = not opts.settings or opts.settings:get(SETTING) ~= false
	self._strip = iup.flattabs({ TABTYPE = "LEFT", TABSBREADTH = tostring(ToolRail.NARROW),
		TABSHIDETITLE = "YES", TABSLETTERS = "YES", TABSALIGNMENT = "ALEFT:ACENTER",
		TABSTEXTELLIPSIS = "YES", EXPAND = "VERTICAL", CANFOCUS = "NO", THEMEROLE = "tool_rail" })
	self._view = StripView.new({ iup = iup, root = opts.main, strip = self._strip,
		is_hidden = function(page)
			return self._is_settings(page) or not self._groups or self._groups:toolbarOf(page) ~= "left"
		end })
	local rail = self
	function self._strip:extrabutton_cb(id, pressed)
		if pressed == 0 then
			if id == 1 and rail._groups then
				local name = rail._prompt and rail._prompt()
				if name then
					rail._groups:_batch(function()
						local group = rail._groups:createGroup(rail._root, name, "user")
						if group then rail._groups:setToolbar(group, "left") end
					end)
				end
			elseif id == 2 then rail:toggle() end
		end
		return iup.DEFAULT
	end
	self:_size()
	return self
end

function ToolRail:widget() return self._strip end
function ToolRail:connect(opts)
	self._groups, self._activity, self._prompt = opts.groups, opts.activity, opts.prompt
	self._view:setOrder(opts.order)
	if self._activity then self._activity:subscribe(function() self:showStatus() end) end
end

--- The width the rail is drawn at now (between the two while it moves).
function ToolRail:width()
	return self._width or (self._collapsed and ToolRail.NARROW or ToolRail.WIDE)
end

-- Lay the rail out at its current width times the bars' reveal: the workspace beside it
-- takes the rest, so it follows every frame of the motion.
function ToolRail:_apply()
	local iup, strip = self._iup, self._strip
	local full = self:width()
	local width = math.floor(full * (self._reveal or 1) + 0.5)
	iup.SetAttribute(strip, "FLOATING", width == 0 and "YES" or "NO")
	iup.SetAttribute(strip, "VISIBLE", width == 0 and "NO" or "YES")
	iup.SetAttribute(strip, "TABSBREADTH", tostring(math.max(1, width)))
	iup.SetAttribute(strip, "RASTERSIZE", width .. "x")
	iup.SetAttribute(strip, "MINSIZE", width .. "x1")
	iup.SetAttribute(strip, "MAXSIZE", width .. "x65535")
	iup.SetAttribute(strip, "TABSHIDETITLE", width < ToolRail.TITLES_FROM and "YES" or "NO")
	if self._on_width then
		local k = (full - ToolRail.NARROW) / (ToolRail.WIDE - ToolRail.NARROW)
		self._on_width(math.max(0, math.min(1, k)) * (self._reveal or 1))
	end
end

function ToolRail:_size()
	local iup, strip = self._iup, self._strip
	self:_apply()
	iup.SetAttribute(strip, "EXTRABUTTONS", "2")
	-- "+" right under the last rail entry; the collapse chevron stays at the foot
	iup.SetAttribute(strip, "EXTRAFOLLOW1", "YES")
	for id, name in ipairs({ "add", self._collapsed and "chevron--right" or "chevron--left" }) do
		local image = self._icon(name, 16)
		if image then iup.SetAttributeId(strip, "EXTRAIMAGE", id, image) end
	end
	iup.SetAttributeId(strip, "EXTRATIP", 1, "New sidebar group")
	iup.SetAttributeId(strip, "EXTRATIP", 2, self._collapsed and "Expand sidebar (Ctrl+B)" or "Collapse sidebar (Ctrl+B)")
end

--- Change occupied width without changing the remembered expand/collapse choice.
function ToolRail:setReveal(progress)
	self._reveal = progress
	self:_apply()
end

function ToolRail:refresh()
	if not self._groups then return end
	self._view:sync(self._groups:_children(self._root))
	self:showStatus()
end

function ToolRail:showStatus()
	if not (self._activity and self._groups) then return end
	local iup, strip = self._iup, self._strip
	local items, palette = self._activity:list(), require("core.ui.ThemeReactor").palette()
	local function status(page)
		if not self._groups:isGroupStrip(page) then
			return ToolRail.statusOf(items, iup.GetAttribute(page, "HOSTTABOWNERID"))
		end
		local result
		for _, child in ipairs(self._groups:_children(page)) do
			local value = status(child)
			if value == "running" then return value end
			result = result or value
		end
		return result
	end
	for i, page in ipairs(self._groups:_children(self._root)) do
		local value = status(page)
		iup.SetAttributeId(strip, "TABDOTCOLOR", i - 1,
			value == "running" and palette.accent or value == "failed" and palette.error or nil)
		local title = iup.GetAttributeId(strip, "TABTITLE", i - 1) or ""
		iup.SetAttributeId(strip, "TABTIP", i - 1, title .. (value and (": " .. value) or ""))
	end
	iup.Update(strip)
end

--- Extend or collapse. The rail moves between its widths with the shared motion (the
-- workspace, the sheet and the dock resize with it in the same frames; the background's
-- crescent follows through `on_width`); without motion it jumps.
function ToolRail:toggle()
	local from = self:width()
	self._collapsed = not self._collapsed
	if self._settings then
		self._settings:set(SETTING, self._collapsed)
		self._settings:save()
	end
	local to = self._collapsed and ToolRail.NARROW or ToolRail.WIDE
	local iup = self._iup
	local function frame(v)
		self._width = v
		winbatch.batch(iup, self._strip, function()
			self:_apply()
			iup.Refresh(self._strip)
		end)
	end
	self._width = from
	self:_size()
	self:refresh()
	if self._motion and from ~= to then
		self._motion:animate({ target = self._anim, from = from, to = to, distance = math.abs(to - from),
			curve = "standard", on_frame = frame,
			on_done = function() self._width = nil end })
	else
		self._width = nil
		frame(to)
		self._width = nil
	end
end

function ToolRail:themeChanged()
	self._view:themeChanged()
	self:_size()
end

function ToolRail:jump(n)
	if not self._groups then return false end
	for _, page in ipairs(self._groups:_children(self._root)) do
		if not self._is_settings(page) and self._groups:toolbarOf(page) == "left" then
			n = n - 1
			if n == 0 then
				self._groups:setActiveRoot(self._root)
				return self._groups:reveal(page)
			end
		end
	end
	return false
end

return ToolRail
