/*
 * main_cli.c — Lunar's console executable (lunar-cli; LunarCLI.exe on Windows).
 *
 * Two modes, both without IUP:
 *
 *   lunar-cli --headless [options]   the headless extension host (core.headless):
 *                                    loads extensions that declare the "headless"
 *                                    mode and runs them on an event loop until
 *                                    SIGTERM/SIGINT (Ctrl+C on Windows).
 *   lunar-cli <script.lua> [args]    runs a Lua script with the host's native
 *                                    modules preloaded (check scripts, the Linux
 *                                    installer).
 *
 * The headless mode runs the embedded Lua tree (lua_bundle.h, the same one the
 * desktop app embeds), so it needs nothing next to the executable.
 */
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "lua_bundle.h"  /* preload_lua_modules(); LUA_MAIN_SCRIPT is the desktop app's */

/* Backend module openers */
#ifdef _WIN32
int luaopen_subprocess(lua_State *L);
#endif
int luaopen_process(lua_State *L);
int luaopen_file_stream(lua_State *L);
int luaopen_logscan(lua_State *L);
int luaopen_compositor(lua_State *L);
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

/* ---- stop requests ------------------------------------------------------- */

/* Set by SIGTERM/SIGINT (POSIX) or a console control event (Windows); the Lua
 * event loop polls it through LUNAR_STOP_REQUESTED() and shuts down cleanly. */
static volatile sig_atomic_t g_stop_requested = 0;

#ifdef _WIN32
static BOOL WINAPI on_console_event(DWORD type)
{
    (void)type;   /* Ctrl+C, Ctrl+Break, console close, logoff, shutdown */
    g_stop_requested = 1;
    return TRUE;
}
#else
static void on_stop_signal(int sig)
{
    (void)sig;
    g_stop_requested = 1;
}
#endif

static void install_stop_handlers(void)
{
#ifdef _WIN32
    SetConsoleCtrlHandler(on_console_event, TRUE);
#else
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_stop_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    /* A client that hangs up mid-response must not kill the server. */
    signal(SIGPIPE, SIG_IGN);
#endif
}

static int l_stop_requested(lua_State *L)
{
    lua_pushboolean(L, g_stop_requested != 0);
    return 1;
}

/* ---- paths --------------------------------------------------------------- */

/* The folder holding this executable, into `buf`; empty when it can't tell. */
static void exe_dir(char *buf, size_t size)
{
    buf[0] = '\0';
#ifdef _WIN32
    DWORD n = GetModuleFileNameA(NULL, buf, (DWORD)size);
    if (n == 0 || n >= size) { buf[0] = '\0'; return; }
    char *slash = strrchr(buf, '\\');
#else
    ssize_t n = readlink("/proc/self/exe", buf, size - 1);
    if (n <= 0) { buf[0] = '\0'; return; }
    buf[n] = '\0';
    char *slash = strrchr(buf, '/');
#endif
    if (slash) *slash = '\0';
    else buf[0] = '\0';
}

/* LUNAR_EXE_DIR, and lua/ next to the executable as a fallback module path
 * (the embedded modules are preloaded and win over files). */
static void set_exe_paths(lua_State *L)
{
    char dir[4096];
    exe_dir(dir, sizeof(dir));
    if (!dir[0]) return;
    lua_pushstring(L, dir);
    lua_setglobal(L, "LUNAR_EXE_DIR");
#ifdef _WIN32
    const char *sep = "\\";
#else
    const char *sep = "/";
#endif
    lua_getglobal(L, "package");
    lua_pushfstring(L, "%s%slua%s?.lua;%s%slua%s?%sinit.lua", dir, sep, sep, dir, sep, sep, sep);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);
}

/* ---- modes --------------------------------------------------------------- */

static int run_headless(lua_State *L, int argc, char **argv)
{
    set_exe_paths(L);
    preload_lua_modules(L);
    install_stop_handlers();
    lua_pushcfunction(L, l_stop_requested);
    lua_setglobal(L, "LUNAR_STOP_REQUESTED");

    /* require("core.headless").main({ args after --headless }) */
    lua_getglobal(L, "require");
    lua_pushstring(L, "core.headless");
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "[LUA ERROR] %s\n", lua_tostring(L, -1));
        return 1;
    }
    lua_getfield(L, -1, "main");
    lua_newtable(L);
    for (int i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        fprintf(stderr, "[LUA ERROR] %s\n", lua_tostring(L, -1));
        return 1;
    }
    return lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : 0;
}

static int run_script(lua_State *L, int argc, char **argv)
{
    const char *script = argv[1];

    /* Populate the global `arg` table the way the standalone lua interpreter
     * does, so scripts can use command-line argument parsers (e.g. argparse).
     * arg[0] is the script path; arg[1..] are the arguments after it; negative
     * indices carry the interpreter and any args before the script name. */
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

    printf("=== Lunar Extension Host CLI Backend Test Harness ===\n");
    printf("Loading script: %s\n\n", script);

    if (luaL_dofile(L, script) != LUA_OK) {
        const char *err = lua_tostring(L, -1);
        fprintf(stderr, "\n[LUA ERROR] %s\n", err ? err : "(unknown error)");
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    (void)LUA_MAIN_SCRIPT;   /* the desktop app's entry; unused here */
    if (argc < 2) {
        fprintf(stderr, "Usage: lunar-cli --headless [options]   (see --headless --help)\n"
                        "       lunar-cli <script.lua> [args...]\n"
                        "Runs the headless extension host, or a Lua script with the host's\n"
                        "native modules preloaded (e.g. scripts/process_check.lua).\n");
        return 2;
    }

    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "[FATAL] Failed to create Lua VM\n");
        return 1;
    }
    luaL_openlibs(L);

    /* Register backend C modules */
#ifdef _WIN32
    preload(L, "subprocess",   luaopen_subprocess);
#endif
    preload(L, "process",      luaopen_process);
    preload(L, "file_stream", luaopen_file_stream);
    preload(L, "logscan",      luaopen_logscan);
    preload(L, "compositor",   luaopen_compositor);
    preload(L, "lfs",          luaopen_lfs);
    preload(L, "cjson",        luaopen_cjson);
    preload(L, "socket.core",  luaopen_socket_core);
    preload(L, "mime.core",    luaopen_mime_core);
    preload(L, "ssl.core",     luaopen_ssl_core);
    preload(L, "ssl.context",  luaopen_ssl_context);
    preload(L, "ssl.x509",     luaopen_ssl_x509);
    preload(L, "ssl.config",   luaopen_ssl_config);

    int status = strcmp(argv[1], "--headless") == 0
        ? run_headless(L, argc, argv)
        : run_script(L, argc, argv);

    lua_close(L);
    return status;
}
