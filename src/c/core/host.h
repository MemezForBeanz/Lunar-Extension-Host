#ifndef LUNAR_HOST_H
#define LUNAR_HOST_H

#include <lua.h>

typedef void (*host_preload_fn)(lua_State *, const char *, lua_CFunction);

void host_set_exe_dir_global(lua_State *L);
void host_set_exe_path_globals(lua_State *L);
void host_register_bundled_fonts(void);
void host_pre_iup_open(void);
void host_preload_modules(lua_State *L, host_preload_fn preload);

#endif
