--- Dear ImGui's C API (cimgui) through LuaJIT's FFI, for code that wants ImGui itself.
--
-- Lunar's own UI is the IUP-compatible tree (core.imgui.Runtime); it never creates an
-- ImGui window. An extension that wants to embed real ImGui content (a debug overlay, a
-- node editor, a plot) can draw with the same context, on the same draw lists, between
-- the frame's begin and end:
--
--     local im = require("core.imgui.cimgui")
--     local ig = im.C
--     -- inside a canvas's ACTION (paint) callback:
--     local dl = im.drawList()                  -- the list Lunar is painting into
--     ig.ImDrawList_AddCircleFilled(dl, im.vec2(40, 40), 12, 0xFF00C080, 0)
--
-- Calls taking ImVec2 by value run in LuaJIT's interpreter rather than its traces; the
-- per-primitive calls Lunar itself makes go through core.imgui.backend.Native, which
-- exports scalar-only wrappers for that reason.
--
-- The declarations are generated from vendor/cimgui/cimgui.h by scripts/gen_cimgui_cdef.py,
-- with full struct layouts, and checked against the executable's own sizes on load.
--
-- @module core.imgui.cimgui
local ffi = require("ffi")

local M = {}

ffi.cdef(require("core.imgui.cimgui_cdef"))
pcall(ffi.cdef, [[
int lunar_ui_sizeof(int which);
ImDrawList *lunar_ui_draw_list(int layer);
ImFont *lunar_ui_face_font(int face);
]])

local C = ffi.C
M.C = C
M.ffi = ffi

-- A cdef that does not match the compiled ImGui would read and write the wrong fields.
local checks = { { 2, "ImGuiIO" }, { 3, "ImDrawList" }, { 4, "ImFont" }, { 5, "ImGuiStyle" } }
for _, c in ipairs(checks) do
	local native = C.lunar_ui_sizeof(c[1])
	if native ~= ffi.sizeof(c[2]) then
		error(string.format("core.imgui.cimgui: %s is %d bytes in the executable but %d in the cdef",
			c[2], native, ffi.sizeof(c[2])))
	end
end

local vec2_t = ffi.typeof("ImVec2")
local vec4_t = ffi.typeof("ImVec4")
function M.vec2(x, y) return vec2_t(x, y) end
function M.vec4(x, y, z, w) return vec4_t(x, y, z, w) end

--- The draw list Lunar is painting into: 0 the page, 1 the overlay layer (popups, tips).
function M.drawList(layer) return C.lunar_ui_draw_list(layer or 0) end

--- The ImFont behind a Lunar font (core.imgui.Fonts font objects carry `.id`).
function M.font(font) return C.lunar_ui_face_font(type(font) == "table" and font.id or font or 0) end

--- The version string of the compiled Dear ImGui.
function M.version() return ffi.string(C.igGetVersion()) end

return M
