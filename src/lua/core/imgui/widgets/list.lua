local Classes = require("core.imgui.widgets.flatlist")
local Element = require("core.imgui.Element")
local base = Classes.get("flatlist")
local function own(e, n) return Element.own(e, n) end

local function list_event(e, st, ev, rt)
	local def = base
	if tostring(Element.getAttribute(e, "DROPDOWN") or "NO"):upper() == "YES" then
		if ev.type == "press" and ev.button == 1 then
			st.data.open = not st.data.open
			if st.data.open and rt.overlay then
				st.data.popup = rt.overlay({ owner = e, x = st.x, y = st.y + st.h, w = st.w, h = st.h * math.max(1, tonumber(Element.getAttribute(e, "VISIBLEITEMS")) or 5),
					draw = function(dc) def.draw(e, st, dc, rt); def.drawAfter(e, st, dc, rt) end,
					event = function(pev) local r = def.event(e, st, pev, rt); if pev.type == "release" and r then st.data.open = false end; return r end,
					closed = function() st.data.open = false end })
			end
			return true
		end
	end
	local r = def.event(e, st, ev, rt)
	if r and (ev.type == "press" or ev.type == "key") then Element.call(e, "ACTION", own(e, tostring(st.data.focus or 0)) or "", st.data.focus or 0, 1) end
	return r
end
local def = {}
for k, v in pairs(base) do def[k] = v end
def.name, def.event = "list", list_event
def.defaults = {}
for k, v in pairs(base.defaults or {}) do def.defaults[k] = v end
def.defaults.VISIBLEITEMS = "5"
def.callbacks = { ACTION = true, VALUECHANGED_CB = true, DROPDOWN_CB = true }
Classes.define(def)
return Classes
