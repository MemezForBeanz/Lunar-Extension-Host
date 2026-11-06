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
static int grid_callbacks_ref = LUA_NOREF;
static int seek_callbacks_ref = LUA_NOREF;
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

static char *provider_value(int ref, Ihandle *ih, int row, const char *field)
{
    lua_State *L = row_state;
    size_t len;
    const char *value;
    char *buffer;
    if (!L || !callback_table(L, ref, ih)) { if (L) lua_pop(L, 1); return NULL; }
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

static char *row_value_cb(Ihandle *ih, int row, const char *field) { return provider_value(row_callbacks_ref, ih, row, field); }
static char *grid_value_cb(Ihandle *ih, int cell, const char *field) { return provider_value(grid_callbacks_ref, ih, cell, field); }

/* bits(position, width, height) -> lightuserdata, stride. The pixels stay with the provider
 * and must stay valid until the paint that asked for them returns. */
static void *provider_bits(int ref, Ihandle *ih, int pos, int w, int h, int *stride)
{
    lua_State *L = row_state;
    void *pixels = NULL;
    if (!L || !callback_table(L, ref, ih)) { if (L) lua_pop(L, 1); return NULL; }
    lua_getfield(L, -1, "bits");
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return NULL; }
    lua_pushinteger(L, pos);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    if (lua_pcall(L, 3, 2, 0) != 0) { lua_pop(L, 2); return NULL; }
    if (lua_islightuserdata(L, -2)) {
        pixels = lua_touserdata(L, -2);
        *stride = (int)lua_tointeger(L, -1);
    }
    lua_pop(L, 3);
    return pixels;
}
static void *row_bits_cb(Ihandle *ih, int row, int w, int h, int *stride) { return provider_bits(row_callbacks_ref, ih, row, w, h, stride); }
static void *grid_bits_cb(Ihandle *ih, int cell, int w, int h, int *stride) { return provider_bits(grid_callbacks_ref, ih, cell, w, h, stride); }

static int position_event(int ref, Ihandle *ih, int row, const char *part, const char *name)
{
    lua_State *L = row_state;
    if (!L || !callback_table(L, ref, ih)) { if (L) lua_pop(L, 1); return IUP_DEFAULT; }
    lua_getfield(L, -1, name);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return IUP_DEFAULT; }
    lua_pushinteger(L, row);
    lua_pushstring(L, part ? part : "");
    if (lua_pcall(L, 2, 0, 0) != 0) lua_pop(L, 1);
    lua_pop(L, 1);
    return IUP_DEFAULT;
}
static int row_event(Ihandle *ih, int row, const char *part, const char *name) { return position_event(row_callbacks_ref, ih, row, part, name); }
static int grid_event(Ihandle *ih, int cell, const char *part, const char *name) { return position_event(grid_callbacks_ref, ih, cell, part, name); }
static int row_action_cb(Ihandle *ih, int row) { return row_event(ih, row, NULL, "action"); }
static int row_part_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "part"); }
static int row_activate_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "activate"); }
static int row_context_cb(Ihandle *ih, int row, const char *part) { return row_event(ih, row, part, "context"); }
static int row_changed_cb(Ihandle *ih) { return row_event(ih, IupGetInt(ih, "VALUE"), NULL, "changed"); }
static int row_header_cb(Ihandle *ih, int column) { return row_event(ih, column, NULL, "header"); }
static int grid_action_cb(Ihandle *ih, int cell) { return grid_event(ih, cell, NULL, "action"); }
static int grid_activate_cb(Ihandle *ih, int cell, const char *part) { return grid_event(ih, cell, part, "activate"); }
static int grid_context_cb(Ihandle *ih, int cell, const char *part) { return grid_event(ih, cell, part, "context"); }
static int grid_changed_cb(Ihandle *ih) { return grid_event(ih, IupGetInt(ih, "VALUE"), NULL, "changed"); }
/* type_ahead(text) -> position to go to, 0 for nowhere, nothing to let the grid scan its titles. */
static int grid_typeahead_cb(Ihandle *ih, const char *text)
{
    lua_State *L = row_state;
    int pos = -1;
    if (!L || !callback_table(L, grid_callbacks_ref, ih)) { if (L) lua_pop(L, 1); return -1; }
    lua_getfield(L, -1, "type_ahead");
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return -1; }
    lua_pushstring(L, text);
    if (lua_pcall(L, 1, 1, 0) != 0) { lua_pop(L, 2); return -1; }
    if (lua_isnumber(L, -1)) pos = (int)lua_tointeger(L, -1);
    lua_pop(L, 2);
    return pos;
}
static int seek_event(Ihandle *ih, double value, int x, const char *name)
{
    lua_State *L = row_state;
    if (!L || !callback_table(L, seek_callbacks_ref, ih)) { if (L) lua_pop(L, 1); return IUP_DEFAULT; }
    lua_getfield(L, -1, name);
    if (lua_isfunction(L, -1)) {
        lua_pushnumber(L, value);
        lua_pushinteger(L, x);
        if (lua_pcall(L, 2, 0, 0) != 0) lua_pop(L, 1);
    } else lua_pop(L, 1);
    lua_pop(L, 1);
    return IUP_DEFAULT;
}
static int seek_seek_cb(Ihandle *ih, double value) { return seek_event(ih, value, 0, "seek"); }
static int seek_changing_cb(Ihandle *ih, double value) { return seek_event(ih, value, 0, "changing"); }
static int seek_hover_cb(Ihandle *ih, double value, int x) { return seek_event(ih, value, x, "hover"); }
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
static int l_flatgrid(lua_State *L) { iuplua_pushihandle(L, IupCreate("flatgrid")); return 1; }
static int l_flatseek(lua_State *L) { iuplua_pushihandle(L, IupCreate("flatseek")); return 1; }
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
    IupSetCallback(ih, "HEADER_CB", (Icallback)row_header_cb);
    /* Its presence is what reserves the art slot on every row. */
    lua_getfield(L, 2, "bits");
    IupSetCallback(ih, "ROWBITS_CB", lua_isfunction(L, -1) ? (Icallback)row_bits_cb : NULL);
    lua_pop(L, 1);
    return 0;
}
static int l_bindgrid(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    store_callbacks(L, &grid_callbacks_ref, ih);
    IupSetCallback(ih, "CELLVALUE_CB", (Icallback)grid_value_cb);
    IupSetCallback(ih, "CELLBITS_CB", (Icallback)grid_bits_cb);
    IupSetCallback(ih, "CELL_ACTION_CB", (Icallback)grid_action_cb);
    IupSetCallback(ih, "CELL_ACTIVATE_CB", (Icallback)grid_activate_cb);
    IupSetCallback(ih, "CELL_CONTEXT_CB", (Icallback)grid_context_cb);
    IupSetCallback(ih, "TYPEAHEAD_CB", (Icallback)grid_typeahead_cb);
    IupSetCallback(ih, "VALUECHANGED_CB", (Icallback)grid_changed_cb);
    return 0;
}
static int l_bindseek(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    store_callbacks(L, &seek_callbacks_ref, ih);
    IupSetCallback(ih, "SEEK_CB", (Icallback)seek_seek_cb);
    IupSetCallback(ih, "VALUECHANGING_CB", (Icallback)seek_changing_cb);
    IupSetCallback(ih, "HOVER_CB", (Icallback)seek_hover_cb);
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
    { "flatgrid", l_flatgrid },
    { "flatseek", l_flatseek },
    { "bindgrid", l_bindgrid },
    { "bindseek", l_bindseek },
    { "bindrows", l_bindrows },
    { "bindsegmented", l_bindsegmented },
    { NULL,  NULL  }
};

int luaopen_iupraw(lua_State *L)
{
    luaL_newlib(L, iupraw_lib);
    return 1;
}
