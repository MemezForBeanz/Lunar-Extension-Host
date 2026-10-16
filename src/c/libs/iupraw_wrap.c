#include "iupraw_wrap.h"
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>

/*** Expose raw IUP handle pointers to LuaJIT FFI code.
 *
 * Provides a single function that converts an `iuplua` widget handle into
 * a Lua `lightuserdata`, which LuaJIT FFI can cast to `Ihandle*` for
 * direct C API calls that are not wrapped by iuplua.
 *
 * @module iupraw
 */

/* iupraw.ptr(ih) -> lightuserdata
 *
 * Resolves the iuplua handle at stack position 1 to its raw Ihandle* and returns
 * it as a Lua lightuserdata. LuaJIT FFI converts a lightuserdata to a pointer
 * cdata, so Lua code can do:
 *
 *     local p = ffi.cast("Ihandle*", iupraw.ptr(widget))
 *     C.IupSetStrAttribute(p, "BGCOLOR", "32 32 32")
 *
 * Returns nil if the argument is not a valid iuplua handle.
 */
/*** Return the raw `Ihandle*` pointer for an IUP widget as `lightuserdata`.
 *
 * LuaJIT FFI converts `lightuserdata` to a pointer cdata automatically,
 * so the returned value can be passed directly to `ffi.cast`.
 *
 * @function ptr
 * @tparam  ihandle ih     An IUP widget handle.
 * @treturn lightuserdata  The underlying `Ihandle*` as `lightuserdata`.
 * @treturn nil            If `ih` is not a valid iuplua handle.
 * @usage
 *   local p = ffi.cast("Ihandle*", iupraw.ptr(widget))
 *   C.IupSetStrAttribute(p, "BGCOLOR", "32 32 32")
 */
static int l_ptr(lua_State *L)
{
    if (!iuplua_isihandle(L, 1)) {
        lua_pushnil(L);
        return 1;
    }
    Ihandle *ih = iuplua_checkihandle(L, 1);
    if (!ih) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlightuserdata(L, (void *)ih);
    return 1;
}

static const luaL_Reg iupraw_lib[] = {
    { "ptr", l_ptr },
    { NULL,  NULL  }
};

int luaopen_iupraw(lua_State *L)
{
    luaL_newlib(L, iupraw_lib);
    return 1;
}
