#include "themeapply_wrap.h"
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>

/*** Batch-apply and restore IUP widget attributes in a single C crossing.
 *
 * Reduces the Lua→C call overhead of a full theme switch by iterating
 * the attribute table in C and skipping writes when the value is already
 * current (avoiding the synchronous natural-size re-measure that IUP
 * performs on every `SetAttribute` call).
 *
 * @module themeapply
 */

/* originals = themeapply.apply_save(ih, attrs)
 *
 * attrs: { ATTRNAME = "value", ... } (string/number values).
 * Captures each attribute's current value, then applies the new one, in a
 * single Lua->C crossing. Returns { ATTRNAME = original_or_false, ... }.
 */
/*** Apply a set of IUP attributes and return the previous values.
 *
 * Iterates `attrs` (a string-keyed table), captures each attribute's current
 * value on `ih`, then sets the new value. Writes are skipped when the new
 * value is identical to the current one to avoid unnecessary IUP geometry
 * re-measures.
 *
 * The returned originals table mirrors `attrs` in shape:
 *
 * - **`string`** — the attribute's value before the call.
 * - **`false`** — the attribute was not set before the call.
 *
 * Pass `originals` to `restore` to undo the changes.
 *
 * @function apply_save
 * @tparam  ihandle ih     IUP widget handle.
 * @tparam  table   attrs  `{ ATTRNAME = "new_value", ... }` (string values).
 * @treturn table          Originals table `{ ATTRNAME = string|false, ... }`.
 * @usage
 *   local saved = themeapply.apply_save(dlg, { BGCOLOR = "32 32 32", FGCOLOR = "255 255 255" })
 *   -- ... do work ...
 *   themeapply.restore(dlg, saved)
 */
static int l_apply_save(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    /* originals result table */
    lua_newtable(L);
    int originals = lua_gettop(L);

    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
        /* key at -2, value at -1 */
        if (lua_type(L, -2) == LUA_TSTRING) {
            const char *name = lua_tostring(L, -2);

            /* Capture the original BEFORE overwriting. IupGetAttribute returns a
             * pointer into IUP-owned storage, so copy it into Lua immediately. */
            char *orig = IupGetAttribute(ih, name);
            lua_pushvalue(L, -2);            /* key copy */
            if (orig) {
                lua_pushstring(L, orig);
            } else {
                lua_pushboolean(L, 0);       /* unset -> false */
            }
            lua_settable(L, originals);      /* originals[name] = orig or false */

            /* Apply the new value only when it differs from the current one.
             * Skipping identical writes avoids the synchronous natural-size
             * re-measure IUP performs on every SetAttribute call -- the dominant
             * cost of a theme switch when geometry/font attributes are involved. */
            const char *value = lua_tostring(L, -1);
            if (value && !(orig && strcmp(orig, value) == 0)) {
                IupSetStrAttribute(ih, name, value);
            }
        }
        lua_pop(L, 1);                       /* pop value, keep key */
    }

    lua_settop(L, originals);
    return 1;
}

/* themeapply.restore(ih, originals)
 *
 * Re-applies captured originals: string values are set; false entries (the
 * attribute was unset when captured) are cleared with IupSetAttribute(NULL).
 */
/*** Restore IUP attributes to previously captured original values.
 *
 * Iterates `originals` (as returned by `apply_save`) and re-applies each
 * entry:
 *
 * - **string** values are set with `IupSetStrAttribute`.
 * - **`false`** values clear the attribute with `IupSetAttribute(NULL)`.
 *
 * Writes are skipped when the attribute already holds the target value.
 *
 * @function restore
 * @tparam ihandle ih        IUP widget handle.
 * @tparam table   originals Originals table returned by `apply_save`.
 * @usage
 *   themeapply.restore(dlg, saved)
 */
static int l_restore(lua_State *L)
{
    Ihandle *ih = iuplua_checkihandle(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            const char *name = lua_tostring(L, -2);
            if (lua_type(L, -1) == LUA_TSTRING) {
                const char *value = lua_tostring(L, -1);
                /* Skip the write if the attribute already holds the target value. */
                char *cur = IupGetAttribute(ih, name);
                if (!cur || strcmp(cur, value) != 0) {
                    IupSetStrAttribute(ih, name, value);
                }
            } else {
                /* false -> clear; skip if already unset. */
                if (IupGetAttribute(ih, name) != NULL) {
                    IupSetAttribute(ih, name, NULL);
                }
            }
        }
        lua_pop(L, 1);
    }
    return 0;
}

static const luaL_Reg themeapply_lib[] = {
    { "apply_save", l_apply_save },
    { "restore",    l_restore    },
    { NULL,         NULL         }
};

int luaopen_themeapply(lua_State *L)
{
    luaL_newlib(L, themeapply_lib);
    return 1;
}
