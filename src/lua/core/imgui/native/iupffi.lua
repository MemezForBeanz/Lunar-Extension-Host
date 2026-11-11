--- `core.classes.IupFFI` on the ImGui host.
--
-- Over IUP that module calls IupGetAttribute/IupSetStrAttribute straight through the FFI
-- with a raw Ihandle*, and reads pointer attributes such as HWND. Here there is no
-- Ihandle: the "pointer" is the element itself and the calls go to the element's
-- attribute store, so the theme walk, attr.lua and the code that wants a dialog's
-- window keep working. HWND is the main window's for the main dialog (and the
-- elements in it); dialogs drawn inside the main window have none, so callers skip
-- their native step for them exactly as they do when IupFFI is unavailable.
--
-- @module core.imgui.native.iupffi
local Element = require("core.imgui.Element")

local M = { available = true, imgui = true }

local ffi_ok, ffi = pcall(require, "ffi")

function M.ptr(widget)
	if Element.is(widget) then return widget end
	return nil
end

function M.get(p, name)
	if p == nil or not Element.is(p) then return nil end
	local v = Element.getAttribute(p, name)
	if v == nil then return nil end
	return tostring(v)
end

local function main_hwnd(p)
	local Runtime = require("core.imgui.Runtime")
	local main = Runtime.mainDialog()
	if not main or Element.dialogOf(p) ~= main and p ~= main then return nil end
	local B = Runtime.backend()
	local h = B and B.window and B.window("hwnd")
	if not h or not ffi_ok then return nil end
	return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(h)))
end

-- A secondary dialog's own window (Runtime.dialogHwnd), for its controls too.
local function dialog_hwnd(p)
	local d = Element.dialogOf(p) or p
	local h = require("core.imgui.Runtime").dialogHwnd(d)
	if not h or not ffi_ok then return nil end
	return ffi.cast("void*", ffi.cast("uintptr_t", tonumber(h)))
end

function M.getptr(p, name)
	if p == nil or not Element.is(p) then return nil end
	if name == "HWND" or name == "WID" then return main_hwnd(p) or dialog_hwnd(p) end
	return nil
end

function M.setstr(p, name, value)
	if p == nil or not Element.is(p) then return end
	Element.setAttribute(p, name, value)
end

function M.clear(p, name)
	if p == nil or not Element.is(p) then return end
	Element.setAttribute(p, name, nil)
end

return M
