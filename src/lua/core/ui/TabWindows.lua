-- Real, modeless windows for live extension pages. Reparenting preserves editors,
-- controls, owners and running tasks; closing a window docks its pages again.
local tree = require("core.lib.tree")
local handle = require("core.lib.handle")
local Windows = {}
Windows.__index = Windows

function Windows.new(opts)
	local self = setmetatable({ iup = opts.iup, groups = opts.groups, main = opts.dialog,
		theme = opts.theme, on_activate = opts.on_activate, windows = {}, busy = false }, Windows)
	self.groups._floating = self.windows
	self.last_main_root = self.groups:activeRoot()
	local focus = self.main.focus_cb
	self.main.focus_cb = function(d, active)
		if focus then focus(d, active) end
		if active == 1 then self:activate() end
	end
	return self
end

function Windows:activate(root)
	local previous = self.groups:activeRoot()
	if not self:windowOf(previous) then self.last_main_root = previous end
	root = root or (self.groups:rootOf(self.last_main_root) and self.last_main_root) or self.groups:rootStrip()
	self.groups:setActiveRoot(root)
	if self.on_activate then self.on_activate() end
end

function Windows:windowOf(widget)
	local root = self.groups:rootOf(widget)
	for _, window in ipairs(self.windows) do
		if handle.same(self.iup, window.root, root) then return window end
	end
end

function Windows:open(widget)
	local iup, groups = self.iup, self.groups
	local existing = self:windowOf(widget)
	if existing and handle.same(iup, iup.GetParent(widget), existing.root) then
		iup.Show(existing.dialog); return existing
	end
	local parent = groups:stripOf(widget)
	if not parent then return nil end
	local index = (tree.indexOf(iup, parent, widget) or 0) + 1
	for n, child in ipairs(groups:savedChildren(parent)) do
		if handle.same(iup, child, widget) then index = n; break end
	end
	if existing and handle.same(iup, parent, existing.root) then parent, index = existing.parent, existing.index end
	local title = groups:_titleOf(widget) or "Extension"
	local root = iup.flattabs{ EXPAND = "YES" }
	local dock = iup.flatbutton{ TITLE = "Return to main window", CANFOCUS = "YES", PADDING = "12x6" }
	local dialog = iup.dialog{ iup.vbox{ iup.hbox{ dock, iup.fill{}, MARGIN = "8x6" }, root, EXPAND = "YES" },
		TITLE = title .. " — Lunar", RASTERSIZE = "960x640", MINSIZE = "500x360", SHRINK = "YES",
		TASKBARBUTTON = "YES", PARENTDIALOG = self.main }
	local window = { root = root, dialog = dialog, parent = parent, index = index, title = title }
	iup.Map(dialog) -- both trees mapped before reparenting: preserve native editor state
	self.busy = true
	groups:_batch(function()
		self.windows[#self.windows + 1] = window
		groups:_prepareStrip(root)
		local change = root.tabchange_cb
		root.tabchange_cb = function(s, new_tab, old_tab)
			if change then change(s, new_tab, old_tab) end
			self:activate(root)
			return iup.DEFAULT
		end
		tree.place(iup, root, widget)
		groups:_syncTitles(parent); groups:_syncTitles(root)
		groups:_requestRefresh(); groups:_changed()
	end)
	self.busy = false
	local self_windows = self
	local function close()
		-- Leave native close/button callbacks before reparenting and destroying
		-- their control trees, as with deferred tab drops.
		if window.closing then return iup.IGNORE end
		window.closing = true
		self_windows:later(function() self_windows:restore(window) end)
		return iup.IGNORE
	end
	-- Capture the controller separately from IUP's callback receiver.
	dialog.close_cb = close
	dialog.focus_cb = function(_, active) if active == 1 then self_windows:activate(root) end end
	dock.flat_action = close
	if self.theme then self.theme(dialog) end
	iup.ShowXY(dialog, iup.CENTERPARENT, iup.CENTERPARENT)
	groups:reveal(widget)
	self:activate(root)
	return window
end

function Windows:later(fn)
	local iup = self.iup
	local timer = iup.timer{ time = 1 }
	function timer:action_cb()
		self.run = "NO"; iup.Destroy(self); fn()
		return iup.DEFAULT
	end
	timer.run = "YES"
end

function Windows:openLater(widget) self:later(function() self:open(widget) end) end

function Windows:restore(window)
	local found
	for n, w in ipairs(self.windows) do if w == window then found = n; break end end
	if not found then return false end
	local iup, groups = self.iup, self.groups
	local parent = window.parent
	local ok, valid = pcall(iup.GetClassName, parent)
	if not ok or not valid or not groups:rootOf(parent) then parent = groups:rootStrip() end
	local children = groups:_children(window.root)
	self.busy = true
	groups:_batch(function()
		local ref, passed = nil, false
		for _, child in ipairs(groups:savedChildren(parent)) do
			if handle.same(iup, iup.GetParent(child), window.root) then passed = true
			elseif passed and handle.same(iup, iup.GetParent(child), parent) then ref = child; break end
		end
		for _, child in ipairs(children) do tree.place(iup, parent, child, ref) end
		table.remove(self.windows, found)
		if handle.same(iup, groups:activeRoot(), window.root) then groups:setActiveRoot(groups:rootStrip()) end
		groups:_syncTitles(parent)
		if children[1] then groups:reveal(children[1]) end
		groups:_requestRefresh(); groups:_changed()
	end)
	iup.Hide(window.dialog)
	iup.Destroy(window.dialog)
	self.busy = false
	return true
end

function Windows:restoreAll()
	while #self.windows > 0 do self:restore(self.windows[#self.windows]) end
end

function Windows:sync()
	if self.busy then return end
	for n = #self.windows, 1, -1 do
		local window = self.windows[n]
		if #self.groups:_children(window.root) == 0 then self:restore(window) end
	end
end

return Windows
