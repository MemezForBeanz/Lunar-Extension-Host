#ifndef IUPRAW_WRAP_H
#define IUPRAW_WRAP_H

#include <lua.h>

/* iupraw.ptr(ihandle) -> lightuserdata (the raw Ihandle*)
 *
 * Bridges an iuplua handle object to its underlying C Ihandle* so LuaJIT's FFI
 * can call IUP entry points (IupSetStrAttribute, ...) directly, bypassing the
 * per-call iuplua binding wrapper. The returned lightuserdata converts to an
 * "Ihandle*" cdata via ffi.cast. Callers must not retain the pointer past the
 * widget's lifetime.
 */
int luaopen_iupraw(lua_State *L);

#endif /* IUPRAW_WRAP_H */
