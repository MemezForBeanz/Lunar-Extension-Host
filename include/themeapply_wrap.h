#ifndef THEMEAPPLY_WRAP_H
#define THEMEAPPLY_WRAP_H

#include <lua.h>

/* Native batch theming helper.
 *
 * Collapses a per-widget burst of save+set (and later restore) attribute
 * operations into a single Lua->C crossing, instead of ~10-25 individual
 * iup.SetAttribute round-trips per node from Lua.
 *
 *   originals = themeapply.apply_save(ih, attrs)
 *       For each name=value in attrs (string values): capture the widget's
 *       current value, then apply the new value. Returns a table mapping each
 *       name to its captured original (string, or false if it was unset).
 *
 *   themeapply.restore(ih, originals)
 *       Re-apply captured originals: string values are set, false entries are
 *       cleared (IupSetAttribute(ih, name, NULL)).
 */
int luaopen_themeapply(lua_State *L);

#endif /* THEMEAPPLY_WRAP_H */
