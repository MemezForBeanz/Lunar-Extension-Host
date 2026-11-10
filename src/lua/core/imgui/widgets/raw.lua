-- The video host's virtual stand-in (the fork's flatrows, flatsegmented, flatgrid and flatseek
-- are ported in their own modules: widgets/flatrows.lua, flatsegmented.lua, flatgrid.lua,
-- flatseek.lua).
-- @module core.imgui.widgets.raw
local Classes = require("core.imgui.Classes")
local Element = require("core.imgui.Element")

local M = {}
local function attr(e, n) return Element.getAttribute(e, n) end
local function data(e, k, d) local v = Element.state(e).data[k]; return v == nil and d or v end

local function video_draw(e, st, dc, rt)
	dc:fill(st.x, st.y, st.w, st.h, attr(e, "BGCOLOR") or "0 0 0")
	local B = rt and (rt.backend or rt.B); if B and B.window then Element.state(e).data.window_id = B.window("hwnd") end
	Element.state(e).data.rect = { x = st.x, y = st.y, w = st.w, h = st.h }
end

Classes.define{ name = "videohost", children = 0, defaults = { BGCOLOR = "0 0 0" }, natural = function() return 320, 180 end, draw = video_draw, get = { WINDOWID = function(e) local v = data(e, "window_id"); return v and tostring(v) end }, methods = { windowId = function(e) local v = data(e, "window_id"); return v and tostring(v) end, rect = function(e) return data(e, "rect") end } }

return M
