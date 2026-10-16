#ifndef LUNAR_APPIMAGES_WRAP_H
#define LUNAR_APPIMAGES_WRAP_H

#include <lua.h>

/* Registers the `appimages` module (see appimages_wrap.c). */
int luaopen_appimages(lua_State *L);

#endif /* LUNAR_APPIMAGES_WRAP_H */
