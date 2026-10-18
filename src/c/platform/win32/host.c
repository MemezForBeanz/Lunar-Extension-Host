#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "../../core/host.h"

int luaopen_subprocess(lua_State *L);
int luaopen_process(lua_State *L);
int luaopen_winredraw(lua_State *L);

/* Paths go through the wide (*W) APIs and reach Lua as UTF-8, so an install or a
 * portable extraction under a non-ASCII folder works. The exe manifest sets the
 * process code page to UTF-8, so the narrow paths Lua uses (io.open, lfs, IUP)
 * read those same UTF-8 strings. */

/* The full path of this executable as a malloc'd wide string, or NULL. The buffer
 * grows until the path fits: MAX_PATH is not a limit on long-path installs. */
static wchar_t *exe_path_w(void)
{
    DWORD size = MAX_PATH;
    for (;;) {
        wchar_t *buf = (wchar_t *)malloc(size * sizeof(wchar_t));
        if (!buf) return NULL;
        DWORD len = GetModuleFileNameW(NULL, buf, size);
        if (len == 0) { free(buf); return NULL; }
        if (len < size) return buf;          /* fits (len excludes the terminator) */
        free(buf);                           /* truncated: try a bigger buffer */
        if (size >= 32768) return NULL;      /* the longest path Windows allows */
        size *= 2;
    }
}

/* `w` as a malloc'd UTF-8 string, or NULL. */
static char *utf8_from_wide(const wchar_t *w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (!s) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) { free(s); return NULL; }
    return s;
}

/* Push the UTF-8 form of `w`, or "" when there is none. An empty LUNAR_EXE_DIR
 * makes a packaged build refuse to start (main.lua) rather than fall back to the
 * working directory. */
static void push_utf8(lua_State *L, const wchar_t *w)
{
    char *s = w ? utf8_from_wide(w) : NULL;
    lua_pushstring(L, s ? s : "");
    free(s);
}

/* Set the global LUNAR_EXE_DIR to the directory containing this executable.
 * This is stable regardless of the process working directory, so Lua can
 * resolve plugins/ and other bundled resources reliably. */
void host_set_exe_dir_global(lua_State *L)
{
    wchar_t *path = exe_path_w();
    if (path) {
        wchar_t *last_sep = wcsrchr(path, L'\\');
        if (last_sep) *last_sep = L'\0';
    }
    push_utf8(L, path);
    free(path);
    lua_setglobal(L, "LUNAR_EXE_DIR");
}

/* Set the global LUNAR_EXE_PATH to the full path of this executable and LUNAR_PID to
 * this process id. These let the Lua updater relaunch the app after installing
 * an update and wait for this process to exit before touching locked files. */
void host_set_exe_path_globals(lua_State *L)
{
    wchar_t *path = exe_path_w();
    push_utf8(L, path);
    free(path);
    lua_setglobal(L, "LUNAR_EXE_PATH");

    lua_pushinteger(L, (lua_Integer)GetCurrentProcessId());
    lua_setglobal(L, "LUNAR_PID");
}

/* Register bundled custom fonts with the OS for this process only, scanning the
 * theme asset tree: assets\\Themes\\<Theme Name>\\... . This supports per-theme fonts
 * without hardcoding file names. */
static int has_font_extension(const wchar_t *filename)
{
    const wchar_t *ext = wcsrchr(filename, L'.');
    if (!ext) return 0;
    return _wcsicmp(ext, L".otf") == 0 ||
           _wcsicmp(ext, L".ttf") == 0 ||
           _wcsicmp(ext, L".ttc") == 0;
}

/* `dir` + "\\" + `name` as a malloc'd wide string, or NULL. */
static wchar_t *join_w(const wchar_t *dir, const wchar_t *name)
{
    size_t n = wcslen(dir) + 1 + wcslen(name) + 1;
    wchar_t *out = (wchar_t *)malloc(n * sizeof(wchar_t));
    if (!out) return NULL;
    _snwprintf(out, n, L"%ls\\%ls", dir, name);
    out[n - 1] = L'\0';
    return out;
}

static void register_fonts_under(const wchar_t *dir_path)
{
    wchar_t *pattern = join_w(dir_path, L"*");
    if (!pattern) return;

    WIN32_FIND_DATAW find_data;
    HANDLE find = FindFirstFileW(pattern, &find_data);
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) return;

    do {
        const wchar_t *name = find_data.cFileName;
        if (wcscmp(name, L".") == 0 || wcscmp(name, L"..") == 0) continue;

        wchar_t *path = join_w(dir_path, name);
        if (!path) continue;
        if (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            register_fonts_under(path);
        } else if (has_font_extension(name)) {
            AddFontResourceExW(path, FR_PRIVATE, 0);
        }
        free(path);
    } while (FindNextFileW(find, &find_data));

    FindClose(find);
}

void host_register_bundled_fonts(void)
{
    wchar_t *exe = exe_path_w();
    if (!exe) return;

    wchar_t *last_sep = wcsrchr(exe, L'\\');
    if (last_sep) *last_sep = L'\0';

    wchar_t *themes_root = join_w(exe, L"assets\\Themes");
    free(exe);
    if (!themes_root) return;
    register_fonts_under(themes_root);
    free(themes_root);
}

void host_pre_iup_open(void)
{
}

void host_preload_modules(lua_State *L, host_preload_fn preload)
{
    preload(L, "subprocess",   luaopen_subprocess);
    preload(L, "process",      luaopen_process);
    preload(L, "winredraw",    luaopen_winredraw);
}
