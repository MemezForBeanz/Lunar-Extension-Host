#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <iup.h>
#include <iuplua.h>
#include <windows.h>
#include <string.h>
#include <stdio.h>

/* Forward declarations for our custom modules */
int luaopen_lfs(lua_State *L);
int luaopen_cjson(lua_State *L);
int luaopen_socket_core(lua_State *L);
int luaopen_mime_core(lua_State *L);
int luaopen_subprocess(lua_State *L);
int luaopen_process(lua_State *L);
int luaopen_logscan(lua_State *L);
int luaopen_winredraw(lua_State *L);
int luaopen_iupraw(lua_State *L);
int luaopen_themeapply(lua_State *L);
int luaopen_svgicon(lua_State *L);
int luaopen_appimages(lua_State *L);

/* LuaSec C core (statically linked TLS transport). Registered so require("ssl")
 * and require("ssl.https") resolve for https:// backends. */
int luaopen_ssl_core(lua_State *L);
int luaopen_ssl_context(lua_State *L);
int luaopen_ssl_x509(lua_State *L);
int luaopen_ssl_config(lua_State *L);

#include "lua_bundle.h"  /* defines LUA_MAIN_SCRIPT */

/* Register a C module as a preloaded Lua package */
static void preload(lua_State *L, const char *name, lua_CFunction fn)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, fn);
    lua_setfield(L, -2, name);
    lua_pop(L, 2);
}

/* Show an error message (safe with WIN32/no-console subsystem) */
static void fatal(const char *msg)
{
    IupMessage("Lunar Extension Host - Fatal Error", msg);
}

/* Set the global LUNAR_EXE_DIR to the directory containing this executable.
 * This is stable regardless of the process working directory, so Lua can
 * resolve plugins/ and other bundled resources reliably. */
static void set_exe_dir_global(lua_State *L)
{
    char exe_path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        lua_pushstring(L, "");
    } else {
        char *last_sep = strrchr(exe_path, '\\');
        if (last_sep) *last_sep = '\0';
        lua_pushstring(L, exe_path);
    }
    lua_setglobal(L, "LUNAR_EXE_DIR");
}

/* Set the global LUNAR_EXE_PATH to the full path of this executable and LUNAR_PID to
 * this process id. These let the Lua updater relaunch the app after installing
 * an update and wait for this process to exit before touching locked files. */
static void set_exe_path_globals(lua_State *L)
{
    char exe_path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        lua_pushstring(L, "");
    } else {
        lua_pushstring(L, exe_path);
    }
    lua_setglobal(L, "LUNAR_EXE_PATH");

    lua_pushinteger(L, (lua_Integer)GetCurrentProcessId());
    lua_setglobal(L, "LUNAR_PID");
}

/* Register bundled custom fonts with the OS for this process only, scanning the
 * theme asset tree: assets\\Themes\\<Theme Name>\\... . This supports per-theme fonts
 * without hardcoding file names. */
static int has_font_extension(const char *filename)
{
    const char *ext = strrchr(filename, '.');
    if (!ext) return 0;
    return _stricmp(ext, ".otf") == 0 ||
           _stricmp(ext, ".ttf") == 0 ||
           _stricmp(ext, ".ttc") == 0;
}

static void register_fonts_under(const char *dir_path)
{
    char search_pattern[MAX_PATH];
    int n = snprintf(search_pattern, sizeof(search_pattern), "%s\\*", dir_path);
    if (n < 0 || n >= (int)sizeof(search_pattern)) return;

    WIN32_FIND_DATAA find_data;
    HANDLE find = FindFirstFileA(search_pattern, &find_data);
    if (find == INVALID_HANDLE_VALUE) return;

    do {
        const char *name = find_data.cFileName;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        char path[MAX_PATH];
        int pn = snprintf(path, sizeof(path), "%s\\%s", dir_path, name);
        if (pn < 0 || pn >= (int)sizeof(path)) continue;

        if (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            register_fonts_under(path);
            continue;
        }

        if (has_font_extension(name)) {
            AddFontResourceExA(path, FR_PRIVATE, 0);
        }
    } while (FindNextFileA(find, &find_data));

    FindClose(find);
}

static void register_bundled_fonts(void)
{
    char exe_path[MAX_PATH];
    DWORD len = GetModuleFileNameA(NULL, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return;

    char *last_sep = strrchr(exe_path, '\\');
    if (last_sep) *last_sep = '\0';

    char themes_root[MAX_PATH];
    int n = snprintf(themes_root, sizeof(themes_root), "%s\\assets\\Themes", exe_path);
    if (n < 0 || n >= (int)sizeof(themes_root)) return;

    register_fonts_under(themes_root);
}

/* Does `path` end in ".lua" (case-insensitively)? Used to decide whether a
 * command-line argument is a script to run in place of the embedded app. */
static int has_lua_suffix(const char *path)
{
    size_t n = path ? strlen(path) : 0;
    if (n < 4) {
        return 0;
    }
    const char *ext = path + (n - 4);
    return (ext[0] == '.'
        && (ext[1] == 'l' || ext[1] == 'L')
        && (ext[2] == 'u' || ext[2] == 'U')
        && (ext[3] == 'a' || ext[3] == 'A'));
}

/* Populate the standard Lua `arg` table so a harness can read its own options.
 * arg[0] is the script; arg[1..] are the remaining arguments, matching the
 * convention the stand-alone lua interpreter uses. */
static void push_arg_table(lua_State *L, int argc, char **argv)
{
    lua_newtable(L);
    for (int i = 1; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");
}

/* IUP's libiup.a provides WinMain which calls main() -- define main() here */
int main(int argc, char **argv)
{
    /* Make bundled custom fonts available before any UI is created */
    register_bundled_fonts();

    /* IUP must be opened before any IUP calls (including iuplua_open) */
    IupOpen(NULL, NULL);

    /* Create Lua VM */
    lua_State *L = luaL_newstate();
    if (!L) {
        fatal("Failed to create Lua VM.");
        IupClose();
        return 1;
    }
    luaL_openlibs(L);

    /* Expose the executable directory before running the app script */
    set_exe_dir_global(L);
    set_exe_path_globals(L);

    /* LUNAR_DEV_BUILD (CMake option, ON for local builds, OFF when packaged)
     * tells main.lua whether it may prefer the repo's plugins/ and keep the
     * default module paths. A build-time flag, not a filesystem guess: a stray
     * folder next to an installed copy must not relax its protections. */
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

    /* Register IUP Lua binding (official libiuplua51.a) */
    iuplua_open(L);

    /* Make require("iup") work for embedded scripts and plugins */
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "loaded");
    lua_getglobal(L, "iup");
    lua_setfield(L, -2, "iup");
    lua_pop(L, 2);

    /* Preload custom C modules so require() finds them */
    preload(L, "lfs",          luaopen_lfs);
    preload(L, "cjson",        luaopen_cjson);
    preload(L, "socket.core",  luaopen_socket_core);
    preload(L, "mime.core",    luaopen_mime_core);
    preload(L, "subprocess",   luaopen_subprocess);
    preload(L, "process",      luaopen_process);
    preload(L, "logscan",      luaopen_logscan);
    preload(L, "winredraw",    luaopen_winredraw);
    preload(L, "iupraw",       luaopen_iupraw);
    preload(L, "themeapply",   luaopen_themeapply);
    preload(L, "svgicon",      luaopen_svgicon);
    preload(L, "appimages",    luaopen_appimages);

    /* LuaSec TLS transport C modules (ssl.lua/https.lua glue is embedded). */
    preload(L, "ssl.core",     luaopen_ssl_core);
    preload(L, "ssl.context",  luaopen_ssl_context);
    preload(L, "ssl.x509",     luaopen_ssl_x509);
    preload(L, "ssl.config",   luaopen_ssl_config);

    /* Preload embedded Lua modules (scanner, middleclass, lualibs/*) */
    preload_lua_modules(L);

    /* A .lua path on the command line runs INSTEAD of the embedded application.
     *
     * This exists for the GUI diagnostic harnesses under scripts\ (see
     * scripts\motion_check.lua). Parts of the UI layer -- the layered motion
     * overlay, GDI snapshot capture -- need a real dialog and a real window
     * handle, so they cannot be reached from the busted suite, and the CLI
     * executable deliberately has no IUP at all.
     *
     * Everything above this point has already run, so a harness executes in
     * exactly the environment the shipped application does: same IUP, same
     * LuaJIT, same native modules, same embedded Lua tree. That is the whole
     * value -- a harness that ran in a different environment would not tell us
     * anything about production. */
    int status;
    if (argc > 1 && argv[1] && has_lua_suffix(argv[1])) {
        push_arg_table(L, argc, argv);
        status = luaL_dofile(L, argv[1]);
    } else {
        status = luaL_dostring(L, LUA_MAIN_SCRIPT);
    }

    if (status != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        fatal(err ? err : "(unknown Lua error)");
    }

    /* Order matters: IupClose BEFORE lua_close. IupClose destroys every dialog
     * still alive, and iuplua's destroy callback (ldestroy_cb) reaches into the
     * lua_State to release each handle's callback references. Closing Lua first
     * left that callback dereferencing a freed state, and every exit ended in an
     * access violation (0xC0000005). The only Lua finalisers left to run after
     * this (MotionOverlay's snapshot guards) release GDI objects, not IUP ones. */
    IupClose();
    lua_close(L);
    return status == LUA_OK ? 0 : 1;
}

