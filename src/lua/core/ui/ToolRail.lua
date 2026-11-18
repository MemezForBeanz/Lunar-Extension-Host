--- The left toolbar: an independent view of root tabs, never a group's child strip.
-- @classmod core.ui.ToolRail
local StripView = require("core.ui.TabStripView")
local ToolRail = {}
ToolRail.__index = ToolRail
ToolRail.WIDE = 176
ToolRail.NARROW = 48
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
		_icon = opts.icon, _is_settings = opts.is_settings }, ToolRail)
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

function ToolRail:_size()
	local iup, strip = self._iup, self._strip
	local width = self._collapsed and ToolRail.NARROW or ToolRail.WIDE
	iup.SetAttribute(strip, "TABSBREADTH", tostring(width))
	iup.SetAttribute(strip, "RASTERSIZE", width .. "x")
	iup.SetAttribute(strip, "MINSIZE", width .. "x1")
	iup.SetAttribute(strip, "MAXSIZE", width .. "x65535")
	iup.SetAttribute(strip, "TABSHIDETITLE", self._collapsed and "YES" or "NO")
	iup.SetAttribute(strip, "EXTRABUTTONS", "2")
	-- "+" right under the last rail entry; the collapse chevron stays at the foot
	iup.SetAttribute(strip, "EXTRAFOLLOW1", "YES")
	for id, name in ipairs({ "add", self._collapsed and "chevron--right" or "chevron--left" }) do
		local image = self._icon(name, 16)
		if image then iup.SetAttributeId(strip, "EXTRAIMAGE", id, image) end
	end
	iup.SetAttributeId(strip, "EXTRATIP", 1, "New sidebar group")
	iup.SetAttributeId(strip, "EXTRATIP", 2, self._collapsed and "Expand sidebar (Ctrl+B)" or "Collapse sidebar (Ctrl+B)")
	if self._reveal then self:setReveal(self._reveal) end
end

--- Change occupied width without changing the remembered expand/collapse choice.
function ToolRail:setReveal(progress)
	self._reveal = progress
	local width = math.floor((self._collapsed and ToolRail.NARROW or ToolRail.WIDE) * progress + 0.5)
	local iup, strip = self._iup, self._strip
	iup.SetAttribute(strip, "FLOATING", width == 0 and "YES" or "NO")
	iup.SetAttribute(strip, "VISIBLE", width == 0 and "NO" or "YES")
	iup.SetAttribute(strip, "RASTERSIZE", width .. "x")
	iup.SetAttribute(strip, "MINSIZE", width .. "x1")
	iup.SetAttribute(strip, "MAXSIZE", width .. "x65535")
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

function ToolRail:toggle()
	self._collapsed = not self._collapsed
	if self._settings then
		self._settings:set(SETTING, self._collapsed)
		self._settings:save()
	end
	self:_size()
	self:refresh()
	self._iup.Refresh(self._strip)
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
