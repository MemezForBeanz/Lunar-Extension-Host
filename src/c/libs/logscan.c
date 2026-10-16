/* logscan.c -- native log scanner for the Log File Parser plugin.
 *
 * See include/logscan.h for the Lua-facing API. Everything here is plain C99 +
 * Win32 FindFirstFile enumeration; no third-party deps. The design keeps the
 * hot paths (directory walk, per-line "failed" detection) in C while leaving
 * batching, progress and cancellation to the Lua orchestrator so the IUP UI
 * thread stays responsive during large / network scans.
 */

/*** Native log scanner for the Log File Parser plugin.
 *
 * Provides fast directory walking and per-file `"failed"` detection in C
 * while leaving batching, progress reporting, and cancellation to the Lua
 * orchestrator so the IUP UI thread stays responsive during large or
 * network-share scans.
 *
 * @module logscan
 */

#include "logscan.h"

#include <lua.h>
#include <lauxlib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

static int ascii_lower(int c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A' + 'a';
    return c;
}

static int is_word_char(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* Whole-word, case-insensitive search for "failed" in [s, s+len). */
static int line_has_failed(const char *s, size_t len)
{
    static const char needle[] = "failed";
    const size_t nlen = 6;
    if (len < nlen) return 0;

    for (size_t i = 0; i + nlen <= len; i++) {
        size_t k;
        for (k = 0; k < nlen; k++) {
            if (ascii_lower((unsigned char)s[i + k]) != needle[k]) break;
        }
        if (k != nlen) continue;

        int before = (i == 0) ? 0 : (unsigned char)s[i - 1];
        int after  = (i + nlen >= len) ? 0 : (unsigned char)s[i + nlen];
        if (!is_word_char(before) && !is_word_char(after)) return 1;
    }
    return 0;
}

/* Extract the first "(...)" group with at least one inner char.
 * On success writes start/len (of the inner text) and returns 1. */
static int extract_type(const char *s, size_t len, const char **out, size_t *out_len)
{
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '(') {
            for (size_t j = i + 1; j < len; j++) {
                if (s[j] == ')') {
                    if (j > i + 1) {           /* non-empty */
                        *out = s + i + 1;
                        *out_len = j - (i + 1);
                        return 1;
                    }
                    break;                     /* empty () -> keep looking */
                }
            }
        }
    }
    return 0;
}

/* Trim leading/trailing ASCII whitespace; returns adjusted pointer + length. */
static void trim(const char **s, size_t *len)
{
    const char *p = *s;
    size_t n = *len;
    while (n > 0 && isspace((unsigned char)p[0])) { p++; n--; }
    while (n > 0 && isspace((unsigned char)p[n - 1])) { n--; }
    *s = p;
    *len = n;
}

/* Read an entire file into a malloc'd, NUL-terminated buffer. Returns the
 * buffer (caller frees) and sets *out_size to the byte count, or NULL. */
static char *read_whole_file(const char *path, size_t *out_size)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }

    char *buf = (char *)malloc((size_t)size + 1);
    if (!buf) { fclose(f); return NULL; }

    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[got] = '\0';
    if (out_size) *out_size = got;
    return buf;
}

/* ------------------------------------------------------------------ */
/* list_dir -- one directory's entries with inline attributes          */
/* ------------------------------------------------------------------ */

/* List a single directory (non-recursive). Returns an array of
 * { name = <string>, dir = <bool> } tables, "." and ".." omitted. The whole
 * point is that FindFirstFile carries each entry's directory/file bit inline,
 * so the Lua orchestrator no longer needs a per-entry lfs.attributes() stat --
 * a separate round-trip that is especially costly on network shares. This
 * mirrors what the standalone LogParserApp gets for free from
 * Directory.EnumerateFiles. The recursive walk / batching / cancellation stay
 * in Lua (libs/scanjob.lua) so the UI thread keeps yielding. */
/*** List the immediate entries of a single directory (non-recursive).
 *
 * Returns an array of entry tables, each with fields:
 *
 * - **`name`** (`string`) — entry name (no directory prefix).
 * - **`dir`** (`boolean`) — `true` if the entry is a sub-directory.
 *
 * `.` and `..` are omitted. Returns an empty array if the directory
 * cannot be opened. The directory/file flag is obtained inline from the
 * Win32 `FindFirstFile` result, avoiding a separate stat round-trip for
 * each entry (important on network shares).
 *
 * @function list_dir
 * @tparam  string path  Directory to list.
 * @treturn table        Array of `{ name = string, dir = boolean }` entries.
 * @usage
 *   for _, e in ipairs(logscan.list_dir("D:\\logs")) do
 *     print(e.name, e.dir)
 *   end
 */
static int l_list_dir(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);

    lua_newtable(L);
    int table_idx = lua_gettop(L);
    int count = 0;

#ifdef _WIN32
    size_t len = strlen(path);
    while (len > 0 && (path[len - 1] == '\\' || path[len - 1] == '/'))
        len--;

    char *pat = (char *)malloc(len + 3); /* path + "\\*" + NUL */
    if (!pat) return 1;
    memcpy(pat, path, len);
    memcpy(pat + len, "\\*", 3);

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) return 1; /* empty array on error */

    do {
        const char *name = fd.cFileName;
        if (name[0] == '.' && (name[1] == '\0' ||
            (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0);
        lua_setfield(L, -2, "dir");
        lua_rawseti(L, table_idx, ++count);
    } while (FindNextFileA(h, &fd));

    FindClose(h);
#else
    /* POSIX: readdir's d_type gives the directory bit inline on most file
     * systems; fall back to lstat where it reports DT_UNKNOWN. */
    DIR *d = opendir(path);
    if (!d) return 1; /* empty array on error */
    size_t plen = strlen(path);
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.' && (name[1] == '\0' ||
            (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        int is_dir = 0;
#ifdef DT_DIR
        if (ent->d_type == DT_DIR) {
            is_dir = 1;
        } else if (ent->d_type == DT_UNKNOWN)
#endif
        {
            size_t n = plen + strlen(name) + 2;
            char *full = (char *)malloc(n);
            if (full) {
                struct stat st;
                snprintf(full, n, "%s/%s", path, name);
                if (lstat(full, &st) == 0 && S_ISDIR(st.st_mode)) is_dir = 1;
                free(full);
            }
        }
        lua_newtable(L);
        lua_pushstring(L, name);
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, is_dir);
        lua_setfield(L, -2, "dir");
        lua_rawseti(L, table_idx, ++count);
    }
    closedir(d);
#endif

    return 1; /* the array table */
}

/* ------------------------------------------------------------------ */
/* scan_file                                                           */
/* ------------------------------------------------------------------ */

/*** Scan a single file for lines containing the word `"failed"`.
 *
 * `"failed"` is matched whole-word and case-insensitively. The most recently
 * seen `(type)` parenthetical on a non-failure line is attached to each
 * subsequent failure entry as its `type` field.
 *
 * Returns a result table with fields:
 *
 * - **`count`** (`integer`) — number of failure lines found.
 * - **`failures`** (`table`) — array of failure entries, each containing:
 *   - **`line`** (`integer`) — 1-based line number.
 *   - **`message`** (`string`) — trimmed line text.
 *   - **`type`** (`string`, optional) — nearest preceding `(...)` token.
 * - **`error`** (`string`, optional) — present if the file could not be read.
 *
 * @function scan_file
 * @tparam  string path  Path to the file to scan.
 * @treturn table        Result table `{ count, failures [, error] }`.
 * @usage
 *   local r = logscan.scan_file("D:\\logs\\run.log")
 *   print(r.count, "failures")
 *   for _, f in ipairs(r.failures) do
 *     print(f.line, f.message)
 *   end
 */
static int l_scan_file(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);

    size_t size = 0;
    char *buf = read_whole_file(path, &size);

    lua_newtable(L);                 /* result */
    if (!buf) {
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "count");
        lua_newtable(L);
        lua_setfield(L, -2, "failures");
        lua_pushstring(L, "could not read file");
        lua_setfield(L, -2, "error");
        return 1;
    }

    lua_newtable(L);                 /* failures array */
    int failures_idx = lua_gettop(L);
    int fail_count = 0;

    /* most recent "(type)" from a non-failure line */
    const char *last_type = NULL;
    size_t last_type_len = 0;

    size_t pos = 0;
    int line_no = 0;
    while (pos <= size) {
        /* find end of line */
        size_t start = pos;
        while (pos < size && buf[pos] != '\n') pos++;
        size_t end = pos;               /* exclusive */
        if (pos < size) pos++;          /* skip '\n' */
        else if (start == size) break;  /* trailing */

        /* strip a trailing '\r' */
        if (end > start && buf[end - 1] == '\r') end--;

        line_no++;
        const char *line = buf + start;
        size_t line_len = end - start;

        int failed = line_has_failed(line, line_len);

        if (!failed) {
            const char *ts;
            size_t tl;
            if (extract_type(line, line_len, &ts, &tl)) {
                last_type = ts;
                last_type_len = tl;
            }
        } else {
            const char *msg = line;
            size_t msg_len = line_len;
            trim(&msg, &msg_len);

            lua_newtable(L);            /* failure entry */
            lua_pushinteger(L, line_no);
            lua_setfield(L, -2, "line");
            lua_pushlstring(L, msg, msg_len);
            lua_setfield(L, -2, "message");
            if (last_type) {
                lua_pushlstring(L, last_type, last_type_len);
                lua_setfield(L, -2, "type");
            }
            lua_rawseti(L, failures_idx, ++fail_count);
        }
    }

    free(buf);

    lua_pushinteger(L, fail_count);
    lua_setfield(L, -3, "count");      /* result.count */
    /* failures array currently on top; attach it */
    lua_setfield(L, -2, "failures");   /* result.failures = failures */
    return 1;                          /* result */
}

/* ------------------------------------------------------------------ */
/* file_context                                                        */
/* ------------------------------------------------------------------ */

/*** Return surrounding lines of context around a target line number.
 *
 * Reads `path` and returns a window of lines centred on `target`.
 * The window spans `[target - before, target + after]`, clamped to
 * the actual file boundaries.
 *
 * Each entry in the returned array is a table with fields:
 *
 * - **`n`** (`integer`) — 1-based line number.
 * - **`text`** (`string`) — line content (trailing newline stripped).
 *
 * Returns an empty array if the file cannot be read.
 *
 * @function file_context
 * @tparam  string  path          Path to the file.
 * @tparam  integer target        1-based line number to centre the window on.
 * @tparam[opt] integer before    Lines to include before `target` (default: 3).
 * @tparam[opt] integer after     Lines to include after `target` (default: 3).
 * @treturn table                 Array of `{ n = integer, text = string }` entries.
 * @usage
 *   local ctx = logscan.file_context("run.log", 42, 2, 2)
 *   for _, l in ipairs(ctx) do print(l.n, l.text) end
 */
static int l_file_context(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    int target = (int)luaL_checkinteger(L, 2);
    int before = (int)luaL_optinteger(L, 3, 3);
    int after  = (int)luaL_optinteger(L, 4, 3);
    if (before < 0) before = 0;
    if (after < 0) after = 0;

    int lo = target - before; if (lo < 1) lo = 1;
    int hi = target + after;

    lua_newtable(L);                   /* context array */
    int out_idx = lua_gettop(L);
    int out_n = 0;

    size_t size = 0;
    char *buf = read_whole_file(path, &size);
    if (!buf) return 1;

    size_t pos = 0;
    int line_no = 0;
    while (pos <= size) {
        size_t start = pos;
        while (pos < size && buf[pos] != '\n') pos++;
        size_t end = pos;
        if (pos < size) pos++;
        else if (start == size) break;

        if (end > start && buf[end - 1] == '\r') end--;
        line_no++;

        if (line_no >= lo && line_no <= hi) {
            lua_newtable(L);
            lua_pushinteger(L, line_no);
            lua_setfield(L, -2, "n");
            lua_pushlstring(L, buf + start, end - start);
            lua_setfield(L, -2, "text");
            lua_rawseti(L, out_idx, ++out_n);
        }
        if (line_no > hi) break;
    }

    free(buf);
    return 1;
}

/* ------------------------------------------------------------------ */
/* module registration                                                 */
/* ------------------------------------------------------------------ */

static const luaL_Reg logscan_lib[] = {
    { "list_dir",     l_list_dir     },
    { "scan_file",    l_scan_file    },
    { "file_context", l_file_context },
    { NULL, NULL }
};

int luaopen_logscan(lua_State *L)
{
    luaL_newlib(L, logscan_lib);
    return 1;
}
