#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>
#include <stdlib.h>
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"

static int png_rgba(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    FILE *f = fopen(path, "rb"); if (!f) { lua_pushnil(L); lua_pushstring(L, "cannot open PNG"); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0 || n > 16 * 1024 * 1024) { fclose(f); lua_pushnil(L); lua_pushstring(L, "invalid PNG size"); return 2; }
    unsigned char *data = (unsigned char *)malloc((size_t)n);
    if (!data || fread(data, 1, (size_t)n, f) != (size_t)n) { free(data); fclose(f); lua_pushnil(L); lua_pushstring(L, "cannot read PNG"); return 2; }
    fclose(f); int w, h, c; unsigned char *px = stbi_load_from_memory(data, (int)n, &w, &h, &c, 4); free(data);
    if (!px) { lua_pushnil(L); lua_pushstring(L, "PNG decode failed"); return 2; }
    lua_pushlstring(L, (const char *)px, (size_t)w * h * 4); lua_pushinteger(L, w); lua_pushinteger(L, h); stbi_image_free(px); return 3;
}
int luaopen_imagecodec(lua_State *L) {
    luaL_Reg r[] = {{"png_rgba", png_rgba}, {NULL, NULL}}; luaL_newlib(L, r); return 1;
}
