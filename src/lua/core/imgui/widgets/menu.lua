-- Themed menu items and menu-bar drawing for the virtual IUP tree.
-- @module core.imgui.widgets.menu
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")
local Fonts = require("core.imgui.Fonts")
local iup = require("core.imgui.iup")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local yes = Element.isTrue -- iupStrBoolean
local function children(e) return Element.children(e) end
local function title_parts(value)
	local s = tostring(value or "")
	local label, accel = s:match("^(.-)\t(.*)$")
	label = label or s
	local mnemonic
	label = label:gsub("&&", "\1"):gsub("&(.)", function(c) mnemonic = mnemonic or c:lower(); return c end):gsub("\1", "&")
	return label, accel, mnemonic
end
local function item_height(e)
	return math.max(24, Fonts.forElement(e):charsize())
end
local function menu_size(menu)
	local f = Fonts.forElement(menu); local w, h = 36, 8
	for _, item in ipairs(children(menu)) do
		if attr(item, "SEPARATOR") == "YES" or Element.state(item).classname == "separator" then h = h + 8
		else
			local label, accel = title_parts(attr(item, "TITLE"))
			w = math.max(w, f:measure(label) + (accel and f:measure(accel) or 0) + 52)
			h = h + item_height(item)
		end
	end
	return w, h
end
local function close_chain(state)
	local o = state and state.overlay
	if o and o.close then o:close() end
	if state and state.parent then close_chain(state.parent) end
end
local function activate(item, state)
	close_chain(state)
	local result = Element.call(item, "ACTION")
	if result == iup.CLOSE then state.result = result end
end
local function menu_draw(menu, state, dc)
	local w, h = state.w, state.h
	local bg = attr(menu, "BGCOLOR") or "38 40 46"
	local fg = attr(menu, "FGCOLOR") or "230 230 235"
	dc:fill(state.x, state.y, w, h, bg, { radius = tonumber(attr(menu, "CORNERRADIUS")) or 4 })
	local y = state.y + 4
	for i, item in ipairs(children(menu)) do
		local ist = Element.state(item)
		if ist.classname == "separator" or yes(attr(item, "SEPARATOR")) then
			dc:line(state.x + 8, y + 3, state.x + w - 8, y + 3, attr(item, "COLOR") or "90 92 100", 1)
			y = y + 8
		else
			local ih = item_height(item); local active = attr(item, "ACTIVE") ~= "NO"; local selected = state.selected == i
			if selected and active then
				dc:fill(state.x + 3, y, w - 6, ih, attr(menu, "HLCOLOR") or "65 70 82", { radius = 3 })
				dc:fill(state.x + 5, y + 5, 2, math.max(1, ih - 10),
					attr(menu, "ITEMMARKERCOLOR") or attr(menu, "TXTHLCOLOR") or "0 180 150")
			end
			local label, accel = title_parts(attr(item, "TITLE"))
			local mark = yes(attr(item, "VALUE")) and "✓" or ""
			local font = Fonts.forElement(item)
			dc:text(mark, state.x + 10, y, 18, ih, fg, font, { valign = "center" })
			dc:text(label, state.x + 32, y, w - 76, ih, active and (attr(item, "FGCOLOR") or fg) or "120 122 128", font, { valign = "center", ellipsis = true })
			if accel then dc:text(accel, state.x + w - 42 - font:measure(accel), y, font:measure(accel), ih, "160 162 170", font, { valign = "center", align = "right" }) end
			if Element.state(item).classname == "submenu" then dc:text("›", state.x + w - 22, y, 16, ih, fg, font, { valign = "center", align = "right" }) end
			y = y + ih
		end
	end
end
local function menu_item_at(menu, state, ly)
	local y = 4
	for i, item in ipairs(children(menu)) do
		if Element.state(item).classname == "separator" or yes(attr(item, "SEPARATOR")) then y = y + 8
		else
			local h = item_height(item)
			if ly >= y and ly < y + h then return i end
			y = y + h
		end
	end
end
local function open_submenu(item, parent_state, rt)
	if Element.state(item).classname ~= "submenu" then return end
	local sub = children(item)[1]
	if not sub then return end
	local w, h = menu_size(sub)
	local x, y = parent_state.x + parent_state.w - 3, parent_state.y + parent_state.item_y
	local state = { x = x, y = y, w = w, h = h, parent = parent_state, menu = sub, selected = 0 }
	state.overlay = rt.overlay{
		owner = sub, x = x, y = y, w = w, h = h,
		draw = function(dc) menu_draw(sub, state, dc) end,
		event = function(ev)
			local lx, ly = (ev.x or 0) - state.x, (ev.y or 0) - state.y
			if ev.type == "move" or ev.type == "enter" then state.selected = menu_item_at(sub, state, ly); return true end
			if ev.type == "press" and ev.button == 1 then
				local n = menu_item_at(sub, state, ly); local child = n and children(sub)[n]
				if child and attr(child, "ACTIVE") ~= "NO" then
					if Element.state(child).classname == "submenu" then open_submenu(child, state, rt) else activate(child, state) end
				end
				return true
			end
			if ev.type == "key" and iup.XkeyBase(ev.key or 0) == iup.K_LEFT then close_chain(state); return true end
			return false
		end,
		closed = function() state.overlay = nil end,
	}
	return state
end

function M.popupMenu(menu, x, y, rt)
	local w, h = menu_size(menu); local state = { x = x or 0, y = y or 0, w = w, h = h, menu = menu, selected = 0 }
	Element.call(menu, "OPEN_CB")
	state.overlay = rt.overlay{
		owner = menu, x = state.x, y = state.y, w = w, h = h, modal = true,
		draw = function(dc) menu_draw(menu, state, dc) end,
		event = function(ev)
			local lx, ly = (ev.x or 0) - state.x, (ev.y or 0) - state.y
			if ev.type == "move" or ev.type == "enter" then
				local n = menu_item_at(menu, state, ly)
				if n ~= state.selected then
					state.selected = n or 0
					if n then Element.call(children(menu)[n], "HIGHLIGHT_CB") end
				end
				local child = n and children(menu)[n]
				if child and Element.state(child).classname == "submenu" then state.item_y = ly; open_submenu(child, state, rt) end
				return true
			elseif ev.type == "press" and ev.button == 1 then
				local n = menu_item_at(menu, state, ly); local item = n and children(menu)[n]
				if item and attr(item, "ACTIVE") ~= "NO" then
					if Element.state(item).classname == "submenu" then state.item_y = ly; open_submenu(item, state, rt) else activate(item, state) end
				end
				return true
			elseif ev.type == "key" then
				local base = iup.XkeyBase(ev.key or 0)
				if base == iup.K_ESCAPE then close_chain(state); return true end
				if base == iup.K_DOWN or base == iup.K_UP then
					local count = #children(menu)
					if count == 0 then return true end
					local n = state.selected
					for _ = 1, count do
						n = base == iup.K_DOWN and n + 1 or n - 1
						if n > count then n = 1 elseif n < 1 then n = count end
						if Element.state(children(menu)[n]).classname ~= "separator" then
							state.selected = n
							break
						end
					end
					return true
				elseif base == iup.K_RIGHT and state.selected > 0 then open_submenu(children(menu)[state.selected], state, rt); return true
				elseif base == iup.K_CR and state.selected > 0 then local item = children(menu)[state.selected]; if Element.state(item).classname ~= "submenu" then activate(item, state) end; return true end
			end
			return false
		end,
		closed = function() Element.call(menu, "MENUCLOSE_CB") end,
	}
	if rt.runNestedLoop then rt.runNestedLoop(function() return state.overlay == nil end) end
	return state.result
end

function M.menubarHeight(menu, font)
	return (font or Fonts.forElement(menu)):charsize() + 8
end
function M.drawMenubar(menu, dc, x, y, w, rt)
	local h = M.menubarHeight(menu); dc:fill(x, y, w, h, attr(menu, "BGCOLOR") or "38 40 46")
	local cursor = x + 8; local f = Fonts.forElement(menu)
	for i, item in ipairs(children(menu)) do
		local label = title_parts(attr(item, "TITLE")); local iw = f:measure(label) + 18
		dc:text(label, cursor + 9, y, iw - 18, h, attr(item, "FGCOLOR") or "230 230 235", f, { valign = "center" }); cursor = cursor + iw
	end
end
function M.menubarEvent(menu, ev, rt)
	if ev.type ~= "press" or ev.button ~= 1 then return false end
	local x, cursor = ev.x or 0, 8
	for _, item in ipairs(children(menu)) do local label = title_parts(attr(item, "TITLE")); local iw = Fonts.forElement(menu):measure(label) + 18; if x >= cursor and x < cursor + iw then return M.popupMenu(children(item)[1] or item, cursor, ev.y or 0, rt) ~= nil end; cursor = cursor + iw end
	return false
end

Classes.define{ name = "menu", children = -1, defaults = { BGCOLOR = "38 40 46", FGCOLOR = "230 230 235", HLCOLOR = "65 70 82" }, callbacks = { OPEN_CB = true, MENUCLOSE_CB = true } }
Classes.define{ name = "item", children = 0, defaults = { ACTIVE = "YES", VALUE = "OFF" }, callbacks = { ACTION = true, HIGHLIGHT_CB = true } }
Classes.define{ name = "submenu", children = 1, defaults = { ACTIVE = "YES" }, callbacks = { HIGHLIGHT_CB = true } }
Classes.define{ name = "separator", children = 0, defaults = { SEPARATOR = "YES" } }
return M
