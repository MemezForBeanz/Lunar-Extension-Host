#include <lua.h>
#include <lauxlib.h>
#include "nanosvg.h"
#include "nanosvgrast.h"
static int sizes(lua_State *L) {
    lua_newtable(L);
#define S(x) lua_pushinteger(L, (lua_Integer)sizeof(x)); lua_setfield(L, -2, #x)
    S(NSVGimage); S(NSVGshape); S(NSVGpath); S(NSVGpaint); S(NSVGgradient); S(NSVGgradientStop);
#undef S
    return 1;
}
int luaopen_svgicon_sizes(lua_State *L) {
    luaL_Reg r[] = {{"sizeofs", sizes}, {NULL, NULL}};
    luaL_newlib(L, r); return 1;
}
