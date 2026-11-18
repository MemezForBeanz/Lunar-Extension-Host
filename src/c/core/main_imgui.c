/* The GUI entry point of the Dear ImGui build.
 *
 * The same program as main.c, with IUP taken out: the `iup` global is the Lua
 * emulator (core.imgui.iup) and core.imgui.Runtime runs it over the native ImGui
 * backend (src/cpp/lunarimgui.cpp). Everything else is unchanged: the service mode,
 * the preloaded C modules, LUNAR_DEV_BUILD, and a .lua path on the command line
 * running in place of the embedded application, in exactly the environment the
 * application gets.
 */
#ifdef _WIN32
#include <windows.h>
#endif
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "host.h"
#include "lua_bundle.h"

int luaopen_lfs(lua_State *L);
int luaopen_cjson(lua_State *L);
int luaopen_socket_core(lua_State *L);
int luaopen_mime_core(lua_State *L);
int luaopen_file_stream(lua_State *L);
int luaopen_logscan(lua_State *L);
int luaopen_compositor(lua_State *L);
int luaopen_media_native(lua_State *L);
int luaopen_lunarimgui(lua_State *L);
int luaopen_imagecodec(lua_State *L);
int luaopen_svgicon_sizes(lua_State *L);
int luaopen_ssl_core(lua_State *L);
int luaopen_ssl_context(lua_State *L);
int luaopen_ssl_x509(lua_State *L);
int luaopen_ssl_config(lua_State *L);

/* host.c preloads these by name; on this build core.imgui.Runtime replaces both with
 * Lua modules (core.imgui.native.winredraw / winframe), so the C side is empty. */
int luaopen_winredraw(lua_State *L) { lua_newtable(L); return 1; }
int luaopen_winframe(lua_State *L) { lua_newtable(L); return 1; }

static void preload(lua_State *L, const char *name, lua_CFunction fn)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, fn);
    lua_setfield(L, -2, name);
    lua_pop(L, 2);
}

static void fatal(const char *msg)
{
#ifdef _WIN32
    int n = MultiByteToWideChar(CP_UTF8, 0, msg, -1, NULL, 0);
    wchar_t *w = (wchar_t *)malloc((size_t)(n > 0 ? n : 1) * sizeof(wchar_t));
    if (!w) return;
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, msg, -1, w, n); else w[0] = 0;
    MessageBoxW(NULL, w, L"Lunar Extension Host - Fatal Error", MB_OK | MB_ICONERROR);
    free(w);
#else
    fprintf(stderr, "Lunar: %s\n", msg ? msg : "unknown error");
#endif
}

static int has_lua_suffix(const char *path)
{
    size_t n = path ? strlen(path) : 0;
    if (n < 4) return 0;
    const char *ext = path + (n - 4);
    return ext[0] == '.' && (ext[1] == 'l' || ext[1] == 'L') && (ext[2] == 'u' || ext[2] == 'U')
        && (ext[3] == 'a' || ext[3] == 'A');
}

static void push_arg_table(lua_State *L, int argc, char **argv)
{
    lua_newtable(L);
    for (int i = 1; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");
}

static void preload_common(lua_State *L)
{
    preload(L, "lfs",          luaopen_lfs);
    preload(L, "cjson",        luaopen_cjson);
    preload(L, "socket.core",  luaopen_socket_core);
    preload(L, "mime.core",    luaopen_mime_core);
    host_preload_modules(L, preload);
    preload(L, "file_stream",  luaopen_file_stream);
    preload(L, "logscan",      luaopen_logscan);
    preload(L, "compositor",   luaopen_compositor);
    preload(L, "ssl.core",     luaopen_ssl_core);
    preload(L, "ssl.context",  luaopen_ssl_context);
    preload(L, "ssl.x509",     luaopen_ssl_x509);
    preload(L, "ssl.config",   luaopen_ssl_config);
}

/* `Lunar --service <command>`: no window, no UI at all. */
static int run_service(int argc, char **argv)
{
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    host_set_exe_dir_global(L);
    host_set_exe_path_globals(L);
    preload_common(L);
    preload_lua_modules(L);
    int code = 1;
    lua_getglobal(L, "require");
    lua_pushstring(L, "core.lib.Service");
    if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        lua_getfield(L, -1, "main");
        lua_newtable(L);
        for (int i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 1);
        }
        if (lua_pcall(L, 1, 1, 0) == LUA_OK && lua_isnumber(L, -1)) code = (int)lua_tointeger(L, -1);
    }
    lua_close(L);
    return code;
}

/* iup = require("core.imgui.iup"); require("core.imgui.Runtime").init(Native) */
static const char *BOOT =
    "local iup = require('core.imgui.iup')\n"
    "_G.iup = iup\n"
    "package.loaded.iup = iup\n"
    "require('core.imgui.Runtime').init(require('core.imgui.backend.Native'))\n";

static int traceback(lua_State *L)
{
    const char *msg = lua_tostring(L, 1);
    luaL_traceback(L, L, msg ? msg : "(error object is not a string)", 1);
    return 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && argv[1] && strcmp(argv[1], "--service") == 0) return run_service(argc, argv);

    /* The fonts bundled under assets/Themes (IBM Plex) are private to this process, as
     * main.c makes them for the IUP build: GDI measures and draws text, and without them
     * it substitutes another face with other metrics. */
    host_register_bundled_fonts();

    lua_State *L = luaL_newstate();
    if (!L) { fatal("Failed to create Lua VM."); return 1; }
    luaL_openlibs(L);
    /* The Lua-owned UI allocates more temporary draw/layout state than IUP's
     * native widgets. Start incremental GC sooner instead of growing to twice
     * the live heap. No forced collections or working-set trimming. */
    int gc_pause = 120;
    const char *gc_env = getenv("LUNAR_GC_PAUSE");
    if (gc_env && *gc_env) {
        char *end = NULL; long parsed = strtol(gc_env, &end, 10);
        if (end && !*end && parsed >= 100 && parsed <= 400) gc_pause = (int)parsed;
    }
    lua_gc(L, LUA_GCSETPAUSE, gc_pause);
    lua_pushinteger(L, gc_pause); lua_setglobal(L, "LUNAR_GC_PAUSE");
    host_set_exe_dir_global(L);
    host_set_exe_path_globals(L);
#ifdef LUNAR_DEV_BUILD
    lua_pushboolean(L, 1);
#else
    lua_pushboolean(L, 0);
#endif
    lua_setglobal(L, "LUNAR_DEV_BUILD");
#ifdef LUNAR_SOURCE_DIR
    lua_pushstring(L, LUNAR_SOURCE_DIR);
    lua_setglobal(L, "LUNAR_SOURCE_DIR");
#endif
    lua_pushboolean(L, 1);
    lua_setglobal(L, "LUNAR_IMGUI");

    preload_common(L);
    preload(L, "media_native",  luaopen_media_native);
    preload(L, "lunarimgui",    luaopen_lunarimgui);
    preload(L, "imagecodec",    luaopen_imagecodec);
    preload(L, "svgicon_sizes", luaopen_svgicon_sizes);
    preload_lua_modules(L);

    lua_pushcfunction(L, traceback);
    int handler = lua_gettop(L);
    int status = luaL_loadbuffer(L, BOOT, strlen(BOOT), "=imgui-boot");
    if (status == LUA_OK) status = lua_pcall(L, 0, 0, handler);
    if (status == LUA_OK) {
        if (argc > 1 && argv[1] && has_lua_suffix(argv[1])) {
            push_arg_table(L, argc, argv);
            status = luaL_loadfile(L, argv[1]);
        } else {
            status = luaL_loadbuffer(L, LUA_MAIN_SCRIPT, strlen(LUA_MAIN_SCRIPT), "=main.lua");
        }
        if (status == LUA_OK) status = lua_pcall(L, 0, 0, handler);
    }
    if (status != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        FILE *f = fopen("lunar-imgui-error.log", "wb");
        if (f) { fputs(err ? err : "(unknown Lua error)", f); fclose(f); }
        if (!getenv("LUNAR_CAPTURE_CLIENT")) fatal(err ? err : "(unknown Lua error)");
    }
    /* Close the window before the Lua state: its textures belong to the GL context. */
    lua_getglobal(L, "require");
    lua_pushstring(L, "core.imgui.Runtime");
    if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        lua_getfield(L, -1, "close");
        if (lua_isfunction(L, -1)) lua_pcall(L, 0, 0, 0);
    }
    lua_close(L);
    return status == LUA_OK ? 0 : 1;
}

#ifdef _WIN32
int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR cmd, int show)
{
    (void)h; (void)p; (void)cmd; (void)show;
    return main(__argc, __argv);
}
#endif
