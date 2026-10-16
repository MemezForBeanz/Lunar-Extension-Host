#ifndef SVGICON_WRAP_H
#define SVGICON_WRAP_H

#include <lua.h>

/* svgicon -- the minimal C glue the core.ui.VectorIcon Lua module needs on top
 * of NanoSVG (vendor/nanosvg). Everything else -- parsing, walking shapes,
 * mutating fill colors, rasterizing -- is done directly from Lua via LuaJIT's
 * FFI calling straight into the nsvg / NSVG symbols exported by the host exe
 * (see nanosvg_impl.c). Only two things genuinely require the plain Lua/C API
 * (i.e. access to lua_State*), so that's all this module provides:
 *
 *   svgicon.to_image(addr, w, h) -> iuplua image handle (or nil, "reason")
 *       Wraps an already-rasterized RGBA pixel buffer as an IUP image via
 *       IupImageRGBA + iuplua_pushihandle. addr is the buffer's address
 *       encoded as a plain Lua number, NOT a raw FFI cdata argument --
 *       LuaJIT's lua_topointer() gives the wrong address for pointer-typed
 *       cdata (it returns where the pointer is stored, not what it points
 *       to; only array/aggregate cdata behave as expected). Passing the
 *       address as tonumber(ffi.cast("intptr_t", ptr)) sidesteps that
 *       ambiguity entirely and works uniformly for both array and pointer
 *       cdata. See VectorIcon.lua for the Lua-side helper that does this.
 *
 *   svgicon.sizeofs() -> table of C sizeof() for the NSVG structs
 *       Lets the Lua FFI cdef self-validate its struct layout against what
 *       this build of NanoSVG actually compiled to, at module load time,
 *       instead of silently corrupting memory on a mismatch.
 */
int luaopen_svgicon(lua_State *L);

#endif /* SVGICON_WRAP_H */
