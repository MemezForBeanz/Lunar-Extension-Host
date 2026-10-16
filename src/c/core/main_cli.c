/*
 * main_cli.c — Console test harness for Lunar Extension Host backend modules.
 *
 * Initializes a Lua VM, registers the C backend modules (process,
 * subprocess, lfs, cjson), and runs a Lua script from disk.
 *
 * Usage: LunarExtensionHostCLI <script.lua> [args...]
 *        Defaults to "test_backend.lua" in the exe's directory.
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* Backend module openers */
int luaopen_subprocess(lua_State *L);
int luaopen_process(lua_State *L);
int luaopen_logscan(lua_State *L);
int luaopen_lfs(lua_State *L);
int luaopen_cjson(lua_State *L);
int luaopen_socket_core(lua_State *L);
int luaopen_mime_core(lua_State *L);

/* LuaSec C core (statically linked TLS transport) */
int luaopen_ssl_core(lua_State *L);
int luaopen_ssl_context(lua_State *L);
int luaopen_ssl_x509(lua_State *L);
int luaopen_ssl_config(lua_State *L);

static void preload(lua_State *L, const char *name, lua_CFunction fn)
{
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, fn);
    lua_setfield(L, -2, name);
    lua_pop(L, 2);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: LunarExtensionHostCLI <script.lua> [args...]\n"
                        "Runs a Lua script with the host's native modules preloaded\n"
                        "(e.g. scripts\\process_check.lua).\n");
        return 2;
    }
    const char *script = argv[1];

    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "[FATAL] Failed to create Lua VM\n");
        return 1;
    }
    luaL_openlibs(L);

    /* Populate the global `arg` table the way the standalone lua interpreter
     * does, so scripts can use command-line argument parsers (e.g. argparse).
     * arg[0] is the script path; arg[1..] are the arguments after it; negative
     * indices carry the interpreter and any args before the script name. */
    {
        lua_newtable(L);
        lua_pushstring(L, script);
        lua_rawseti(L, -2, 0);
        lua_pushstring(L, argv[0]);
        lua_rawseti(L, -2, -1);
        for (int i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 1);
        }
        lua_setglobal(L, "arg");
    }

    /* Register backend C modules */
    preload(L, "subprocess",   luaopen_subprocess);
    preload(L, "process",      luaopen_process);
    preload(L, "logscan",      luaopen_logscan);
    preload(L, "lfs",          luaopen_lfs);
    preload(L, "cjson",        luaopen_cjson);
    preload(L, "socket.core",  luaopen_socket_core);
    preload(L, "mime.core",    luaopen_mime_core);
    preload(L, "ssl.core",     luaopen_ssl_core);
    preload(L, "ssl.context",  luaopen_ssl_context);
    preload(L, "ssl.x509",     luaopen_ssl_x509);
    preload(L, "ssl.config",   luaopen_ssl_config);

    printf("=== Lunar Extension Host CLI Backend Test Harness ===\n");
    printf("Loading script: %s\n\n", script);

    if (luaL_dofile(L, script) != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        fprintf(stderr, "\n[LUA ERROR] %s\n", err ? err : "(unknown error)");
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
