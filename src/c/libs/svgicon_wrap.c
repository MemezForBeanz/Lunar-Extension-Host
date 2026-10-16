#include "svgicon_wrap.h"
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include <stdint.h>

/* Implementations live in nanosvg_impl.c; only the declarations are needed
 * here for sizeof() and the paint-order/fill-rule enum values are not
 * required by this file. */
#include "nanosvg.h"
#include "nanosvgrast.h"

/*** Wrap NanoSVG rasterised pixels as IUP image handles.
 *
 * Bridges the LuaJIT FFI-level NanoSVG rasteriser (which writes into a raw
 * RGBA buffer) and the IUP image API. Also exposes the C-side `sizeof` of
 * every NanoSVG struct that the Lua FFI layer cdefs, so an ABI mismatch
 * fails loudly at load time instead of silently corrupting memory.
 *
 * @module svgicon
 */

/* svgicon.to_image(addr, w, h) -> image_handle
 *
 * addr is the RGBA pixel buffer's address, passed as a plain Lua number (see
 * svgicon_wrap.h for why -- NOT a raw cdata argument). Wraps it with
 * IupImageRGBA and returns a ready-to-use iuplua image object, exactly as if
 * it had been produced by iup.LoadImage. On failure returns (nil, reason).
 */
/*** Wrap a raw RGBA pixel buffer as an IUP image handle.
 *
 * `addr` is the buffer's address expressed as a plain Lua number — use
 * `tonumber(ffi.cast("uintptr_t", ptr))` to convert a cdata pointer.
 * The buffer must be at least `w * h * 4` bytes and must remain valid for
 * the lifetime of the returned image handle.
 *
 * @function to_image
 * @tparam  number  addr  Address of the RGBA pixel buffer (as a Lua number).
 * @tparam  integer w     Image width in pixels (must be > 0).
 * @tparam  integer h     Image height in pixels (must be > 0).
 * @treturn ihandle       Ready-to-use IUP image handle on success.
 * @treturn nil           `nil` on failure.
 * @treturn string        Error message on failure.
 * @usage
 *   local addr = tonumber(ffi.cast("uintptr_t", pixels))
 *   local img, err = svgicon.to_image(addr, 32, 32)
 *   if img then iup.SetAttributeHandle(btn, "IMAGE", img) end
 */
static int l_to_image(lua_State *L)
{
    lua_Number addr = luaL_checknumber(L, 1);
    int w = (int)luaL_checkinteger(L, 2);
    int h = (int)luaL_checkinteger(L, 3);

    if (w <= 0 || h <= 0) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid width/height");
        return 2;
    }
    if (addr == 0) {
        lua_pushnil(L);
        lua_pushstring(L, "null pixel buffer address");
        return 2;
    }

    const unsigned char *pixels = (const unsigned char *)(uintptr_t)addr;
    Ihandle *img = IupImageRGBA(w, h, pixels);
    if (!img) {
        lua_pushnil(L);
        lua_pushstring(L, "IupImageRGBA failed");
        return 2;
    }

    iuplua_pushihandle(L, img);
    return 1;
}

/* svgicon.sizeofs() -> table
 *
 * C sizeof() of every NSVG struct the Lua side reads/writes fields of
 * directly through FFI, keyed by struct name. core.ui.VectorIcon compares
 * these against ffi.sizeof(...) for its own cdef of the same structs at
 * load time, so a NanoSVG version/ABI mismatch fails loudly (falls back to
 * `available = false`) instead of silently corrupting memory.
 */
/*** Return C `sizeof` values for the NanoSVG structs used by FFI.
 *
 * Returns a table mapping each NanoSVG struct name to its size in bytes as
 * compiled into this module. The Lua FFI layer compares these against
 * `ffi.sizeof(...)` for its own `cdef` of the same structs at load time;
 * a mismatch triggers a graceful fallback (`available = false`) rather than
 * silent memory corruption.
 *
 * Keys present: `NSVGimage`, `NSVGshape`, `NSVGpath`, `NSVGpaint`,
 * `NSVGgradient`, `NSVGgradientStop`.
 *
 * @function sizeofs
 * @treturn table  `{ [struct_name] = integer, ... }` size-in-bytes table.
 * @usage
 *   local sizes = svgicon.sizeofs()
 *   assert(sizes.NSVGimage == ffi.sizeof("NSVGimage"))
 */
static int l_sizeofs(lua_State *L)
{
    lua_newtable(L);

#define PUSH_SIZEOF(name) \
    lua_pushinteger(L, (lua_Integer)sizeof(name)); \
    lua_setfield(L, -2, #name)

    PUSH_SIZEOF(NSVGimage);
    PUSH_SIZEOF(NSVGshape);
    PUSH_SIZEOF(NSVGpath);
    PUSH_SIZEOF(NSVGpaint);
    PUSH_SIZEOF(NSVGgradient);
    PUSH_SIZEOF(NSVGgradientStop);

#undef PUSH_SIZEOF

    return 1;
}

static const luaL_Reg svgicon_lib[] = {
    { "to_image", l_to_image },
    { "sizeofs",  l_sizeofs  },
    { NULL,       NULL       }
};

int luaopen_svgicon(lua_State *L)
{
    luaL_newlib(L, svgicon_lib);
    return 1;
}
