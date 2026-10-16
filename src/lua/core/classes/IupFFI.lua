--- Direct LuaJIT FFI access to IUP's attribute entry points.
--
-- The `iuplua` binding routes every `iup.SetAttribute`/`GetAttribute` through a
-- Lua C function that re-validates the handle, looks the attribute up by name, and
-- copies strings. For the theme walk — thousands of single-attribute reads and
-- writes across the whole widget tree — that wrapper overhead dominates. This
-- module lets the hot path call the C IUP functions directly via the FFI, using
-- the raw `Ihandle*` obtained once from `iupraw.ptr`.
--
-- The host executable exports all symbols (`-Wl,--export-all-symbols`), so the
-- IUP functions linked into the exe resolve through `ffi.C` at runtime. If
-- LuaJIT/FFI or `iupraw` is unavailable, or the symbols don't resolve, `available`
-- stays `false` and callers fall back to the normal `iup.*` path.
--
-- Not covered by the busted suite: `iupraw` and the IUP symbols only exist
-- inside the host executable, so `available` is always `false` under the test
-- runner even though it runs on LuaJIT. This module is exercised by the GUI
-- integration harnesses (scripts\*_check.lua) instead.
--
-- @module core.classes.IupFFI
local M = { available = false }

local ok_ffi, ffi = pcall(require, "ffi")
local ok_raw, iupraw = pcall(require, "iupraw")
if not (ok_ffi and ffi and ok_raw and iupraw) then
	return M
end

-- cdef is per-Lua-state and errors if a type/symbol is redeclared. require caches
-- this module so it normally runs once; pcall keeps a stray re-require harmless.
pcall(ffi.cdef, [[
	typedef struct Ihandle_ Ihandle;
	char* IupGetAttribute(Ihandle* ih, const char* name);
	void  IupSetStrAttribute(Ihandle* ih, const char* name, const char* value);
	void  IupSetAttribute(Ihandle* ih, const char* name, const char* value);
]])

local C = ffi.C

-- Indexing ffi.C.<name> resolves the symbol immediately and raises if it is not
-- exported, so this probe confirms the host actually exposes the IUP entry points.
local ok_sym = pcall(function()
	local _ = C.IupGetAttribute
	local _ = C.IupSetStrAttribute
	local _ = C.IupSetAttribute
end)
if not ok_sym then
	return M
end

local IH = ffi.typeof("Ihandle*")
local VOIDP = ffi.typeof("void*")
local cast = ffi.cast
local ffistring = ffi.string

--- Resolve an `iuplua` widget handle to a raw `Ihandle*` cdata pointer (or `nil`).
-- The pointer is only valid while the widget is alive; the theme walk resolves it
-- fresh per node.
-- @tparam ihandle widget An `iuplua` widget handle.
-- @treturn cdata|nil Raw `Ihandle*` pointer, or `nil` if the handle could not be resolved.
function M.ptr(widget)
	local lud = iupraw.ptr(widget)
	if not lud then
		return nil
	end
	return cast(IH, lud)
end

--- Read an IUP attribute from a raw `Ihandle*` pointer via `IupGetAttribute`.
-- Returns `nil` if `p` is `nil` or the attribute is unset.
-- @tparam cdata p Raw `Ihandle*` pointer from `M.ptr()`.
-- @tparam string name IUP attribute name (e.g. `"BGCOLOR"`).
-- @treturn string|nil The attribute value, or `nil` if unset.
function M.get(p, name)
	if p == nil then
		return nil
	end
	local v = C.IupGetAttribute(p, name)
	if v == nil then
		return nil
	end
	return ffistring(v)
end

--- Read a POINTER-valued IUP attribute from a raw `Ihandle*` as a `void*` cdata.
--
-- IUP registers some attributes with `IUPAF_NO_STRING`, meaning the stored value
-- is a raw pointer rather than text -- `HDC_WMPAINT` on a canvas (the device
-- context live during `WM_PAINT`) is the one this app needs. `M.get` would hand
-- such a value to `ffi.string` and either truncate it at the first zero byte or
-- read wildly out of bounds, so pointer attributes must come through here.
--
-- @tparam cdata p Raw `Ihandle*` pointer from `M.ptr()`.
-- @tparam string name IUP attribute name registered as `IUPAF_NO_STRING`.
-- @treturn cdata|nil The value as `void*`, or `nil` if unset.
-- @usage local hdc = IupFFI.getptr(IupFFI.ptr(canvas), "HDC_WMPAINT")
function M.getptr(p, name)
	if p == nil then
		return nil
	end
	local v = C.IupGetAttribute(p, name)
	if v == nil then
		return nil
	end
	return cast(VOIDP, v)
end

--- Set an IUP string attribute on a raw `Ihandle*` pointer via `IupSetStrAttribute`.
-- No-op if `p` is `nil`.
-- @tparam cdata p Raw `Ihandle*` pointer from `M.ptr()`.
-- @tparam string name IUP attribute name.
-- @tparam string value String value to set.
function M.setstr(p, name, value)
	if p == nil then
		return
	end
	C.IupSetStrAttribute(p, name, value)
end

--- Clear an IUP attribute on a raw `Ihandle*` pointer via `IupSetAttribute(p, name, NULL)`.
-- No-op if `p` is `nil`.
-- @tparam cdata p Raw `Ihandle*` pointer from `M.ptr()`.
-- @tparam string name IUP attribute name to clear.
function M.clear(p, name)
	if p == nil then
		return
	end
	C.IupSetAttribute(p, name, nil)
end

M.available = true
M.C = C
return M
