#include "winredraw_wrap.h"
#include <lua.h>
#include <lauxlib.h>
#include <iup.h>
#include <iuplua.h>
#include <windows.h>

/* Resolve the top-level window HWND for an IUP handle. We always lock/redraw the
 * dialog (top-level) window so a single batch covers every child control inside
 * it. LockWindowUpdate suspends drawing for the locked window AND its children,
 * so the whole theme walk repaints once on unlock instead of per-widget. */
static HWND resolve_hwnd(lua_State *L, int pos)
{
    if (!iuplua_isihandle(L, pos)) {
        return NULL;
    }
    Ihandle *ih = iuplua_checkihandle(L, pos);
    if (!ih) {
        return NULL;
    }
    Ihandle *dlg = IupGetDialog(ih);
    Ihandle *target = dlg ? dlg : ih;
    char *hwnd_str = IupGetAttribute(target, "HWND");
    if (!hwnd_str) {
        return NULL;
    }
    return (HWND)hwnd_str;
}

/*** Batch window repaints by suspending and resuming drawing.
 *
 * Wraps the Win32 `LockWindowUpdate` / `RedrawWindow` pair so that a theme
 * switch can update every widget attribute without triggering a per-widget
 * repaint. The host dialog (top-level window) is always targeted, so a
 * single `lock`/`unlock` call covers all child controls inside it.
 *
 * @module winredraw
 */

/* winredraw.lock(ihandle) -> boolean (true if painting was suspended) */
/*** Suspend painting for the top-level window containing an IUP handle.
 *
 * Resolves `ihandle` to its parent dialog's HWND and calls
 * `LockWindowUpdate`. All drawing for the window and its children is
 * deferred until `unlock` is called. Only one window can be locked
 * system-wide at a time.
 *
 * @function lock
 * @tparam  ihandle ihandle  Any IUP widget inside the dialog to lock.
 * @treturn boolean          `true` if painting was suspended; `false` if the
 *                           HWND could not be resolved.
 * @usage
 *   winredraw.lock(dlg)
 *   -- ... batch attribute changes ...
 *   winredraw.unlock(dlg)
 */
static int l_lock(lua_State *L)
{
    HWND hwnd = resolve_hwnd(L, 1);
    if (!hwnd) {
        lua_pushboolean(L, 0);
        return 1;
    }
    BOOL ok = LockWindowUpdate(hwnd);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

/* winredraw.unlock(ihandle) -> boolean
 * Releases the global window-update lock and forces one full repaint (including
 * all child controls) so the batched changes become visible at once. */
/*** Release the window-update lock and force a full repaint.
 *
 * Calls `LockWindowUpdate(NULL)` to release whatever lock is currently
 * held, then calls `RedrawWindow` on the resolved HWND with
 * `RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW` so all
 * batched attribute changes become visible at once.
 *
 * @function unlock
 * @tparam  ihandle ihandle  Any IUP widget inside the locked dialog.
 * @treturn boolean          Always `true`.
 * @usage
 *   winredraw.unlock(dlg)
 */
static int l_unlock(lua_State *L)
{
    HWND hwnd = resolve_hwnd(L, 1);

    /* LockWindowUpdate(NULL) releases whatever window is currently locked. */
    LockWindowUpdate(NULL);

    if (hwnd) {
        RedrawWindow(hwnd, NULL, NULL,
                     RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static const luaL_Reg winredraw_lib[] = {
    { "lock",   l_lock   },
    { "unlock", l_unlock },
    { NULL,     NULL     }
};

int luaopen_winredraw(lua_State *L)
{
    luaL_newlib(L, winredraw_lib);
    return 1;
}
