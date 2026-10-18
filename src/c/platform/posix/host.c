#include "core/host.h"

#include <dirent.h>
#include <fontconfig/fontconfig.h>
#include <glib.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

int luaopen_process(lua_State *L);

/* /proc/self/exe is independent of the current working directory. */
static int exe_path(char *path, size_t size)
{
    ssize_t len = readlink("/proc/self/exe", path, size - 1);
    if (len < 0 || (size_t)len >= size - 1) return 0;
    path[len] = '\0';
    return 1;
}

void host_set_exe_dir_global(lua_State *L)
{
    char path[PATH_MAX];
    if (!exe_path(path, sizeof(path))) {
        lua_pushstring(L, "");
    } else {
        char *last_sep = strrchr(path, '/');
        if (last_sep) *last_sep = '\0';
        lua_pushstring(L, path);
    }
    lua_setglobal(L, "LUNAR_EXE_DIR");
}

void host_set_exe_path_globals(lua_State *L)
{
    char path[PATH_MAX];
    lua_pushstring(L, exe_path(path, sizeof(path)) ? path : "");
    lua_setglobal(L, "LUNAR_EXE_PATH");
    lua_pushinteger(L, (lua_Integer)getpid());
    lua_setglobal(L, "LUNAR_PID");
}

static int has_font_extension(const char *filename)
{
    const char *ext = strrchr(filename, '.');
    return ext && (strcasecmp(ext, ".otf") == 0 ||
                   strcasecmp(ext, ".ttf") == 0 ||
                   strcasecmp(ext, ".ttc") == 0);
}

static void register_fonts_under(const char *dir_path)
{
    DIR *dir = opendir(dir_path);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        const char *name = entry->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        char path[PATH_MAX];
        int n = snprintf(path, sizeof(path), "%s/%s", dir_path, name);
        if (n < 0 || n >= (int)sizeof(path)) continue;
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) register_fonts_under(path);
        else if (S_ISREG(st.st_mode) && has_font_extension(name))
            FcConfigAppFontAddFile(NULL, (const FcChar8 *)path);
    }
    closedir(dir);
}

void host_register_bundled_fonts(void)
{
    char path[PATH_MAX];
    if (!exe_path(path, sizeof(path))) return;
    char *last_sep = strrchr(path, '/');
    if (last_sep) *last_sep = '\0';
    char themes_root[PATH_MAX];
    int n = snprintf(themes_root, sizeof(themes_root), "%s/assets/Themes", path);
    if (n < 0 || n >= (int)sizeof(themes_root)) return;
    register_fonts_under(themes_root);
}

void host_pre_iup_open(void)
{
    /* The executable is `lunar` (Linux convention), but the process is "Lunar"
       everywhere it is shown: ps/top/System Monitor read the thread name, and
       GTK derives the X11 window class (WM_CLASS "Lunar", "Lunar") from the
       program name, which the .desktop file's StartupWMClass matches so the
       panel groups the window under the Lunar launcher and icon. */
    prctl(PR_SET_NAME, "Lunar", 0, 0, 0);
    g_set_prgname("Lunar");
    g_set_application_name("Lunar");

    /* Linux v1 uses X11 or XWayland; set this only in our process before GTK opens. */
    const char *backend = getenv("LUNAR_GDK_BACKEND");
    setenv("GDK_BACKEND", backend && *backend ? backend : "x11", 1);
}

void host_preload_modules(lua_State *L, host_preload_fn preload)
{
    preload(L, "process", luaopen_process);
}
