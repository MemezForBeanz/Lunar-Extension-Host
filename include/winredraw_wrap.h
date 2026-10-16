#ifndef WINREDRAW_WRAP_H
#define WINREDRAW_WRAP_H

#include <lua.h>

/* winredraw.lock(ihandle)   -> suspend painting on the widget's top-level window
 * winredraw.unlock(ihandle) -> resume painting and force a single full repaint
 *
 * Used to batch a burst of attribute changes (theme switching, list rebuilds)
 * into one repaint instead of letting Windows progressively repaint each child
 * control as it is touched (the visible "one element at a time" ripple).
 */
int luaopen_winredraw(lua_State *L);

#endif /* WINREDRAW_WRAP_H */
