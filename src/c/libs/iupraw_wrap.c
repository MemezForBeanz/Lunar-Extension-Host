#include "iupraw_wrap.h"
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include <string.h>

/* The shipped iuplua archive predates Lunar's fork classes.  Keep their Lua
 * callbacks here while the controls themselves remain normal IUP handles. */
static lua_State *row_state;
static int row_callbacks_ref = LUA_NOREF;
static int segmented_callbacks_ref = LUA_NOREF;
static char row_value_buffer[16][4096];
static unsigned row_value_slot;

static int callback_table(lua_State *L, int ref, Ihandle *ih)
{
    if (ref == LUA_NOREF) return 0;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    lua_pushlightuserdata(L, ih);
    lua_rawget(L, -2);
    lua_remove(L, -2);
    return lua_istable(L, -1);
}

static char *row_value_cb(Ihandle *ih, int row, const char *field)
{
    lua_State *L = row_state;
    size_t len;
    const char *value;
    char *buffer;
    if (!L || !callback_table(L, row_callbacks_ref, ih)) { if (L) lua_pop(L, 1); return NULL; }
    lua_getfield(L, -1, "value");
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return NULL; }
    lua_pushinteger(L, row);
    lua_pushstring(L, field);
    if (lua_pcall(L, 2, 1, 0) != 0) { lua_pop(L, 2); return NULL; }
    value = lua_tolstring(L, -1, &len);
    if (value) {
        buffer = row_value_buffer[(row_value_slot++) % 16];
        if (len >= 4096) len = 4095;
        memcpy(buffer, value, len);
        buffer[len] = 0;
    }
    lua_pop(L, 2);
    return value ? buffer : NULL;
}

static int row_event(Ihandle *ih, int row, const char *part, const char *name)
{
    lua_State *L = row_state;
    if (!L || !callback_table(L, row_callbacks_ref, ih)) { if (L) lua_pop(L, 1); return IUP_DEFAULT; }
    lua_getfield(L, -1, name);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return IUP_DEFAULT; }
    lua_pushinteger(L, row);
    lua_pushstring(L, part ? part : "");
    if (lua_pcall(L, 2, 0, 0) != 0) lua_pop(L, 1);
    lua_pop(L, 1);
    return IUP_DEFAULT;
}
static int row_action_cb(Ihandle *ih, int row) { return row_event(ih, row, NULL, "action"); }
static int row_part_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "part"); }
static int row_activate_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "activate"); }
static int row_context_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "context"); }
static int row_changed_cb(Ihandle *ih) { return row_event(ih, IupGetInt(ih, "VALUE"), NULL, "changed"); }
static int segmented_changed_cb(Ihandle *ih)
{
    lua_State *L = row_state;
    if (!L || !callback_table(L, segmented_callbacks_ref, ih)) { if (L) lua_pop(L, 1); return IUP_DEFAULT; }
    lua_getfield(L, -1, "changed");
    if (lua_isfunction(L, -1)) {
        lua_pushinteger(L, IupGetInt(ih, "VALUEPOS"));
        if (lua_pcall(L, 1, 0, 0) != 0) lua_pop(L, 1);
    } else lua_pop(L, 1);
    lua_pop(L, 1);
    return IUP_DEFAULT;
}
static int store_callbacks(lua_State *L, int *ref, Ihandle *ih)
{
    if (*ref == LUA_NOREF) { lua_newtable(L); *ref = luaL_ref(L, LUA_REGISTRYINDEX); }
    lua_rawgeti(L, LUA_REGISTRYINDEX, *ref);
    lua_pushlightuserdata(L, ih);
    lua_pushvalue(L, 2);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    row_state = L;
    return 0;
}
static int l_flatrows(lua_State *L) { iuplua_pushihandle(L, IupCreate("flatrows")); return 1; }
static int l_flatsegmented(lua_State *L) { iuplua_pushihandle(L, IupCreate("flatsegmented")); return 1; }
static int l_videohost(lua_State *L) { iuplua_pushihandle(L, IupCreate("videohost")); return 1; }
static int l_bindrows(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    store_callbacks(L, &row_callbacks_ref, ih);
    IupSetCallback(ih, "ROWVALUE_CB", (Icallback)row_value_cb);
    IupSetCallback(ih, "ROW_ACTION_CB", (Icallback)row_action_cb);
    IupSetCallback(ih, "ROW_PART_CB", (Icallback)row_part_cb);
    IupSetCallback(ih, "ROW_ACTIVATE_CB", (Icallback)row_activate_cb);
    IupSetCallback(ih, "ROW_CONTEXT_CB", (Icallback)row_context_cb);
    IupSetCallback(ih, "VALUECHANGED_CB", (Icallback)row_changed_cb);
    return 0;
}
static int l_bindsegmented(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    store_callbacks(L, &segmented_callbacks_ref, ih);
    IupSetCallback(ih, "VALUECHANGED_CB", (Icallback)segmented_changed_cb);
    return 0;
}

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
    { "flatrows", l_flatrows },
    { "flatsegmented", l_flatsegmented },
    { "videohost", l_videohost },
    { "bindrows", l_bindrows },
    { "bindsegmented", l_bindsegmented },
    { NULL,  NULL  }
};

int luaopen_iupraw(lua_State *L)
{
    luaL_newlib(L, iupraw_lib);
    return 1;
}
