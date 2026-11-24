--- The frame loop of the ImGui host.
--
-- Everything IUP's driver did between the OS and the widget tree happens here, once
-- per frame: read input from the backend, find what is under the mouse, fire the
-- callbacks IUP would have fired (enter/leave, buttons, motion, wheel, K_ANY, focus),
-- run due timers, lay out what changed, and paint every visible dialog and overlay.
--
-- Loops nest like IUP's: `iup.Popup` runs frames until its dialog hides, `iup.MainLoop`
-- until `iup.ExitLoop`, a callback returning `iup.CLOSE`, or the last dialog closing.
-- An idle host blocks in `backend.wait` until input or the next timer is due.
--
-- @module core.imgui.Runtime
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")
local Fonts = require("core.imgui.Fonts")
local Draw = require("core.imgui.Draw")

local M = {}

local STATE = Element.STATE
local DEFAULT, IGNORE, CLOSE, CONTINUE = -2, -1, -3, -4

-- Runtime state ------------------------------------------------------------------------
local B            -- backend
local dc           -- draw context
local Layout       -- core.imgui.Layout (loaded on init)
local iup          -- core.imgui.iup

local dialogs = {}        -- shown dialogs, bottom to top
local main_dialog = nil   -- the dialog that owns the OS window
local active_dialog = nil
local timers = {}         -- running timer elements -> true
local overlays = {}       -- rt.overlay handles, bottom to top
local overlay_windows, tip_overlay
-- Scrim patches over native video (one per video rectangle on the main window while a modal
-- is up): the video child sits above the main surface, so the dim drawn there misses it.
-- IUP's scrim was a layered window over everything; these are click-through overlay windows
-- stacked directly under the modal's own window.
local scrim_windows, scrim_used = {}, 0
local scrim_over_video
local video_rects = {}
local hovered, captured, focused = nil, nil, nil
-- The overlay (menu, dropdown list) under the pointer: its glass rim lifts.
local hover_overlay = nil
local loop_level = 0
local exit_levels = {}
local need_frame = true
local animating = false
local cursor_override = nil
local hover_since, tip_el, tip_shown = 0, nil, false
local last_mouse = { -1, -1 }
local last_inside = false
local frame_input = nil
local in_layout = false
local in_paint = false
local closed = false
-- The app was asked to end (SIGTERM, SIGINT, the session). Sticky: a quit during a startup
-- popup must also end the main loop that starts after it.
local quitting = false
local log = nil

M.globals = Element.globals
M.TIP_DELAY = 0.5

local globals = Element.globals
Color.globals = globals

local function default_globals()
	globals.DLGBGCOLOR = globals.DLGBGCOLOR or "240 240 240"
	globals.DLGFGCOLOR = globals.DLGFGCOLOR or "0 0 0"
	globals.TXTBGCOLOR = globals.TXTBGCOLOR or "255 255 255"
	globals.TXTFGCOLOR = globals.TXTFGCOLOR or "0 0 0"
	globals.TXTHLCOLOR = globals.TXTHLCOLOR or "0 120 215"
	globals.MENUBGCOLOR = globals.MENUBGCOLOR or "240 240 240"
	globals.LINKFGCOLOR = globals.LINKFGCOLOR or "0 102 204"
	globals.DEFAULTFONT = globals.DEFAULTFONT or "Segoe UI, 9"
	globals.UTF8MODE = "YES"
	globals.DRIVER = "ImGui"
	globals.SYSTEM = globals.SYSTEM or "Win11"
	globals.VERSION = "3.32"
end
default_globals()

-- Logging -------------------------------------------------------------------------------
local function warn(msg)
	if not log then
		local ok, l = pcall(require, "core.lib.log")
		log = ok and l or false
	end
	if log and log.warn then pcall(log.warn, "imgui", msg) else io.stderr:write("[imgui] ", tostring(msg), "\n") end
end
M.warn = warn
local function info(msg)
	local ok, l = pcall(require, "core.lib.log")
	local logger = ok and type(l) == "table" and l.get and l.get("imgui")
	if logger then pcall(logger.info, logger, msg) end
end

Element.hooks.error = function(el, name, err)
	warn(string.format("%s %s failed: %s", tostring(el), name, tostring(err)))
end

-- Invalidation --------------------------------------------------------------------------
local function dialog_of(el)
	local e = el
	while e do
		local st = STATE[e]
		if not st then return nil end
		if st.classname == "dialog" then return e, st end
		e = st.parent
	end
	return nil
end

-- Paint generations: what IUP would repaint. An element's visual attribute set or an
-- IupUpdate/IupRedraw on it stamps it with a new generation; a canvas whose recorded
-- ACTION is older than its own or any ancestor's stamp paints again (widgets/canvas.lua).
local paint_gen, frame_no = 0, 0
local function stamp(el)
	paint_gen = paint_gen + 1
	local st = el and STATE[el]
	if st then st.data.paint_gen = paint_gen end
end
--- The newest stamp on el and its ancestors.
function M.paintGen(el)
	local g, e = 0, el
	while e do
		local st = STATE[e]
		if not st then break end
		local s = st.data.paint_gen
		if s and s > g then g = s end
		e = st.parent
	end
	return g
end
function M.paintGenNow() return paint_gen end
function M.frameNo() return frame_no end

Element.hooks.invalidate = function(el, kind, name, changed, layout_invalidated)
	if kind ~= "layout" then
		-- IUP repaints for a visual attribute, not for the canvas draw state (DRAWCOLOR,
		-- DRAWSTYLE... set inside a paint callback) or internal storage.
		if type(name) == "string" and (name:sub(1, 4) == "DRAW" or name:sub(1, 4) == "_IUP") then return end
	end
	-- A later canvas may change an earlier canvas or its ancestor during ACTION.
	-- Stamp that change for the next frame, but repeated writes of the same stored
	-- value while drawing must not keep the event loop awake indefinitely.
	if changed == false then return end
	if not layout_invalidated and Element.invalidateLayout then
		Element.invalidateLayout(el, name == "FONT" or name == "EXPAND" or name == "CHILD")
	end
	stamp(el)
	need_frame = true
	if kind ~= "layout" or in_layout then return end
	local _, dst = dialog_of(el)
	if dst then dst.data.layout_dirty = true end
end

Element.hooks.destroyed = function(el, st)
	if st.data.paint then Draw.releaseRecording(st.data.paint.list); st.data.paint = nil end
	if hovered == el then hovered = nil end
	if captured == el then captured = nil end
	if focused == el then focused = nil end
	if tip_el == el then tip_el = nil end
	timers[el] = nil
	for i = #dialogs, 1, -1 do if dialogs[i] == el then table.remove(dialogs, i) end end
	if main_dialog == el then main_dialog = nil end
	if active_dialog == el then active_dialog = nil end
	for i = #overlays, 1, -1 do
		local o = overlays[i]
		if o.owner == el then o:close() end
	end
	local tex = st.data and st.data.tex
	local owner = st.data and st.data.tex_backend or B
	if tex and owner and owner.texture_free then pcall(owner.texture_free, tex) end
end

-- Globals ---------------------------------------------------------------------------------
local GLOBAL_GET = {
	SCREENSIZE = function()
		local w, h = 1920, 1040
		if B and B.window then
			local sw, sh = B.window("screen")
			if sw then w, h = sw, sh end
		end
		return string.format("%dx%d", w, h)
	end,
	FULLSIZE = function()
		local w, h = 1920, 1080
		if B and B.window then
			local sw, sh = B.window("full")
			if sw then w, h = sw, sh end
		end
		return string.format("%dx%d", w, h)
	end,
	CURSORPOS = function()
		if B and B.cursor_pos then
			local x, y = B.cursor_pos()
			return string.format("%dx%d", x or 0, y or 0)
		end
		return "0x0"
	end,
	SCREENDPI = function() return tostring(Fonts.dpi) end,
	SCREENDEPTH = function() return "32" end,
	SHIFTKEY = function() return frame_input and frame_input.mods.shift and "ON" or "OFF" end,
	CONTROLKEY = function() return frame_input and frame_input.mods.ctrl and "ON" or "OFF" end,
	MODKEYSTATE = function()
		local m = frame_input and frame_input.mods or {}
		return (m.shift and "S" or " ") .. (m.ctrl and "C" or " ") .. (m.alt and "A" or " ") .. (m.sys and "Y" or " ")
	end,
	VIRTUALSCREEN = function()
		local w, h = 1920, 1080
		if B and B.window then local fw, fh = B.window("full"); if fw then w, h = fw, fh end end
		return string.format("0 0 %d %d", w, h)
	end,
	MONITORSINFO = function()
		local w, h = 1920, 1080
		if B and B.window then local fw, fh = B.window("full"); if fw then w, h = fw, fh end end
		return string.format("0 0 %d %d\n", w, h)
	end,
	MONITORSCOUNT = function() return "1" end,
	LASTERROR = function() return nil end,
}

function M.setGlobal(name, value)
	value = Element.tostr(value)
	globals[name] = value
	if name == "DEFAULTFONT" or name == "DLGBGCOLOR" or name == "DLGFGCOLOR" or name:match("COLOR$") then
		Color.flush()
		for _, d in ipairs(dialogs) do STATE[d].data.layout_dirty = true end
	end
	if name == "DEFAULTFONT" then Fonts.reset() end
	need_frame = true
end

function M.getGlobal(name)
	local g = GLOBAL_GET[name]
	if g then return g() end
	return globals[name]
end

-- Element-wide getters IUP's base class provides (current size, position, WID...) ----

local function dialog_offset(el)
	local d, dst = dialog_of(el)
	if not dst then return 0, 0 end
	if d == main_dialog then return 0, 0 end
	return dst.data.ox or 0, dst.data.oy or 0
end
M.dialogOffset = dialog_offset

local function client_origin()
	if B and B.window then
		local x, y = B.window("client_origin")
		if x then return x, y end
	end
	return 0, 0
end
M.clientOrigin = client_origin

Element.commonGet = {
	WID = function(el, st) if st.mapped then return "WID" .. st.id end end,
	RASTERSIZE = function(el, st)
		M.layoutNow(el)
		if st.mapped and (st.w > 0 or st.h > 0) then return string.format("%dx%d", st.w, st.h) end
	end,
	CURRENTSIZE = function(el, st) M.layoutNow(el); return string.format("%dx%d", st.w, st.h) end,
	-- A dialog's client area (the whole window for one drawn inside the main window).
	CLIENTSIZE = function(el, st)
		if st.classname ~= "dialog" then return nil end
		return string.format("%dx%d", st.w, st.h)
	end,
	NATURALSIZE = function(el, st) M.layoutNow(el); return string.format("%dx%d", st.nat_w, st.nat_h) end,
	POSITION = function(el, st)
		M.layoutNow(el)
		local p = st.parent and STATE[st.parent]
		if st.classname == "dialog" then return nil end
		return string.format("%d,%d", st.x - (p and p.x or 0), st.y - (p and p.y or 0))
	end,
	X = function(el, st)
		M.layoutNow(el)
		local ox = select(1, client_origin()) + select(1, dialog_offset(el))
		return tostring(ox + st.x)
	end,
	Y = function(el, st)
		M.layoutNow(el)
		local _, oy = client_origin()
		local _, doy = dialog_offset(el)
		return tostring(oy + doy + st.y)
	end,
	SCREENPOSITION = function(el, st)
		M.layoutNow(el)
		local cx, cy = client_origin()
		local dx, dy = dialog_offset(el)
		if st.classname == "dialog" and el == main_dialog and B and B.window then
			local wx, wy = B.window("pos")
			if wx then return string.format("%d,%d", wx, wy) end
		end
		return string.format("%d,%d", cx + dx + st.x, cy + dy + st.y)
	end,
	HWND = function(el, st)
		if st.mapped and B and B.window then
			local d = dialog_of(el)
			-- a dialog on its own window (and its controls, which have none of their own)
			local own = d and M.dialogHwnd(d)
			if own then return tostring(own) end
			return tostring(B.window("hwnd") or 0)
		end
	end,
	NATIVEPARENT = function(el, st) return nil end,
	CHARSIZE = function(el, st)
		local cw, ch = Fonts.forElement(el):charsize()
		return string.format("%dx%d", cw, ch)
	end,
	FONTFACE = function(el) return Fonts.forElement(el).face end,
	FONTSIZE = function(el) return tostring(Fonts.forElement(el).pt) end,
	FONTSTYLE = function(el)
		local f = Fonts.forElement(el)
		local s = {}
		if f.bold then s[#s + 1] = "Bold" end
		if f.italic then s[#s + 1] = "Italic" end
		if f.underline then s[#s + 1] = "Underline" end
		if f.strikeout then s[#s + 1] = "Strikeout" end
		return table.concat(s, " ")
	end,
}

-- Element.getAttribute consults commonGet after class getters and before the store.
do
	local raw_get = Element.getAttribute
	local common = Element.commonGet
	Element.getAttribute = function(el, name)
		local st = STATE[el]
		if not st then return nil end
		local c = common[name]
		if c and not (st.class.get and st.class.get[name]) then
			local v = c(el, st)
			if v ~= nil then return v end
		end
		return raw_get(el, name)
	end
end

-- Visibility and hit testing ------------------------------------------------------------
local function own_visible(st)
	local v = st.attrs.VISIBLE
	return v ~= "NO"
end

local function children_shown(el, st)
	local vc = st.class.visibleChildren
	if vc then return vc(el, st) end
	return st.children
end
M.childrenShown = children_shown

--- Is the element and every ancestor visible (and its page the shown one)?
function M.isVisible(el)
	local e = el
	while e do
		local st = STATE[e]
		if not st or not own_visible(st) then return false end
		local p = st.parent
		if p then
			local ps = STATE[p]
			if ps.class.visibleChildren then
				local shown = false
				for _, c in ipairs(ps.class.visibleChildren(p, ps)) do if c == e then shown = true; break end end
				if not shown then return false end
			end
		elseif st.classname == "dialog" then
			return st.data.shown and true or false
		end
		e = p
	end
	return true
end

local function inside(st, x, y)
	return x >= st.x and y >= st.y and x < st.x + st.w and y < st.y + st.h
end

local function hit(el, x, y)
	local st = STATE[el]
	if not st or not own_visible(st) then return nil end
	local class = st.class
	local in_rect = inside(st, x, y)
	if class.hit then
		if not class.hit(el, st, x, y) then in_rect = false end
	end
	if class.clip and not in_rect then return nil end
	-- a native control's children live in its client area: not under its own scroll bars
	local in_client = true
	if class.clipRect then
		local cx, cy, cw, ch = class.clipRect(el, st)
		in_client = x >= cx and y >= cy and x < cx + cw and y < cy + ch
	end
	local kids = in_client and children_shown(el, st) or {}
	for i = #kids, 1, -1 do
		local found = hit(kids[i], x, y)
		if found then return found end
	end
	if in_rect and st.classname ~= "dialog" then
		-- Boxes are not windows in IUP: a click between children goes to nobody but the
		-- dialog. Containers with a look of their own (frames, tabs) do take it.
		if class.transparent or (class.children ~= 0 and not class.event and not class.opaque) then return nil end
		return el
	end
	if in_rect then return el end
	return nil
end
-- The three-argument form is used by widgets for coordinates local to an element.
-- The two-argument form mirrors the runtime's top-level pointer hit test for specs and
-- input tools, using the same retained-tree hit routine as route_input.
function M.hitTest(a, b, c)
	if c ~= nil then return hit(a, b, c) end
	local x, y = a, b
	for i = #dialogs, 1, -1 do
		local dialog = dialogs[i]
		local st = STATE[dialog]
		if st and st.data.shown then
			local ox, oy = 0, 0
			if dialog ~= main_dialog then ox, oy = st.data.ox or 0, st.data.oy or 0 end
			local lx, ly = x - ox, y - oy
			if lx >= 0 and ly >= 0 and lx < st.w and ly < st.h then
				return hit(dialog, lx, ly)
			end
		end
	end
	return nil
end

-- Focus --------------------------------------------------------------------------------
local function is_active(el)
	return Element.getAttribute(el, "ACTIVE") ~= "NO"
end

local function focusable(el)
	local st = STATE[el]
	if not st then return false end
	local f = st.class.focusable
	if type(f) == "function" then f = f(el, st) end
	if not f then return false end
	if Element.getAttribute(el, "CANFOCUS") == "NO" then return false end
	if not is_active(el) then return false end
	return M.isVisible(el)
end
M.focusable = focusable

local GENERIC_MOUSE = { press = "BUTTON_CB", release = "BUTTON_CB", move = "MOTION_CB", wheel = "WHEEL_CB" }

local function deliver(el, ev)
	local st = STATE[el]
	if not st then return false end
	local ev_fn = st.class.event
	ev.lx, ev.ly = (ev.x or 0) - st.x, (ev.y or 0) - st.y
	-- IUP passes buttons to BUTTON_CB as the characters '1' '2' '3'.
	if ev.button and not ev.iupbutton then ev.iupbutton = 48 + ev.button end
	-- Every IUP control with a window reports BUTTON_CB, MOTION_CB and WHEEL_CB (a label,
	-- a text, a list...). A class that does not handle one itself gets it here; IGNORE
	-- stops the control's own handling, as it does in IUP's drivers.
	local generic = GENERIC_MOUSE[ev.type]
	if generic and Element.hasCallback(el, generic) and not (st.class.callbacks and st.class.callbacks[generic]) then
		local r
		if generic == "BUTTON_CB" then
			r = Element.call(el, generic, ev.iupbutton, ev.type == "press" and 1 or 0, ev.lx, ev.ly, ev.status)
		elseif generic == "MOTION_CB" then
			r = Element.call(el, generic, ev.lx, ev.ly, ev.status)
		else
			r = Element.call(el, generic, ev.dy or 0, ev.lx, ev.ly, ev.status)
		end
		if r == CLOSE then M.exitLoop() end
		if r == IGNORE then return true end
		if not ev_fn then return true end
	end
	if not ev_fn then return false end
	local ok, consumed = xpcall(ev_fn, debug.traceback, el, st, ev, M)
	if not ok then warn(tostring(consumed)); return false end
	if ev.result == CLOSE then M.exitLoop() end
	return consumed and true or false
end
M.deliver = deliver

local function check_close(r)
	if r == CLOSE then M.exitLoop() end
	return r
end

function M.activateDialog(d)
	if d == active_dialog then return end
	local old = active_dialog
	active_dialog = d
	if old and STATE[old] then Element.call(old, "FOCUS_CB", 0) end
	if d and STATE[d] then Element.call(d, "FOCUS_CB", 1) end
end

function M.setFocus(el)
	if el ~= nil and not STATE[el] then return focused end
	if el then M.activateDialog(dialog_of(el)) end
	if el == focused then return focused end
	local old = focused
	if el and not focusable(el) then
		-- IUP gives focus to a non-focusable container's first focusable child.
		local found
		local function first(e)
			local st = STATE[e]
			if not st then return end
			if focusable(e) then found = e; return end
			for _, c in ipairs(children_shown(e, st)) do
				first(c)
				if found then return end
			end
		end
		first(el)
		if not found then return old end
		el = found
	end
	focused = el
	if old and STATE[old] then
		check_close(Element.call(old, "KILLFOCUS_CB"))
		deliver(old, { type = "blur" })
		check_close(Element.call(old, "FOCUS_CB", 0))
	end
	if el then
		check_close(Element.call(el, "GETFOCUS_CB"))
		deliver(el, { type = "focus" })
		check_close(Element.call(el, "FOCUS_CB", 1))
		local d = dialog_of(el)
		if d then STATE[d].data.last_focus = el end
	end
	need_frame = true
	return old
end

function M.getFocus() return focused end
function M.focused() return focused end

local function focus_order(root, out)
	local st = STATE[root]
	if not st or not own_visible(st) then return out end
	if focusable(root) then out[#out + 1] = root end
	for _, c in ipairs(children_shown(root, st)) do focus_order(c, out) end
	return out
end

function M.nextField(el, dir)
	el = el or focused
	local root = el and dialog_of(el) or dialogs[#dialogs]
	if not root then return nil end
	local order = focus_order(root, {})
	if #order == 0 then return nil end
	local idx = 0
	for i, e in ipairs(order) do if e == el then idx = i; break end end
	local n = idx + dir
	if n < 1 then n = #order elseif n > #order then n = 1 end
	M.setFocus(order[n])
	return order[n]
end

-- Services for widgets ---------------------------------------------------------------------
--- IupUpdate / IupRedraw: the element (and what is inside it) paints again.
function M.redraw(el)
	if el and STATE[el] then stamp(el) end
	need_frame = true
end
function M.relayout(el)
	need_frame = true
	if el and Element.invalidateLayout then Element.invalidateLayout(el) end
	if el then
		local _, dst = dialog_of(el)
		if dst then dst.data.layout_dirty = true end
	else
		for _, d in ipairs(dialogs) do STATE[d].data.layout_dirty = true end
	end
end
function M.capture(el) captured = el end
function M.tipShown() return tip_shown and true or false end -- for scripts/ui_mechanics.lua
function M.release() captured = nil end
function M.captured() return captured end
function M.now() return B and B.now() or os.clock() end
function M.animate() animating = true; need_frame = true end
--- The pointer in main-client coordinates, and whether it is over one of the host's windows.
function M.pointer() return last_mouse[1], last_mouse[2], last_inside end
-- A frame is wanted at time `t` (M.now() seconds) and not before: a caret blink, a
-- delayed hover. Cheaper than animate(), which draws every frame until it stops.
local wake_at
function M.wakeAt(t)
	t = tonumber(t)
	if t and (not wake_at or t < wake_at) then wake_at = t end
end
function M.cursor(name) cursor_override = name end
function M.clipboard_get() return B and B.clipboard_get and B.clipboard_get() or "" end
function M.clipboard_set(s) if B and B.clipboard_set then B.clipboard_set(s or "") end end
function M.backend() return B end
function M.dc() return dc end

--- Element rect in OS-window client coordinates.
function M.toWindow(el, x, y)
	local dx, dy = dialog_offset(el)
	return (x or 0) + dx, (y or 0) + dy
end

local Overlay = {}
Overlay.__index = Overlay
function Overlay:close()
	if overlay_windows then overlay_windows.release(self) end
	if M._overlay_capture == self then M._overlay_capture = nil end
	for i = #overlays, 1, -1 do
		if overlays[i] == self then
			table.remove(overlays, i)
			self.open = false
			need_frame = true
			if self.closed then
				local ok, err = pcall(self.closed)
				if not ok then warn(err) end
			end
			return
		end
	end
end
function Overlay:move(x, y, w, h)
	local dx, dy = 0, 0
	if self.owner then dx, dy = dialog_offset(self.owner) end
	self.x, self.y = x + dx, y + dy
	if w then self.w, self.h = w, h end
	need_frame = true
end
function Overlay:isOpen() return self.open end

--- Open an overlay (a dropdown, a menu, a tooltip, a transition layer). Coordinates are in
-- the owner's dialog client space.
function M.overlay(o)
	local h = setmetatable(o, Overlay)
	h.window_owner = dialog_of(h.owner) or active_dialog or main_dialog
	local dx, dy = 0, 0
	if h.owner then dx, dy = dialog_offset(h.owner) end
	h.x, h.y = (h.x or 0) + dx, (h.y or 0) + dy
	h.dx, h.dy = dx, dy
	h.w, h.h = h.w or 0, h.h or 0
	h.open = true
	overlays[#overlays + 1] = h
	need_frame = true
	return h
end
function M.overlays() return overlays end

-- Timers -------------------------------------------------------------------------------------
function M.timerStart(el)
	local st = STATE[el]
	if not st then return end
	local ms = tonumber(Element.getAttribute(el, "TIME")) or 0
	st.data.interval = math.max(ms, 1) / 1000
	st.data.started = M.now()
	st.data.due = st.data.started + st.data.interval
	timers[el] = true
	need_frame = true
end

function M.timerStop(el)
	timers[el] = nil
	local st = STATE[el]
	if st then st.data.due = nil end
end

function M.timerRunning(el) return timers[el] and true or false end

local function run_timers(now)
	local due = {}
	for el in pairs(timers) do
		local st = STATE[el]
		if not st then timers[el] = nil
		elseif st.data.due and st.data.due <= now then due[#due + 1] = el end
	end
	table.sort(due, function(a, b) return STATE[a].data.due < STATE[b].data.due end)
	for _, el in ipairs(due) do
		local st = STATE[el]
		if st and timers[el] then
			st.data.due = now + st.data.interval
			check_close(Element.call(el, "ACTION_CB"))
		end
	end
end

local function next_timer_due()
	local best = wake_at
	for el in pairs(timers) do
		local st = STATE[el]
		local d = st and st.data.due
		if d and (not best or d < best) then best = d end
	end
	return best
end

-- Map / show / hide --------------------------------------------------------------------------
local function map_tree(el)
	local st = STATE[el]
	if not st or st.mapped then
		if st then for _, c in ipairs(st.children) do map_tree(c) end end
		return
	end
	st.mapped = true
	if st.class.map then st.class.map(el, st, M) end
	check_close(Element.call(el, "MAP_CB"))
	for _, c in ipairs(st.children) do map_tree(c) end
end
M.mapTree = map_tree

function M.map(el)
	-- Mapping a child maps it only if its dialog is mapped, as IupMap does.
	local d, dst = dialog_of(el)
	if not d then
		local st = STATE[el]
		if st and st.classname ~= "dialog" then return -1 end
	end
	if el ~= d and dst and not dst.mapped then map_tree(d) else map_tree(el) end
	M.relayout(el)
	return 0
end

function M.unmap(el)
	local function walk(e)
		local st = STATE[e]
		if not st or not st.mapped then return end
		for _, c in ipairs(st.children) do walk(c) end
		check_close(Element.call(e, "UNMAP_CB"))
		st.mapped = false
	end
	walk(el)
end

function M.reparented(child)
	local _, dst = dialog_of(child)
	if dst and dst.mapped then map_tree(child) end
	M.relayout(child)
end

local function parse_size(s)
	if not s then return nil end
	local w, h = tostring(s):match("^(%d*)x(%d*)$")
	return tonumber(w), tonumber(h)
end

local function dialog_size(d, st)
	if not Layout then Layout = require("core.imgui.Layout") end
	local w, h = Layout.natural(d)
	return math.max(w or 0, 1), math.max(h or 0, 1)
end

--- The client size of a dialog drawn inside the main window. A user size (RASTERSIZE, SIZE)
-- is the whole window's, and iDialogSetChildrenCurrentSizeMethod gives the child that less
-- the frame (iupDialogGetDecorSize); a dialog sized by its content gets the content.
local function panel_client_size(d, st)
	local w, h = dialog_size(d, st)
	local uw, uh = Layout.userSize(d, st)
	local dw, dh = require("core.imgui.widgets.dialog").decorSize(d)
	if uw > 0 then w = math.max(1, uw - dw) end
	if uh > 0 then h = math.max(1, uh - dh) end
	return w, h
end

local SCREEN_POS = {
	[0xFFFF] = "center", [0xFFFE] = "left", [0xFFFD] = "right", [0xFFFC] = "mouse",
	[0xFFFB] = "current", [0xFFFA] = "centerparent", [0xFFF9] = "leftparent", [0xFFF8] = "rightparent",
}

local function resolve_xy(d, st, x, y, w, h)
	local cx, cy = client_origin()
	local ww, wh = 1280, 800
	if main_dialog then ww, wh = STATE[main_dialog].w, STATE[main_dialog].h end
	-- iDialogAdjustPos places the dialog's window against the parent's window, not its
	-- client: (fl, ft) is the main window's frame left of and above its client
	local fl, ft = 0, 0
	if B and B.window then
		local wx, wy = B.window("pos")
		local ow, oh = B.window("window_size")
		if wx and ow then fl, ft, ww, wh = cx - wx, cy - wy, ow, oh end
	end
	local function axis(v, size, total, origin, is_x)
		local kind = SCREEN_POS[v or 0xFFFA]
		if v == nil then kind = "centerparent" end
		local f = is_x and fl or ft
		if kind == "center" or kind == "centerparent" then return math.floor((total - size) / 2) - f end
		if kind == "left" or kind == "leftparent" then return -f end
		if kind == "right" or kind == "rightparent" then return total - size - f end
		if kind == "mouse" then
			local m = is_x and last_mouse[1] or last_mouse[2]
			return math.max(0, math.min(m, total - size))
		end
		if kind == "current" then return is_x and (st.data.ox or 0) or (st.data.oy or 0) end
		return v - origin
	end
	return axis(x, w, ww, cx, true), axis(y, h, wh, cy, false)
end

local function raise(d)
	for i = #dialogs, 1, -1 do if dialogs[i] == d then table.remove(dialogs, i) end end
	dialogs[#dialogs + 1] = d
end

function M.show(d, x, y)
	local st = STATE[d]
	if not st then return -1 end
	if st.classname ~= "dialog" then
		-- IupShow on a control makes it visible (VISIBLE=YES).
		Element.setAttribute(d, "VISIBLE", "YES")
		return 0
	end
	if not st.mapped then map_tree(d) end
	local first_show = not st.data.shown
	st.data.layout_dirty = true
	if not main_dialog or main_dialog == d then
		main_dialog = d
		if not B.alive() then
			local w, h = parse_size(Element.own(d, "RASTERSIZE"))
			if not (w and h) then
				local nw, nh = dialog_size(d, st)
				w, h = w or nw, h or nh
			end
			local placement = Element.own(d, "PLACEMENT")
			local ok, err = B.open({
				title = Element.getAttribute(d, "TITLE") or "",
				w = w, h = h,
				x = (x and x < 0xFFF0) and x or nil, y = (y and y < 0xFFF0) and y or nil,
				maximized = placement == "MAXIMIZED" or Element.own(d, "MAXIMIZED") == "YES",
				borderless = Element.own(d, "BORDER") == "NO" or st.data.custom_frame,
			})
			if not ok then error("could not open the window: " .. tostring(err)) end
			st.w, st.h = w, h
		else
			if B.window then B.window("show") end
		end
		st.x, st.y = 0, 0
	else
		local w, h = panel_client_size(d, st)
		st.w, st.h = w, h
		if first_show or x then
			-- iDialogAdjustPos places the window; the client sits inside its frame
			local dw, dh = require("core.imgui.widgets.dialog").decorSize(d)
			local wx, wy = resolve_xy(d, st, x, y, w + dw, h + dh)
			st.data.ox, st.data.oy = wx + dw / 2, wy + dh - dw / 2
		end
	end
	st.data.shown = true
	require("core.imgui.widgets.dialog").applyLimits(d)
	raise(d)
	if not first_show and st.data.win and st.data.win_shown then B.window("popup_focus", st.data.win) end
	need_frame = true
	-- iDialogAfterShow (iup_dialog.c): process the pending messages first (IupFlush, so
	-- due timers run here, before SHOW_CB), then SHOW_CB, then the start focus unless
	-- SHOW_CB moved the focus itself.
	local noflush = Element.getAttribute(d, "NOFLUSH") == "YES"
	if not noflush then M.flush() end
	local old_focus = focused
	local has_show_cb = Element.hasCallback(d, "SHOW_CB")
	if check_close(Element.call(d, "SHOW_CB", first_show and 0 or 1)) == CLOSE then return 0 end
	if first_show then
		if has_show_cb and not noflush then M.flush() end
		-- SHOWNOFOCUS: a notification shows without taking the keyboard from the user.
		if old_focus == focused and not Element.isTrue(Element.getAttribute(d, "SHOWNOFOCUS")) then
			local start = Element.getHandle(d, "STARTFOCUS")
			if start then M.setFocus(start)
			else
				local order = focus_order(d, {})
				if order[1] then M.setFocus(order[1]) end
			end
		end
	end
	return 0
end

function M.hide(d)
	local st = STATE[d]
	if not st then return end
	if st.classname ~= "dialog" then
		Element.setAttribute(d, "VISIBLE", "NO")
		return 0
	end
	if not st.data.shown then return 0 end
	st.data.shown = false
	if st.data.win and st.data.win_shown then
		B.window("popup_place", st.data.win, 0, 0, 1, 1, false)
		st.data.win_shown = false
		st.data.opened = nil -- the next show fades in again
	end
	for i = #dialogs, 1, -1 do if dialogs[i] == d then table.remove(dialogs, i) end end
	if focused and dialog_of(focused) == d then
		focused = nil
		local top = dialogs[#dialogs]
		local back = top and STATE[top].data.last_focus
		if back and STATE[back] then M.setFocus(back) end
	end
	if captured and dialog_of(captured) == d then captured = nil end
	if hovered and dialog_of(hovered) == d then hovered = nil end
	for i = #overlays, 1, -1 do
		local o = overlays[i]
		if o.window_owner == d or (o.owner and dialog_of(o.owner) == d) then o:close() end
	end
	if d == main_dialog and B.window then B.window("hide") end
	-- iDialogAfterHide: flush, then SHOW_CB
	if Element.getAttribute(d, "NOFLUSH") ~= "YES" then M.flush() end
	check_close(Element.call(d, "SHOW_CB", 4))
	-- IUP leaves MainLoop when the last visible dialog is hidden.
	if #dialogs == 0 and loop_level > 0 then M.exitLoop() end
	need_frame = true
	return 0
end

function M.destroy(el)
	local st = STATE[el]
	if not st then return end
	if st.classname == "dialog" and st.data.shown then M.hide(el) end
	if st.data.win then B.window("popup_close", st.data.win); st.data.win = nil end
	Element.destroy(el)
end

function M.refresh(el)
	M.relayout(el)
end

--- IupRefresh lays a dialog out at once (iupLayoutCompute + iupLayoutUpdate); this host
-- does it when it is needed. Reading a geometry attribute of an element whose dialog
-- has a layout pending lays that dialog out first, so code that sets sizes, refreshes
-- and reads RASTERSIZE back sees what IUP would show it. The dialog takes its own
-- RASTERSIZE, else its current size, else its natural size.
function M.layoutNow(el)
	if in_layout or in_paint or not el then return end
	local d, st = dialog_of(el)
	if not d or not st or not st.data.layout_dirty then return end
	if not Layout then Layout = require("core.imgui.Layout") end
	local w, h
	if d == main_dialog and st.data.shown then
		w, h = st.w, st.h
	elseif main_dialog and d ~= main_dialog and Element.own(d, "RASTERSIZE") and not st.data.user_sized then
		w, h = panel_client_size(d, st)
		if st.data.shown then st.w, st.h = w, h end
	else
		w, h = parse_size(Element.own(d, "RASTERSIZE"))
		if not (w and h) then
			local cw, ch
			if st.data.shown then cw, ch = st.w, st.h else cw, ch = dialog_size(d, st) end
			w, h = w or cw, h or ch
		end
		if st.data.shown then st.w, st.h = w, h end
	end
	if not (w and h) or w <= 0 or h <= 0 then return end
	in_layout = true
	local ok, err = xpcall(Layout.run, debug.traceback, d, w, h)
	in_layout = false
	if not ok then warn(err) end
	-- the frame need not lay it out again unless the size it gets differs
	if st.data.lw == w and st.data.lh == h then st.data.layout_dirty = false end
end

--- IupFlush: run what is pending (due timers, then a frame for input and paint). Called
-- from inside a paint or a layout, as an ACTION callback might, it only runs the timers.
function M.flush()
	if in_paint or in_layout then
		if not closed then run_timers(M.now()) end
		return
	end
	M.step(false)
end

-- Popup: modal dialogs, menus and the stock dialogs -----------------------------------------
function M.runUntil(done)
	loop_level = loop_level + 1
	local level = loop_level
	exit_levels[level] = false
	while not exit_levels[level] and not quitting and not done() and not closed do
		M.step(true)
	end
	exit_levels[level] = nil
	loop_level = level - 1
end

function M.popup(el, x, y)
	local st = STATE[el]
	if not st then return -1 end
	if st.classname == "menu" then
		local Menu = require("core.imgui.widgets.menu")
		local sx, sy = x, y
		local cx, cy = client_origin()
		if not sx or sx >= 0xFFF0 then sx = last_mouse[1] else sx = sx - cx end
		if not sy or sy >= 0xFFF0 then sy = last_mouse[2] else sy = sy - cy end
		local handle = Menu.popupMenu(el, sx, sy, M)
		if handle and handle.isOpen then
			M.runUntil(function() return not handle:isOpen() end)
		end
		return 0
	end
	if st.class.popup then return st.class.popup(el, st, M, x, y) end
	if st.classname ~= "dialog" then return -1 end
	st.data.modal = true
	M.show(el, x or iup.CENTERPARENT, y or iup.CENTERPARENT)
	M.runUntil(function() return not st.data.shown or not STATE[el] end)
	if STATE[el] then st.data.modal = false end
	return 0
end

function M.message(title, message)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.message(M, title, message)
end
function M.alarm(title, message, b1, b2, b3)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.alarm(M, title, message, b1, b2, b3)
end
function M.getText(title, text)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.getText(M, title, text)
end
function M.getParam(title, action, format, ...)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.getParam(M, title, action, format, ...)
end
function M.scanf(format, ...)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.scanf(M, format, ...)
end
function M.listDialog(...)
	local Dialogs = require("core.imgui.widgets.dialog")
	return Dialogs.listDialog(M, ...)
end

-- Text position (iup.ConvertXYToPos) ------------------------------------------------------
function M.convertXYToPos(el, x, y)
	local st = STATE[el]
	if st and st.class.xyToPos then return st.class.xyToPos(el, st, x, y) end
	return -1
end

-- Loops -----------------------------------------------------------------------------------
function M.mainLoop()
	if quitting or (#dialogs == 0 and not next(timers)) then return 0 end
	M.runUntil(function() return false end)
	return 0
end

function M.loopLevel() return loop_level end

function M.exitLoop()
	if loop_level > 0 then exit_levels[loop_level] = true end
	need_frame = true
end

--- One iteration: timers, then a frame. With `wait`, block for input when idle.
function M.step(wait)
	if closed then return CLOSE end
	local now = M.now()
	run_timers(now)
	if wake_at and now >= wake_at then wake_at = nil; need_frame = true end
	if wait and not need_frame and not animating then
		local due = next_timer_due()
		local t = 0.5
		if due then t = math.max(0, math.min(t, due - M.now())) end
		local woke
		if t > 0 then woke = B.wait(t) end
		run_timers(M.now())
		if wake_at and M.now() >= wake_at then wake_at = nil; need_frame = true end
		-- Nothing arrived and nothing changed: the window already shows this frame. (A
		-- backend whose wait says nothing, like the Null one, always gets the frame.)
		if woke == false and not need_frame and not animating then return DEFAULT end
	end
	M.frame()
	return DEFAULT
end

function M.loopStep(wait)
	M.step(wait)
	if loop_level > 0 and exit_levels[loop_level] then return CLOSE end
	return DEFAULT
end

-- Input routing ------------------------------------------------------------------------------
local K_TAB, K_CR, K_ESC = 9, 13, 0xFF1B
local SHIFT, CTRL, ALT, SYS = 0x10000000, 0x20000000, 0x40000000, 0x80000000
local bit = require("bit")

--- Turn a backend key event into IUP's code, or nil when the typed character carries it.
local function iup_key(k)
	local code = k.code
	if not code then return nil end
	local mod = (k.ctrl or k.alt or k.sys)
	if code >= 97 and code <= 122 then code = code - 32 end
	local printable = code >= 32 and code < 127
	if printable and not mod then return nil end   -- arrives as a char
	if printable then
		local c = code
		if k.ctrl then c = bit.bor(c, CTRL) end
		if k.alt then c = bit.bor(c, ALT) end
		if k.sys then c = bit.bor(c, SYS) end
		if k.shift and not (c >= 65 and c <= 90) then c = bit.bor(c, SHIFT) end
		if k.shift and (code >= 65 and code <= 90) and not k.ctrl and not k.alt then c = bit.bor(c, SHIFT) end
		return c
	end
	local c = code
	if k.shift then c = bit.bor(c, SHIFT) end
	if k.ctrl then c = bit.bor(c, CTRL) end
	if k.alt then c = bit.bor(c, ALT) end
	if k.sys then c = bit.bor(c, SYS) end
	return c
end
M.iupKey = iup_key

local KEYNAMES
local function key_name(code)
	if not KEYNAMES then
		KEYNAMES = {}
		for k, v in pairs(iup) do
			if type(k) == "string" and k:sub(1, 2) == "K_" and type(v) == "number" then
				KEYNAMES[v] = KEYNAMES[v] or k
			end
		end
	end
	return KEYNAMES[code]
end

--- K_ANY (and named key callbacks) from the focus up to the dialog, IUP's propagation.
local function key_callbacks(start, code)
	local e = start
	local name = key_name(code)
	while e do
		local st = STATE[e]
		if not st then break end
		local r
		if name and st.cbs[name] then r = Element.call(e, name)
		elseif st.cbs.K_ANY then r = Element.call(e, "K_ANY", code) end
		if r ~= nil then
			if r == CLOSE then M.exitLoop(); return IGNORE end
			if r ~= CONTINUE then return r end
		end
		e = st.parent
	end
	return nil
end

local function activate_default(d, name)
	local btn = Element.getHandle(d, name)
	if not btn or not STATE[btn] then return false end
	local st = STATE[btn]
	if st.cbs.FLAT_ACTION then check_close(Element.call(btn, "FLAT_ACTION"))
	elseif st.cbs.ACTION then check_close(Element.call(btn, "ACTION")) end
	return true
end

local function topmost_dialog()
	return dialogs[#dialogs]
end

local function modal_top()
	for i = #dialogs, 1, -1 do
		local st = STATE[dialogs[i]]
		if st and st.data.modal then return dialogs[i] end
	end
	return nil
end

M.activateDefault = function(el, name) local d = dialog_of(el) or el; return activate_default(d, name) end
local function key_event(code)
	-- An open overlay (dropdown, menu) sees keys first.
	for i = #overlays, 1, -1 do
		local o = overlays[i]
		if o.event then
			local ok, consumed = pcall(o.event, { type = "key", key = code, mods = frame_input.mods })
			if ok and consumed then return end
			if not ok then warn(consumed) end
			if o.modal then return end
		end
	end
	local target = focused or modal_top() or topmost_dialog()
	if not target then return end
	local r = key_callbacks(target, code)
	if r == IGNORE then return end
	if focused and deliver(focused, { type = "key", key = code, mods = frame_input.mods }) then return end
	local d = dialog_of(target) or target
	local base = bit.band(code, 0x0FFFFFFF)
	if base == K_TAB and bit.band(code, CTRL + ALT) == 0 then
		M.nextField(focused, bit.band(code, SHIFT) ~= 0 and -1 or 1)
	elseif code == K_CR then
		activate_default(d, "DEFAULTENTER")
	elseif code == K_ESC then
		activate_default(d, "DEFAULTESC")
	end
end

local function char_event(ch)
	local cp = ch:byte(1) or 0
	if cp < 32 or cp == 127 then return end
	-- The code point of the character, as IUP passes it.
	if cp >= 0xC0 then
		local n = cp >= 0xF0 and 4 or cp >= 0xE0 and 3 or 2
		cp = cp % (2 ^ (7 - n))
		for i = 2, n do cp = cp * 64 + (ch:byte(i) or 128) % 64 end
	end
	for i = #overlays, 1, -1 do
		local o = overlays[i]
		if o.event then
			local ok, consumed = pcall(o.event, { type = "char", char = ch, key = cp, mods = frame_input.mods })
			if ok and consumed then return end
			if o.modal then return end
		end
	end
	local target = focused or modal_top() or topmost_dialog()
	if not target then return end
	local r = key_callbacks(target, cp)
	if r == IGNORE then return end
	if focused then deliver(focused, { type = "char", char = ch, key = cp, mods = frame_input.mods }) end
end

local function status_for(input, extra)
	local m = input.mods
	return iup._status({
		shift = m.shift, ctrl = m.ctrl, alt = m.alt, sys = m.sys,
		b1 = input.down[1], b2 = input.down[2], b3 = input.down[3],
		double = extra and extra.double,
	})
end

-- Secondary dialogs as their own windows (backends with B.surface; LUNAR_DIALOG_WINDOWS=0
-- keeps them as panels in the main window). The dialog keeps its place at (ox, oy) in the
-- main window's client coordinates; the backend puts the client of an owned native window
-- there (iupwin_dialog.c styles: caption, MENUBOX/MINBOX/MAXBOX, RESIZE, BORDER, TOOLBOX),
-- so Windows draws the frame and caption as under IUP, and reports input in the main
-- window's coordinates, so routing does not change.
local dialog_windows = false
local pending_closes = {}

local function ensure_window(d, st)
	if not dialog_windows or st.data.win == false then return false end
	if st.data.win then
		-- A device reset may restore the main surface but fail a popup swap chain.
		-- Hide/destroy that window and retain the logical dialog as a drawn panel.
		if B.window("popup_ready", st.data.win) == false then
			B.window("popup_close", st.data.win)
			st.data.win = false
			return false
		end
		return true
	end
	if not (B.alive and B.alive()) then return false end
	local function a(n) return Element.getAttribute(d, n) end
	local yes = Element.isTrue
	-- winDialogMapMethod: RESIZE=NO turns MAXBOX off; TITLE or a box makes the title bar,
	-- and any of those or BORDER the border
	local resize = yes(a("RESIZE"))
	local maxbox = resize and yes(a("MAXBOX"))
	local caption = Element.own(d, "TITLE") ~= nil or yes(a("MENUBOX")) or maxbox or yes(a("MINBOX"))
	if Element.own(d, "CUSTOMFRAME") == "YES" or Element.own(d, "HIDETITLEBAR") == "YES" then caption = false end
	local border = yes(a("BORDER")) or caption or resize
	-- iupDialogGetNativeParent: PARENTDIALOG's window owns it; without one it is top level
	local parent = Element.getHandle(d, "PARENTDIALOG")
	local pst = parent and STATE[parent]
	local id = B.window("popup_open", {
		title = a("TITLE") or "", caption = caption, border = border, resize = resize,
		menubox = yes(a("MENUBOX")), minbox = yes(a("MINBOX")), maxbox = maxbox, dropfiles = Element.hasCallback(d, "DROPFILES_CB"),
		toolbox = yes(a("TOOLBOX")), dialogframe = yes(a("DIALOGFRAME")),
		taskbar = Element.own(d, "TASKBARBUTTON"),
		owned = parent ~= nil, parent = (parent ~= main_dialog and pst and pst.data.win) or 0,
	})
	st.data.win = id or false
	if id then require("core.imgui.widgets.dialog").applyLimits(d) end
	return id ~= nil
end

--- The native window of a secondary dialog (made now if needed, as IupMap makes it on
-- IUP, so code that themes the frame right after mapping finds it), or nil when the
-- dialog has none (the main dialog, or dialogs drawn as panels).
function M.dialogHwnd(d)
	local st = STATE[d]
	if not st or st.classname ~= "dialog" or d == main_dialog then return nil end
	if not ensure_window(d, st) then return nil end
	return B.window("popup_hwnd", st.data.win)
end

--- Where the user moved or sized a dialog window, and whether its close button was used.
local function sync_windows()
	if not dialog_windows then return end
	if main_dialog and B.window("is_active") then M.activateDialog(main_dialog) end
	for _, d in ipairs(dialogs) do
		local st = STATE[d]
		if st and d ~= main_dialog and st.data.win and st.data.win_shown then
			local x, y, w, h, close, minimized, active = B.window("popup_state", st.data.win)
			-- the window includes a glass dialog's shadow clearance; the dialog is inside it
			local c = st.data.clear or 0
			if x and c > 0 then x, y, w, h = x + c, y + c, w - 2 * c, h - 2 * c end
			if active then M.activateDialog(d) end
			if x and not minimized then
				if x ~= st.data.ox or y ~= st.data.oy then
					st.data.ox, st.data.oy = x, y
					check_close(Element.call(d, "MOVE_CB", x, y))
				end
				if w > 0 and h > 0 and (w ~= st.w or h ~= st.h) then
					st.w, st.h = w, h
					st.data.user_sized = true
					st.data.layout_dirty = true
				end
			end
			if close then pending_closes[#pending_closes + 1] = d end
		end
	end
end

--- The close button (WM_CLOSE): CLOSE_CB, then hide unless it says IGNORE. Run after the
-- frame ends, since hiding flushes and may draw a frame itself.
local function run_closes()
	if #pending_closes == 0 then return end
	local list = pending_closes
	pending_closes = {}
	for _, d in ipairs(list) do
		local st = STATE[d]
		if st and st.data.shown then
			local r = Element.call(d, "CLOSE_CB")
			if r ~= IGNORE then
				if r == CLOSE then M.exitLoop() end
				M.hide(d)
			end
		end
	end
end

--- The dialog window an element is on: its dialog's state, or nil on the main window.
local function window_of(el)
	if not el then return nil end
	local d, st = dialog_of(el)
	if d and d ~= main_dialog and st and st.data.win and st.data.win_shown then return st end
	return nil
end

local function prepare_overlay(o)
	local owner = o.window_owner or o.owner
	local ws = window_of(owner)
	local st = ws or (main_dialog and STATE[main_dialog])
	local bounds = ws and { ws.data.ox or 0, ws.data.oy or 0, ws.w, ws.h } or { 0, 0, st and st.w or 1280, st and st.h or 800 }
	local id, x, y, w, h = overlay_windows.prepare(o, ws and ws.data.win or 0, bounds, video_rects)
	if id then return id, x, y, w, h end
	if ws then return ws.data.win, unpack(bounds) end
end

--- What is under the window point (x, y): an overlay, or an element and its dialog.
-- With dialog windows, `win` is the window the pointer is over (0 the main one): only
-- what is on that window can be under it, whatever the windows' stacking order.
local function surface_of(d, st)
	if d ~= main_dialog and st and st.data.win and st.data.win_shown then return st.data.win end
	return 0
end
local function pick(x, y, win)
	for i = #overlays, 1, -1 do
		local o = overlays[i]
		local ws = win and window_of(o.window_owner or o.owner)
		local here = not win or (o.win or (ws and ws.data.win) or 0) == win
		local ox, oy = o.x + (o.shift_x or 0), o.y + (o.shift_y or 0)
		if here and o.event and x >= ox and y >= oy and x < ox + o.w and y < oy + o.h then return nil, nil, o end
	end
	local modal = modal_top()
	for i = #dialogs, 1, -1 do
		local d = dialogs[i]
		local st = STATE[d]
		if win and surface_of(d, st) ~= win then goto next_dialog end
		local ox, oy = 0, 0
		if d ~= main_dialog then ox, oy = st.data.ox or 0, st.data.oy or 0 end
		local lx, ly = x - ox, y - oy
		if d ~= main_dialog and st.data.chrome then
			local ch = st.data.chrome
			if lx >= 0 and ly >= -ch.top and lx < st.w and ly < 0 then return nil, d, nil, "caption" end
		end
		if lx >= 0 and ly >= 0 and lx < st.w and ly < st.h then
			return hit(d, lx, ly) or d, d
		end
		if d == modal then return nil, d end
		::next_dialog::
	end
	return nil, nil
end

local function local_xy(el, x, y)
	local dx, dy = dialog_offset(el)
	return x - dx, y - dy
end

local DRAG = nil -- dragging a secondary dialog by its caption

--- Hooks run before input routing: preRoute(input) -> true consumes the mouse this frame.
-- The window frame's caption buttons use it, with postPaint.
-- @table preRoute
M.preRoute = {}
--- Hooks run after painting: postPaint(dc, input) paints over the main dialog.
-- @table postPaint
M.postPaint = {}

local function route(input)
	for _, fn in ipairs(M.preRoute) do
		local ok, r = pcall(fn, input)
		if not ok then warn(r) elseif r then return end
	end
	local mx, my = input.mx, input.my
	local moved = mx ~= last_mouse[1] or my ~= last_mouse[2]
	last_mouse[1], last_mouse[2] = mx, my
	last_inside = input.inside == true
	-- glass lit toward the pointer near it (core.ui.Glass) follows it
	if moved then
		local Glass = package.loaded["core.ui.Glass"]
		if Glass and Glass.wantsPointer and Glass.wantsPointer(mx, my, last_inside) then need_frame = true end
	end

	if DRAG then
		local st = STATE[DRAG.d]
		if st then
			st.data.ox = DRAG.ox + (mx - DRAG.mx)
			st.data.oy = DRAG.oy + (my - DRAG.my)
			if moved then check_close(Element.call(DRAG.d, "MOVE_CB", st.data.ox, st.data.oy)) end
		end
		if input.released[1] > 0 or not input.down[1] then DRAG = nil end
		need_frame = true
		return
	end

	local target, target_dialog, overlay, part = nil, nil, nil, nil
	if input.inside or captured then
		target, target_dialog, overlay, part = pick(mx, my, (dialog_windows or overlay_windows.enabled) and input.win or nil)
	end
	local modal = modal_top()
	if modal and target and dialog_of(target) ~= modal then target = nil end

	-- An overlay captures the mouse while a button is held on it.
	local over = M._overlay_capture or overlay
	if over ~= hover_overlay then hover_overlay = over; need_frame = true end

	-- Hover
	local new_hover = captured or (not over and target) or nil
	if new_hover ~= hovered then
		local old = hovered
		hovered = new_hover
		if old and STATE[old] then
			local lx, ly = local_xy(old, mx, my)
			deliver(old, { type = "leave", x = lx, y = ly })
			check_close(Element.call(old, "LEAVEWINDOW_CB"))
		end
		if new_hover then
			local lx, ly = local_xy(new_hover, mx, my)
			check_close(Element.call(new_hover, "ENTERWINDOW_CB"))
			deliver(new_hover, { type = "enter", x = lx, y = ly })
		end
		hover_since = M.now()
		tip_shown = false
		need_frame = true
	elseif moved then
		if not tip_shown then hover_since = M.now() end
	end

	-- Overlays first
	if over and over.event then
		local function ov(ev)
			ev.x, ev.y = mx - over.dx - (over.shift_x or 0), my - over.dy - (over.shift_y or 0)
			ev.lx, ev.ly = mx - over.x - (over.shift_x or 0), my - over.y - (over.shift_y or 0)
			local ok, r = pcall(over.event, ev)
			if not ok then warn(r) end
			return r
		end
		for b = 1, 3 do
			if input.pressed[b] > 0 then
				if over.owner then M.activateDialog(dialog_of(over.owner)) end
				M._overlay_capture = over
				ov({ type = "press", button = b, double = input.double[b] > 0, status = status_for(input, { double = input.double[b] > 0 }) })
			end
		end
		if moved then ov({ type = "move", status = status_for(input) }) end
		if input.wheel_y ~= 0 or input.wheel_x ~= 0 then ov({ type = "wheel", dy = input.wheel_y, dx = input.wheel_x, status = status_for(input) }) end
		for b = 1, 3 do
			if input.released[b] > 0 then
				ov({ type = "release", button = b, status = status_for(input) })
				M._overlay_capture = nil
			end
		end
		need_frame = true
		return
	end

	-- A press outside the open, non-sticky overlays closes them (and is swallowed).
	local any_press = input.pressed[1] > 0 or input.pressed[2] > 0 or input.pressed[3] > 0
	if any_press then
		local closed_any = false
		for i = #overlays, 1, -1 do
			local o = overlays[i]
			if o.event and not o.sticky then o:close(); closed_any = true end
		end
		if closed_any then return end
	end

	if part == "caption" and input.pressed[1] > 0 and target_dialog then
		local st = STATE[target_dialog]
		local ch = st.data.chrome
		local lx = mx - (st.data.ox or 0)
		if ch.close and lx >= ch.close.x then
			if Element.call(target_dialog, "CLOSE_CB") ~= IGNORE then M.hide(target_dialog) end
		else
			DRAG = { d = target_dialog, mx = mx, my = my, ox = st.data.ox or 0, oy = st.data.oy or 0 }
			raise(target_dialog)
		end
		return
	end

	local recv = captured or target
	if recv then
		local lx, ly = local_xy(recv, mx, my)
		for b = 1, 3 do
			if input.pressed[b] > 0 then
				M.activateDialog(dialog_of(recv))
				if target_dialog and target_dialog ~= main_dialog then raise(target_dialog) end
				if b == 1 and recv ~= focused and focusable(recv) then M.setFocus(recv) end
				captured = recv
				local dbl = input.double[b] > 0
				deliver(recv, { type = "press", button = b, x = lx, y = ly, double = dbl,
					status = status_for(input, { double = dbl }), mods = input.mods })
			end
		end
		if moved then
			deliver(recv, { type = "move", x = lx, y = ly, status = status_for(input), mods = input.mods })
		end
		if input.wheel_y ~= 0 or input.wheel_x ~= 0 then
			local e = target
			while e do
				if deliver(e, { type = "wheel", x = lx, y = ly, dy = input.wheel_y, dx = input.wheel_x,
					status = status_for(input), mods = input.mods }) then break end
				local st = STATE[e]
				e = st and st.parent
			end
		end
		for b = 1, 3 do
			if input.released[b] > 0 then
				local r = captured or recv
				local rx, ry = local_xy(r, mx, my)
				deliver(r, { type = "release", button = b, x = rx, y = ry, status = status_for(input), mods = input.mods })
				if not (input.down[1] or input.down[2] or input.down[3]) then captured = nil end
			end
		end
	end
end

-- The native backend reports input as ordered events (input.events), each with the
-- pointer position, buttons and modifiers it happened with. They are routed one at a
-- time, so a press and a release in the same frame (a tap, a fast click), a click
-- followed by the pointer leaving, or a key typed between two clicks all reach the
-- widgets in order and at the right place. Each event is presented to `route` as a
-- one-event input of the old shape.
local MINI = {
	pressed = { 0, 0, 0 }, released = { 0, 0, 0 }, double = { 0, 0, 0 }, down = { false, false, false },
	wheel_x = 0, wheel_y = 0, keys = {}, chars = {}, files = {},
}
local route_keys
local function route_events(input)
	local evs = input.events
	if not evs then
		route(input)
		route_keys(input)
		return
	end
	local mini = MINI
	mini.w, mini.h, mini.scale, mini.focused = input.w, input.h, input.scale, input.focused
	mini.mx, mini.my, mini.inside = last_mouse[1], last_mouse[2], input.inside
	local routed_mouse = false
	for i = 1, #evs do
		local ev = evs[i]
		local t = ev.type
		local p, r, d, down = mini.pressed, mini.released, mini.double, mini.down
		p[1], p[2], p[3], r[1], r[2], r[3], d[1], d[2], d[3] = 0, 0, 0, 0, 0, 0, 0, 0, 0
		mini.wheel_x, mini.wheel_y = 0, 0
		local m = ev.mods
		mini.mods = m
		down[1], down[2], down[3] = m.b1, m.b2, m.b3
		frame_input = mini
		if t == "keydown" then
			local code = iup_key({ code = ev.code, shift = m.shift, ctrl = m.ctrl, alt = m.alt, sys = m.sys })
			if code then key_event(code) end
		elseif t == "char" then
			if ev.char then char_event(ev.char) end
		elseif t == "dismiss" then
			for n = #overlays, 1, -1 do local o = overlays[n]; if o.event and not o.sticky then o:close() end end
			if tip_overlay then overlay_windows.release(tip_overlay); tip_overlay = nil end
			hovered = nil
		elseif t == "tray" then
			local dlg = main_dialog
			-- winDialogTrayMessage: TRAYCLICK_CB(but, pressed, dclick)
			if dlg then check_close(Element.call(dlg, "TRAYCLICK_CB", ev.button or 1, (ev.pressed or (ev.dx or 0) ~= 0) and 1 or 0, ev.double and 1 or 0)) end
		elseif t ~= "keyup" and t ~= "file" then
			if t == "leave" then
				mini.inside, mini.mx, mini.my = false, -1, -1
			else
				-- (-1, -1) is "no pointer" (after a leave); a dialog window left of or above
				-- the main window reports real negative coordinates
				mini.inside, mini.mx, mini.my = not (ev.x == -1 and ev.y == -1), ev.x, ev.y
				mini.win = ev.win
			end
			if t == "press" then
				p[ev.button] = 1
				if ev.double then d[ev.button] = 1 end
			elseif t == "release" then
				r[ev.button] = 1
			elseif t == "wheel" then
				mini.wheel_x, mini.wheel_y = ev.dx, ev.dy
			end
			route(mini)
			routed_mouse = true
		end
	end
	frame_input = input
	-- No pointer event: still route once, so what is under a still pointer is re-checked
	-- (content scrolled or laid out under it).
	if not routed_mouse then route(input) end
end

function route_keys(input)
	for _, k in ipairs(input.keys or {}) do
		if k.down ~= false then
			local code = iup_key(k)
			if code then key_event(code) end
		end
	end
	for _, ch in ipairs(input.chars or {}) do char_event(ch) end
end

-- Painting --------------------------------------------------------------------------------
-- Is `target` el or inside it?
local function contains(el, target)
	local t = target
	while t do
		if t == el then return true end
		local ts = STATE[t]
		t = ts and ts.parent
	end
	return false
end

local function paint(el, d)
	local st = STATE[el]
	if not st or not own_visible(st) then return end
	if st.w <= 0 and st.h <= 0 and st.classname ~= "dialog" then return end
	local class = st.class
	local culled = not d:visible(st.x, st.y, st.w, st.h)
	if culled and class.clip then return end
	local material, material_palette = require("core.ui.Glass").material(el, st)
	-- One floating surface per window: a frame filling a floating dialog (the palette, the
	-- Activity panel, a toast) is that surface already, so it adds no second lip or rim.
	local nested = material and material.glass == "floating" and d.in_floating
	if not culled and material and not nested then
		local Glass = require("core.ui.Glass")
		local g = material.glass
		-- the rim's highlight lifts while the pointer is over the surface (eased)
		local lift = (g == "chrome" or g == "caps" or g == "floating")
			and Glass.ease(st.data, (hovered ~= nil and contains(el, hovered)) or d.overlay_hovered == true) or nil
		Glass.paint(d, st.x, st.y, st.w, st.h, g, material_palette, material.radius, el, material.lip, lift,
			st.data, material)
	end
	if not culled and class.draw then
		if st.classname == "videohost" then
			video_rects[#video_rects + 1] = { surface = d.surface_id or 0, x = st.x+d.ox, y = st.y+d.oy, w = st.w, h = st.h }
		end
		d.material, d.material_palette = material, material_palette
		local ok, err = xpcall(class.draw, debug.traceback, el, st, d, M)
		d.material, d.material_palette, d.painting_material = nil, nil, false
		if not ok then warn(err) end
	end
	local kids = children_shown(el, st)
	if #kids > 0 or class.paintChildren then
		-- Descendants of a translucent glass surface must not repaint its colour opaquely.
		local saved_under, saved_floating = d.glass_under, d.in_floating
		local g = material and material.glass
		if g == "floating" then d.in_floating = true end
		if g == "chrome" or g == "floating" or g == "floor" or g == "caps" then
			d.glass_under = Color.parse(material.bg)
		elseif g == "card" then
			d.glass_under = nil -- an opaque sheet: its children paint as usual
		end
		if class.clipRect then d:clip_push(class.clipRect(el, st))
		elseif class.clip then d:clip_push(st.x, st.y, st.w, st.h) end
		-- live glass (the Media transport) shows the nearest artwork drawn on it, extended
		-- under it: the first poster its children draw, kept for the next frame
		local saved_art = d.glass_art
		if g == "chrome" and material.live and not culled then
			st.data.glass_art_rec = st.data.glass_art_rec or {}
			d.glass_art = st.data.glass_art_rec
			d.glass_art.tex = nil
		end
		-- A class may paint its children itself (a tab strip moving two pages during a
		-- transition); it gets the shown children and the painters.
		if class.paintChildren then
			local ok, err = xpcall(class.paintChildren, debug.traceback, el, st, d, kids, M)
			if not ok then warn(err); for i = 1, #kids do paint(kids[i], d) end end
		else
			for i = 1, #kids do paint(kids[i], d) end
		end
		if d.glass_art ~= saved_art then
			local rec, used = d.glass_art, st.data.glass_art
			if rec.tex then
				if not used or used.tex ~= rec.tex or used.x ~= rec.x or used.y ~= rec.y or used.w ~= rec.w or used.h ~= rec.h then
					st.data.glass_art = { tex = rec.tex, x = rec.x, y = rec.y, w = rec.w, h = rec.h }
					need_frame = true
				end
			elseif used then
				st.data.glass_art = nil; need_frame = true
			end
			d.glass_art = saved_art
		end
		if class.clip or class.clipRect then d:clip_pop() end
		d.glass_under, d.in_floating = saved_under, saved_floating
	end
	if not culled and class.drawAfter then
		local ok, err = xpcall(class.drawAfter, debug.traceback, el, st, d, M)
		if not ok then warn(err) end
	end
end
M.paint = paint

--- Paint an element although it is not shown itself (VISIBLE=NO): a page leaving during
-- a transition is still drawn, live, until it has gone. Its own descendants' visibility
-- is honoured as usual.
function M.paintHidden(el, d)
	local st = STATE[el]
	if not st then return end
	local attrs = st.attrs
	local saved = attrs.VISIBLE
	attrs.VISIBLE = "YES"
	local ok, err = xpcall(paint, debug.traceback, el, d)
	attrs.VISIBLE = saved
	if not ok then warn(err) end
end

-- winDialogResize: a new client size reaches RESIZE_CB first, so the callback can set
-- sizes the layout then honours; IGNORE keeps the old layout.
local function layout_dialog(d, w, h)
	local st = STATE[d]
	if not Layout then Layout = require("core.imgui.Layout") end
	if st.data.lw ~= w or st.data.lh ~= h then
		st.data.lw, st.data.lh = w, h
		local r = Element.call(d, "RESIZE_CB", w, h)
		check_close(r)
		if r == IGNORE then return end
		st.data.layout_dirty = true
	end
	if st.data.layout_dirty then
		in_layout = true
		local ok, err = xpcall(Layout.run, debug.traceback, d, w, h)
		-- A dialog's first layout runs twice on IUP: IupMap/IupShow compute it, then the
		-- WM_SIZE of the new window reaches winDialogResize, whose IupRefresh computes it
		-- again with every control at its current size (a scroll box's natural size is its
		-- child's only while it has no size yet: iScrollBoxComputeNaturalSizeMethod).
		if ok and not st.data.laid_out then
			st.data.laid_out = true
			Layout.invalidate(d, true)
			ok, err = xpcall(Layout.run, debug.traceback, d, w, h)
		end
		in_layout = false
		if not ok then warn(err) end
		st.data.layout_dirty = false
	end
end

local function tooltip(d)
	if not hovered or tip_el ~= hovered then tip_el = hovered end
	if not hovered or captured then return end
	local tip = Element.getAttribute(hovered, "TIP")
	if not tip or tip == "" then return end
	if Element.getAttribute(hovered, "TIPVISIBLE") == "NO" then return end
	-- The system's initial delay, then the tip stays up for TIPDELAY ms (IUP's autopop time).
	local now = M.now()
	local shown_for = now - hover_since - M.TIP_DELAY
	if shown_for < 0 then
		animating = true -- keep frames coming until the tip is due
		return
	end
	local autopop = (tonumber(Element.getAttribute(hovered, "TIPDELAY")) or 5000) / 1000
	if shown_for > autopop then return end
	tip_shown = true
	local tip_palette = require("core.ui.ThemeReactor").palette()
	local font = Fonts.get(Element.getAttribute(hovered, "TIPFONT") or tip_palette.font or globals.TIPFONT)
	local bg = Element.getAttribute(hovered, "TIPBGCOLOR") or globals.TIPBGCOLOR or "255 255 255"
	local fg = Element.getAttribute(hovered, "TIPFGCOLOR") or globals.TIPFGCOLOR or "0 0 0"
	local border = Element.getAttribute(hovered, "TIPBORDERCOLOR") or globals.TIPBORDERCOLOR or "160 160 160"
	local tw, th = d:measure(tip, font, 400)
	local pw, ph = tw + 12, th + 8
	local x, y = last_mouse[1] + 2, last_mouse[2] + 22
	local win = main_dialog and STATE[main_dialog]
	local bx, by, W, H = 0, 0, win and win.w or 1280, win and win.h or 800
	local ws = window_of(hovered)
	if ws then bx, by, W, H = ws.data.ox or 0, ws.data.oy or 0, ws.w, ws.h end
	local o = tip_overlay or { passthrough = true }
	o.owner, o.x, o.y, o.w, o.h = hovered, x, y, pw, ph
	local id, sx, sy, sw, sh = prepare_overlay(o)
	if o.win then
		tip_overlay = o; o.seen = true
		x, y = x + (o.shift_x or 0), y + (o.shift_y or 0)
	else
		if x + pw > bx + W then x = bx + W - pw - 2 end
		if y + ph > by + H then y = last_mouse[2] - ph - 4 end
	end
	if id then d:surface(id, sx, sy, sw, sh) end
	d:layer("overlay")
	if tip_palette.glass then local Glass = require("core.ui.Glass"); Glass.paint(d,x,y,pw,ph,"floating",tip_palette,12,nil,4,nil,Glass.TIP_STATE,Glass.TIP_STYLE)
	else
		d:fill(x, y, pw, ph, bg, { radius = 4 })
		d:rect(x, y, pw, ph, border, { radius = 4 })
	end
	d:text(tip, x + 6, y + 4, tw, th, fg, font, { wrap = tw >= 400 })
	d:layer("main")
	if id then d:surface_end() end
end

--- Dim the main window's native video children too, under the modal dialog `st` (once its
-- own window exists: the first frame of a modal has none yet, and the next one covers it).
scrim_over_video = function(st, color, input)
	local under = st.data.win
	if not (under and overlay_windows.enabled) then return end
	local bounds = { 0, 0, input.w, input.h }
	for _, r in ipairs(video_rects) do
		if r.surface == 0 and r.w > 0 and r.h > 0 then
			scrim_used = scrim_used + 1
			local o = scrim_windows[scrim_used]
			if not o then o = { passthrough = true, scrim = true }; scrim_windows[scrim_used] = o end
			if o.win and o.under ~= under then overlay_windows.release(o) end
			o.under = under
			o.x, o.y, o.w, o.h = r.x, r.y, r.w, r.h
			local id, sx, sy, sw, sh = overlay_windows.prepare(o, 0, bounds, video_rects)
			if id then
				dc:surface(id, sx, sy, sw, sh)
				dc:fill(o.x + (o.shift_x or 0), o.y + (o.shift_y or 0), o.w, o.h, color)
				dc:surface_end()
			end
		end
	end
end

--- Close the scrim patches this frame did not use (the modal closed, or the video went).
local function scrim_release(from)
	for i = #scrim_windows, from, -1 do
		overlay_windows.release(scrim_windows[i])
		scrim_windows[i] = nil
	end
end

-- Chrome for dialogs drawn inside the main window (secondary dialogs): the caption band
-- IUP's frame puts above the client, the top border and the caption (iupdrvDialogGetDecoration).
local function chrome_of(d, st)
	if Element.own(d, "CUSTOMFRAME") == "YES" or Element.own(d, "HIDETITLEBAR") == "YES" then return nil end
	local dw, dh = require("core.imgui.widgets.dialog").decorSize(d)
	local caption = dh - dw
	if caption <= 0 then return nil end
	return { top = caption + dw / 2 }
end

local SHADOW_DARK, SHADOW_LIGHT = Color.pack(0, 0, 0, 26), Color.pack(0, 0, 0, 10)
local function paint_dialog_frame(d, st)
	local ch = st.data.chrome
	local bg = Element.getAttribute(d, "BGCOLOR")
	local fg = Element.getAttribute(d, "FGCOLOR")
	local x, y, w, h = st.data.ox or 0, st.data.oy or 0, st.w, st.h
	local top = ch and ch.top or 0
	-- soft shadow: on a dark surface a light one vanishes, and the window's edge then
	-- reads as a cut through whatever it covers rather than a sheet above it
	local dark = Color.isDark(Color.parse(bg) or 0)
	local shade = dark and SHADOW_DARK or SHADOW_LIGHT
	for i = 1, 6 do
		dc:fill(x - i, y - top - i + 2, w + 2 * i, h + top + 2 * i, shade, { radius = 8 + i })
	end
	dc:fill(x - 1, y - top - 1, w + 2, h + top + 2, dark and Color.pack(80, 80, 80) or Color.pack(170, 170, 170), { radius = 8 })
	dc:fill(x, y - top, w, h + top, bg, { radius = 7 })
	if ch then
		local font = Fonts.forElement(d)
		dc:text(Element.getAttribute(d, "TITLE") or "", x + 12, y - top, w - 60, top, fg, font, { valign = "center", ellipsis = true })
		local cx = w - 46
		ch.close = { x = cx }
		local hover = last_mouse[1] >= x + cx and last_mouse[1] < x + w and last_mouse[2] >= y - top and last_mouse[2] < y
		if hover then dc:fill(x + cx, y - top, 46, top, Color.pack(196, 43, 28), { radius = 7, corners = { tr = true } }) end
		local mx, my = x + cx + 23, y - top + top / 2
		local c = hover and "255 255 255" or fg
		dc:line(mx - 5, my - 5, mx + 5, my + 5, c, 1)
		dc:line(mx + 5, my - 5, mx - 5, my + 5, c, 1)
	end
end

function M.frame()
	if closed then return end
	-- No window yet (dialogs only mapped, or none shown): IupLoopStep still runs timers and
	-- messages, which step() did before calling here, but there is nothing to draw.
	if B.alive and not B.alive() then return end
	local input = B.frame_begin()
	local dpi = tonumber(input.scale) and input.scale > 0 and math.floor(96 * input.scale + 0.5)
	if dpi and dpi ~= Fonts.dpi then
		Fonts.dpi = dpi; Fonts.reset()
		for _,d in ipairs(dialogs) do
			local st = STATE[d]
			if st then st.data.layout_dirty = true; stamp(d) end
		end
	end
	frame_no = frame_no + 1
	frame_input = input
	need_frame = false
	animating = false
	cursor_override = nil

	-- Asked to end (SIGTERM, SIGINT, the session): leave every loop, now and later, as Quit
	-- Lunar does. A window close goes to CLOSE_CB instead, which may keep the app in the tray.
	if input.quit_requested and not quitting then
		info("quit requested; leaving every loop")
		quitting = true
		need_frame = true
	end
	if input.close_requested and main_dialog then
		local r = Element.call(main_dialog, "CLOSE_CB")
		if r ~= IGNORE then
			if r == CLOSE then M.exitLoop() end
			M.hide(main_dialog)
		end
	end

	sync_windows()
	local ok, err = xpcall(route_events, debug.traceback, input)
	frame_input = input
	if not ok then warn(err) end

	-- Main dialog follows the window.
	if main_dialog and STATE[main_dialog] then
		local st = STATE[main_dialog]
		st.x, st.y, st.w, st.h = 0, 0, input.w, input.h
	end

	in_paint = true
	video_rects = {}
	scrim_used = 0
	dc:begin(input.w, input.h)
	Draw.current = dc
	for _, d in ipairs(dialogs) do
		local st = STATE[d]
		if st then
			if d == main_dialog then
				layout_dialog(d, st.w, st.h)
				paint(d, dc)
				for _, fn in ipairs(M.postPaint) do
					local okp, errp = pcall(fn, dc, input)
					if not okp then warn(errp) end
				end
			else
				layout_dialog(d, st.w, st.h)
				if st.data.modal then
					-- the page under a modal dialog dims, as Lunar's scrim did
					local scrim = globals.LUNAR_SCRIMCOLOR or "0 0 0 90"
					dc:fill(0, 0, input.w, input.h, scrim)
					scrim_over_video(st, scrim, input)
				end
				if ensure_window(d, st) then
					-- its own window: Windows draws the frame and the caption
					st.data.chrome = nil
					local ox, oy = st.data.ox or 0, st.data.oy or 0
					-- A glass dialog floats: the main window's lists render under it (the
					-- backend's underlay), so its lip shows the workspace, and it fades in.
					-- A borderless one gets a margin of window round it for its shadow.
					local Glass = require("core.ui.Glass")
					local m = Glass.material(d, st)
					local glass = m and m.glass == "floating"
					local c = (glass and Element.getAttribute(d, "BORDER") == "NO") and Glass.CLEARANCE or 0
					st.data.clear = c
					B.window("popup_place", st.data.win, ox - c, oy - c, st.w + 2 * c, st.h + 2 * c, true,
						st.data.modal and true or false, Element.getAttribute(d, "TITLE") or "")
					st.data.win_shown = true
					dc:surface(st.data.win, ox - c, oy - c, st.w + 2 * c, st.h + 2 * c)
					dc:offset_push(ox, oy)
					dc:clip_push(-c, -c, st.w + 2 * c, st.h + 2 * c)
					-- the shadow margin lets clicks through to the page beneath
					local underlay = glass and c or false
					if underlay ~= (st.data.underlay or false) then
						st.data.underlay = underlay
						B.window("popup_underlay", st.data.win, glass, c)
					end
					local k = glass and Glass.entrance(st.data) or 1
					if k < 1 then dc:alpha_push(k); dc:offset_push(0, Glass.LIFT * (1 - k)) end
					local bg = Element.getAttribute(d, "BGCOLOR")
					if bg and not glass then dc:fill(0, 0, st.w, st.h, bg) end
					paint(d, dc)
					if k < 1 then dc:offset_pop(); dc:alpha_pop() end
					dc:clip_pop()
					dc:offset_pop()
					dc:surface_end()
				else
					st.data.chrome = chrome_of(d, st)
					-- A borderless glass dialog (the palette, Activity) is one glass surface with
					-- its own shadow and rim: the window frame's outline, fill and stepped shadow
					-- would draw a second, differently rounded contour round it.
					local m = require("core.ui.Glass").material(d, st)
					if not (m and m.glass == "floating" and not st.data.chrome and Element.getAttribute(d, "BORDER") == "NO") then
						paint_dialog_frame(d, st)
					end
					dc:offset_push(st.data.ox or 0, st.data.oy or 0)
					dc:clip_push(0, 0, st.w, st.h)
					paint(d, dc)
					dc:clip_pop()
					dc:offset_pop()
				end
			end
		end
	end
	for _, o in ipairs(overlays) do
		if o.draw then
			local id, x, y, w, h = prepare_overlay(o)
			if id then dc:surface(id, x, y, w, h) end
			dc:layer("overlay")
			dc:offset_push((o.dx or 0) + (o.shift_x or 0), (o.dy or 0) + (o.shift_y or 0))
			dc.overlay_hovered = o == hover_overlay
			local okd, errd = xpcall(o.draw, debug.traceback, dc, o)
			dc.overlay_hovered = false
			if not okd then warn(errd) end
			dc:offset_pop()
			dc:layer("main")
			if id then dc:surface_end() end
		end
	end
	if tip_overlay then tip_overlay.seen = false end
	tooltip(dc)
	if tip_overlay and not tip_overlay.seen then overlay_windows.release(tip_overlay); tip_overlay = nil end
	scrim_release(scrim_used + 1)
	overlay_windows.sweep()
	in_paint = false
	Draw.current = nil

	-- Cursor
	if B.cursor then
		local name = cursor_override
		if not name then
			local el = captured or hovered
			local st = el and STATE[el]
			name = st and (st.data.cursor or Element.getAttribute(el, "CURSOR")) or "ARROW"
		end
		B.cursor(M.CURSORS[name] or name)
	end
	B.frame_end()
	run_closes()
end

M.CURSORS = {
	ARROW = "ARROW", NONE = "NONE", HAND = "HAND", TEXT = "IBEAM", IBEAM = "IBEAM",
	BUSY = "WAIT", WAIT = "WAIT", CROSS = "CROSS", HELP = "ARROW", MOVE = "SIZEALL",
	RESIZE_N = "SIZENS", RESIZE_S = "SIZENS", RESIZE_NS = "SIZENS", SPLIT_V = "SIZENS",
	RESIZE_W = "SIZEWE", RESIZE_E = "SIZEWE", RESIZE_WE = "SIZEWE", SPLIT_H = "SIZEWE",
	RESIZE_NE = "SIZENESW", RESIZE_SW = "SIZENESW", RESIZE_NW = "SIZENWSE", RESIZE_SE = "SIZENWSE",
	UPARROW = "UPARROW", PEN = "CROSS", APPSTARTING = "WAIT", NO = "NO",
}

-- Setup -----------------------------------------------------------------------------------
local function preload_natives()
	local function pre(name, mod)
		-- These replace C modules that only make sense over IUP, so they win over any
		-- C preload the executable registered under the same name.
		package.loaded[name] = nil
		package.preload[name] = function() return require(mod) end
	end
	pre("iupraw", "core.imgui.native.iupraw")
	pre("sci", "core.imgui.native.sci")
	pre("themeapply", "core.imgui.native.themeapply")
	pre("winframe", "core.imgui.native.winframe")
	pre("winredraw", "core.imgui.native.winredraw")
	pre("svgicon", "core.imgui.native.svgicon")
	pre("pngimage", "core.imgui.native.pngimage")
	pre("appimages", "core.imgui.native.appimages")
	-- Direct IUP C calls through the FFI become calls on the element (see native/iupffi.lua).
	pre("core.classes.IupFFI", "core.imgui.native.iupffi")
	-- The layered-window compositor becomes draw-call replay (see native/compositor.lua).
	package.loaded.compositor = nil
	package.preload.compositor = function() return require("core.imgui.native.compositor") end
end

--- Start the runtime over a backend. Safe to call again (tests do, with a fresh Null).
function M.init(backend)
	if overlay_windows then
		for _, o in ipairs(overlays) do overlay_windows.release(o) end
		if tip_overlay then overlay_windows.release(tip_overlay) end
		scrim_release(1)
		overlay_windows.sweep(true)
	end
	scrim_windows, scrim_used = {}, 0
	B = backend
	overlay_windows = require("core.imgui.OverlayWindows").new(B, M.now, M.wakeAt)
	tip_overlay, video_rects = nil, {}
	dc = Draw.new(B)
	Fonts.backend = B
	Fonts.reset()
	Color.flush()
	if B.window then
		local scale = B.window("dpi")
		if type(scale) == "number" and scale > 0 then Fonts.dpi = 96 * scale end
	end
	iup = require("core.imgui.iup")
	dialogs, overlays, timers = {}, {}, {}
	main_dialog, hovered, captured, focused = nil, nil, nil, nil
	active_dialog = nil
	dialog_windows = B.surface ~= nil and B.dialog_windows == true and os.getenv("LUNAR_DIALOG_WINDOWS") ~= "0"
	pending_closes = {}
	loop_level, exit_levels = 0, {}
	need_frame, animating, closed, quitting = true, false, false, false
	wake_at = nil
	last_mouse = { -1, -1 }
	DRAG = nil
	M._overlay_capture = nil
	M.preRoute, M.postPaint = {}, {}
	preload_natives()
	-- A font an extension registers (ctx:registerFont) must reach the ImGui atlas too;
	-- AddFontResourceEx alone only tells GDI about it.
	local okp, platform = pcall(require, "core.platform")
	if okp and platform and platform.register_font and not platform._imgui_fonts then
		local raw = platform.register_font
		platform.register_font = function(path, ...)
			pcall(Fonts.register, path)
			return raw(path, ...)
		end
		platform._imgui_fonts = true
	end
	-- While Windows runs its modal size/move loop, the backend calls back here so the
	-- window repaints live (and timers keep running) instead of stretching a stale frame.
	if B.set_paint_callback then
		B.set_paint_callback(function()
			if closed then return end
			local ok, err = xpcall(M.step, debug.traceback, false)
			if not ok then warn(err) end
		end)
	end
	return M
end

function M.close()
	if closed then return end
	closed = true
	local roots = {}; for _,el in ipairs(dialogs) do roots[#roots+1] = el end
	for _,el in ipairs(roots) do Element.destroy(el) end
	for el in pairs(timers) do Element.destroy(el) end
	local layers = {}; for _,o in ipairs(overlays) do layers[#layers+1] = o end
	for _,o in ipairs(layers) do o:close() end
	-- Unmapped shared image handles may survive close/reopen in resource caches.
	-- Their native IDs and paint recordings cannot survive the device lifecycle.
	for _,st in pairs(STATE) do
		local d = st.data
		if d.paint then Draw.releaseRecording(d.paint.list); d.paint = nil end
		if d.tex then
			local owner = d.tex_backend or B
			if owner and owner.texture_free then owner.texture_free(d.tex) end
			d.tex, d.tex_backend = nil, nil
		end
	end
	if B then Draw.clearBitsCache(B) end
	dialogs, overlays, timers, pending_closes = {}, {}, {}, {}
	main_dialog, hovered, captured, focused, tip_el = nil, nil, nil, nil, nil
	active_dialog = nil
	frame_input, DRAG, M._overlay_capture, wake_at = nil, nil, nil, nil
	M.preRoute, M.postPaint = {}, {}
	Draw.current, dc = nil, nil
	Fonts.reset()
	if tip_overlay then overlay_windows.release(tip_overlay); tip_overlay = nil end
	overlay_windows.sweep(true)
	if B and B.close then B.close() end
end

function M.dialogs() return dialogs end
function M.mainDialog() return main_dialog end
function M.hovered() return hovered end
function M.lastMouse() return last_mouse[1], last_mouse[2] end
function M.input() return frame_input end

return M
