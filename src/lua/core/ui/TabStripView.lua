--- A toolbar view of the main tab tree. Empty pages preserve root positions, while
-- TABVISIBLE partitions top and left tabs without moving their actual content.
-- @module core.ui.TabStripView
local View = {}
View.__index = View

function View.new(opts)
	local self = setmetatable({ _iup = opts.iup, _root = opts.root, _hidden = opts.is_hidden,
		_pages = {}, _count = 0, _strip = opts.strip }, View)
	local iup, root, strip = opts.iup, opts.root, opts.strip
	local function forward(name, ...)
		local fn = root[name]
		if not fn then return iup.DEFAULT end
		if self._order then return self._order:fromView(strip, fn, root, ...) end
		return fn(root, ...)
	end
	local view = self
	function strip:flat_button_cb(button, pressed, x, y, status)
		local result = forward("flat_button_cb", button, pressed, x, y, status)
		if result ~= iup.IGNORE and view._away and button == iup.BUTTON1 and pressed == 0 then
			local pos = tonumber(iup.ConvertXYToPos(strip, x, y))
			if pos and pos >= 0 and tostring(pos) == iup.GetAttribute(strip, "VALUEPOS") then view:select(pos) end
		end
		return result
	end
	function strip:flat_motion_cb(x, y, status) return forward("flat_motion_cb", x, y, status) end
	function strip:rightclick_cb(pos) return forward("rightclick_cb", pos) end
	function strip:tabchange_cb()
		if not view._syncing then view:select(tonumber(iup.GetAttribute(strip, "VALUEPOS"))) end
		return iup.DEFAULT
	end
	return self
end

function View:setOrder(order) self._order = order end

function View:select(pos)
	if not pos then return end
	local iup, root = self._iup, self._root
	local old = iup.GetChild(root, tonumber(iup.GetAttribute(root, "VALUEPOS")) or 0)
	iup.SetAttribute(root, "VALUEPOS", tostring(pos))
	if root.tabchange_cb then root.tabchange_cb(root, iup.GetChild(root, pos), old) end
end

function View:themeChanged() self._away = nil end

function View:sync(pages)
	local iup, strip = self._iup, self._strip
	self._syncing = true
	while self._count < #pages do
		local page = iup.vbox({ iup.fill({}), EXPAND = "YES" })
		iup.Append(strip, page)
		if iup.GetAttribute(strip, "WID") then iup.Map(page) end
		self._pages[#self._pages + 1], self._count = page, self._count + 1
	end
	while self._count > #pages do
		iup.Destroy(table.remove(self._pages))
		self._count = self._count - 1
	end
	local active = tonumber(iup.GetAttribute(self._root, "VALUEPOS")) or 0
	local away, visible, changed = true, {}, false
	if self._away == nil then self._selected = iup.GetAttribute(strip, "TABSSELCOLOR") end
	for i, page in ipairs(pages) do
		local pos = i - 1
		local show = not (self._hidden and self._hidden(page))
		visible[i] = show
		local title = iup.GetAttributeId(self._root, "TABTITLE", pos) or ""
		local image = iup.GetAttributeId(self._root, "TABIMAGE", pos)
		for key, value in pairs({ TABTITLE = title, TABVISIBLE = show and "YES" or "NO", TABTIP = title }) do
			if iup.GetAttributeId(strip, key, pos) ~= value then
				iup.SetAttributeId(strip, key, pos, value)
				changed = true
			end
		end
		iup.SetAttributeId(strip, "TABIMAGE", pos, image)
		if show and pos == active then away = false end
	end
	if not away and tostring(active) ~= iup.GetAttribute(strip, "VALUEPOS") then
		iup.SetAttribute(strip, "VALUEPOS", tostring(active))
	end
	if away ~= self._away then
		self._away = away
		local p = require("core.ui.ThemeReactor").palette()
		iup.SetAttribute(strip, "TABSACTIVELINE", not away and p.accent or nil)
		iup.SetAttribute(strip, "TABSSELCOLOR", away and iup.GetAttribute(strip, "TABSBACKCOLOR") or self._selected)
		iup.SetAttribute(strip, "FORECOLOR", away and p.textMuted or p.text)
	end
	self._syncing = false
	iup.Update(strip)
	return visible, changed
end

return View
