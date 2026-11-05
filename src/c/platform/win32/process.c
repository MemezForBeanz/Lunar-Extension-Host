/*** Child processes with separate, non-blocking output streams (Windows).
 *
 * The contract a long-running engine runs on:
 *
 *  - **argv, never a shell.** Arguments are quoted with the MSVC runtime rules,
 *    so paths with spaces, quotes or trailing backslashes arrive intact.
 *  - **The child's working directory and environment only.** The host's own
 *    current directory is never changed (the old `subprocess.start_argv` did).
 *  - **stdout and stderr are separate pipes.** A tool's protocol on stdout can't
 *    be corrupted by warnings or a traceback on stderr.
 *  - **Non-blocking reads that tell "nothing yet" from "finished".** `read`
 *    returns `""` while a stream is open and empty, and `nil` once every writer
 *    has closed it.
 *  - **One kill-on-close job per process.** The child starts suspended and joins
 *    its job before it runs, so nothing it spawns escapes. `kill` ends the whole
 *    tree, and if the host dies Windows ends it too.
 *  - **Deterministic ownership.** A process is a full userdata with `close` and a
 *    finaliser; closing a process that is still running ends its tree.
 *  - **Only its own handles are inherited.** The child gets exactly its three
 *    standard handles, not every inheritable handle the host happens to hold.
 *  - **stdin is one-shot or a stream, and never blocks the host.** A string is
 *    written and the pipe closed; `stdin = true` keeps the pipe open for
 *    `process:write`, which queues the bytes for a writer thread. A child that
 *    stops reading makes the queue grow (see `process:pending`), not the UI hang.
 *
 * Strings cross this boundary in the active ANSI code page, matching `io.open`
 * and `lfs`. The exe manifest sets that code page to UTF-8, so in practice they
 * are UTF-8, like the rest of the host.
 *
 * @module process
 */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <lua.h>
#include <lauxlib.h>

#define PROCESS_MT "lunar.process"
#define READ_DEFAULT 65536
#define READ_MAX (1024 * 1024)

/* Code page for strings crossing into Win32 (see the module comment). */
static const UINT g_codepage = CP_ACP;

/* Most bytes `process:write` will hold for a child that is not reading. Past
 * this the write is refused, so a stalled child costs bounded memory. */
#define STDIN_BACKLOG_MAX (64u * 1024u * 1024u)

/* A long-lived stdin (opts.stdin = true). `process:write` appends a chunk and
 * returns; the writer thread owns the pipe's write end and does the blocking
 * WriteFile. Shared by the userdata and the thread, so it is reference counted:
 * whichever lets go last frees it. */
typedef struct StdinChunk {
    struct StdinChunk *next;
    size_t len;
    char data[1];
} StdinChunk;

typedef struct {
    CRITICAL_SECTION lock;
    HANDLE wake;             /* auto-reset: there is work, or the state changed */
    HANDLE pipe;             /* write end; the thread closes it */
    StdinChunk *head, *tail;
    size_t queued;           /* bytes accepted and not yet written */
    int closing;             /* write what is queued, then close the pipe */
    int abort;               /* drop what is queued and close the pipe */
    int failed;              /* a write failed: the child no longer reads */
    int done;                /* the thread has closed the pipe */
    LONG refs;
} StdinStream;

typedef struct {
    HANDLE process;
    HANDLE job;
    HANDLE out_r, err_r;
    HANDLE stdin_thread;   /* delivers stdin; owns the pipe's write end */
    StdinStream *stream;   /* set when stdin is a stream (opts.stdin = true) */
    DWORD pid;
    int out_eof, err_eof;
} LProcess;

/* stdin is written by its own thread: a child that never reads its input (or
 * fills stdout before reading) must not be able to block the host's UI thread.
 * The thread owns the buffer and the write end, and closes both when done; if
 * the child dies first the write fails and the thread ends. */
typedef struct {
    HANDLE pipe;
    char *data;
    size_t len;
} StdinFeed;

static DWORD WINAPI stdin_writer(LPVOID arg)
{
    StdinFeed *feed = (StdinFeed *)arg;
    const char *p = feed->data;
    size_t left = feed->len;
    while (left > 0) {
        DWORD wrote = 0;
        DWORD chunk = left > 65536 ? 65536 : (DWORD)left;
        if (!WriteFile(feed->pipe, p, chunk, &wrote, NULL)) break;
        p += wrote;
        left -= wrote;
    }
    CloseHandle(feed->pipe);
    SecureZeroMemory(feed->data, feed->len);  /* it may be a credential */
    free(feed->data);
    free(feed);
    return 0;
}

static void stream_release(StdinStream *st)
{
    if (InterlockedDecrement(&st->refs) > 0) return;
    for (StdinChunk *c = st->head; c;) {
        StdinChunk *next = c->next;
        SecureZeroMemory(c->data, c->len);
        free(c);
        c = next;
    }
    if (st->pipe) CloseHandle(st->pipe);
    if (st->wake) CloseHandle(st->wake);
    DeleteCriticalSection(&st->lock);
    free(st);
}

static StdinStream *stream_new(void)
{
    StdinStream *st = (StdinStream *)calloc(1, sizeof(StdinStream));
    if (!st) return NULL;
    st->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!st->wake) { free(st); return NULL; }
    InitializeCriticalSection(&st->lock);
    st->refs = 1;
    return st;
}

static DWORD WINAPI stream_writer(LPVOID arg)
{
    StdinStream *st = (StdinStream *)arg;
    for (;;) {
        EnterCriticalSection(&st->lock);
        while (!st->head && !st->closing && !st->abort) {
            LeaveCriticalSection(&st->lock);
            WaitForSingleObject(st->wake, INFINITE);
            EnterCriticalSection(&st->lock);
        }
        if (st->abort || !st->head) { LeaveCriticalSection(&st->lock); break; }
        StdinChunk *c = st->head;
        st->head = c->next;
        if (!st->head) st->tail = NULL;
        LeaveCriticalSection(&st->lock);

        const char *p = c->data;
        size_t left = c->len;
        int ok = 1;
        while (left > 0) {
            DWORD wrote = 0;
            DWORD chunk = left > 65536 ? 65536 : (DWORD)left;
            if (!WriteFile(st->pipe, p, chunk, &wrote, NULL)) { ok = 0; break; }
            p += wrote;
            left -= wrote;
        }
        EnterCriticalSection(&st->lock);
        st->queued -= c->len;
        if (!ok) st->failed = 1;
        LeaveCriticalSection(&st->lock);
        SecureZeroMemory(c->data, c->len);
        free(c);
        if (!ok) break;
    }
    EnterCriticalSection(&st->lock);
    HANDLE pipe = st->pipe;
    st->pipe = NULL;
    st->done = 1;
    LeaveCriticalSection(&st->lock);
    if (pipe) CloseHandle(pipe);   /* the child sees end of input */
    stream_release(st);
    return 0;
}

/* ---------------------------------------------------------------------------
 * Growable wide-string buffer
 * ------------------------------------------------------------------------- */

typedef struct { wchar_t *p; size_t len, cap; int oom; } WBuf;

static void wb_putn(WBuf *b, const wchar_t *s, size_t n)
{
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) cap *= 2;
        wchar_t *p = (wchar_t *)realloc(b->p, cap * sizeof(wchar_t));
        if (!p) { b->oom = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n * sizeof(wchar_t));
    b->len += n;
    b->p[b->len] = 0;
}

static void wb_putc(WBuf *b, wchar_t c) { wb_putn(b, &c, 1); }

/* Convert `n` bytes of a Lua string to a freshly allocated wide string. */
static wchar_t *to_wide(const char *s, size_t n)
{
    int wn = n ? MultiByteToWideChar(g_codepage, 0, s, (int)n, NULL, 0) : 0;
    wchar_t *w = (wchar_t *)malloc(((size_t)wn + 1) * sizeof(wchar_t));
    if (!w) return NULL;
    if (wn > 0) MultiByteToWideChar(g_codepage, 0, s, (int)n, w, wn);
    w[wn] = 0;
    return w;
}

/* Append one argument quoted the way CommandLineToArgvW / the MSVC CRT parse it. */
static void append_quoted(WBuf *b, const wchar_t *arg)
{
    if (*arg && !wcspbrk(arg, L" \t\n\v\"")) {
        wb_putn(b, arg, wcslen(arg));
        return;
    }
    wb_putc(b, L'"');
    for (const wchar_t *p = arg;; ++p) {
        size_t slashes = 0;
        while (*p == L'\\') { ++p; ++slashes; }
        if (*p == 0) {
            /* Double trailing backslashes so they don't escape the closing quote. */
            for (size_t i = 0; i < slashes * 2; i++) wb_putc(b, L'\\');
            break;
        } else if (*p == L'"') {
            for (size_t i = 0; i < slashes * 2 + 1; i++) wb_putc(b, L'\\');
            wb_putc(b, L'"');
        } else {
            for (size_t i = 0; i < slashes; i++) wb_putc(b, L'\\');
            wb_putc(b, *p);
        }
    }
    wb_putc(b, L'"');
}

/* ---------------------------------------------------------------------------
 * Environment block: the host's environment with the table at `idx` applied.
 * A string value sets a variable; `false` removes it.
 * ------------------------------------------------------------------------- */

static int env_entry_is(const wchar_t *entry, const wchar_t *name)
{
    size_t n = wcslen(name);
    return _wcsnicmp(entry, name, n) == 0 && entry[n] == L'=';
}

static wchar_t *build_env(lua_State *L, int idx)
{
    WBuf names = { 0 }, out = { 0 };
    lua_pushnil(L);
    while (lua_next(L, idx)) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            size_t n;
            const char *k = lua_tolstring(L, -2, &n);
            wchar_t *wk = to_wide(k, n);
            if (wk) { wb_putn(&names, wk, wcslen(wk)); wb_putc(&names, 0); free(wk); }
        }
        lua_pop(L, 1);
    }

    wchar_t *inherited = GetEnvironmentStringsW();
    for (const wchar_t *e = inherited; e && *e; e += wcslen(e) + 1) {
        int overridden = 0;
        for (const wchar_t *n = names.p; n && n < names.p + names.len; n += wcslen(n) + 1) {
            if (env_entry_is(e, n)) { overridden = 1; break; }
        }
        if (!overridden) { wb_putn(&out, e, wcslen(e)); wb_putc(&out, 0); }
    }
    if (inherited) FreeEnvironmentStringsW(inherited);
    free(names.p);

    lua_pushnil(L);
    while (lua_next(L, idx)) {
        if (lua_type(L, -2) == LUA_TSTRING
            && (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER)) {
            size_t kn, vn;
            const char *k = lua_tolstring(L, -2, &kn);
            lua_pushvalue(L, -1);  /* tolstring on a copy: don't convert the value in place */
            const char *v = lua_tolstring(L, -1, &vn);
            wchar_t *wk = to_wide(k, kn), *wv = to_wide(v, vn);
            if (wk && wv) {
                wb_putn(&out, wk, wcslen(wk));
                wb_putc(&out, L'=');
                wb_putn(&out, wv, wcslen(wv));
                wb_putc(&out, 0);
            }
            free(wk);
            free(wv);
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    wb_putc(&out, 0);  /* the block ends with an extra NUL */
    if (out.oom) { free(out.p); return NULL; }
    return out.p;
}

/* ---------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

static void close_handle(HANDLE *h)
{
    if (*h && *h != INVALID_HANDLE_VALUE) CloseHandle(*h);
    *h = NULL;
}

static int push_win_error(lua_State *L, const char *what)
{
    DWORD e = GetLastError();
    char msg[256] = { 0 };
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, e, 0,
                   msg, sizeof(msg) - 1, NULL);
    size_t n = strlen(msg);
    while (n && (msg[n - 1] == '\n' || msg[n - 1] == '\r' || msg[n - 1] == ' ')) msg[--n] = 0;
    lua_pushnil(L);
    lua_pushfstring(L, "%s failed (%d): %s", what, (int)e, msg);
    return 2;
}

static LProcess *check_proc(lua_State *L)
{
    return (LProcess *)luaL_checkudata(L, 1, PROCESS_MT);
}

/* An anonymous pipe whose child end is inheritable and parent end is not. */
static int make_pipe(HANDLE *parent, HANDLE *child, int child_reads)
{
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE r = NULL, w = NULL;
    if (!CreatePipe(&r, &w, &sa, 0)) return 0;
    *parent = child_reads ? w : r;
    *child = child_reads ? r : w;
    SetHandleInformation(*parent, HANDLE_FLAG_INHERIT, 0);
    return 1;
}

/* ---------------------------------------------------------------------------
 * process.spawn
 * ------------------------------------------------------------------------- */

/*** Start a program.
 *
 * @function spawn
 * @tparam table opts
 * @tparam table opts.argv `{ executable, arg1, ... }`; the executable is searched
 *   on PATH when it has no directory part.
 * @tparam[opt] string opts.cwd Working directory for the child (default: the host's).
 * @tparam[opt] table opts.env Variables to set (string) or remove (`false`) on top
 *   of the host's environment.
 * @tparam[opt] string|boolean opts.stdin A string is written to the child's stdin,
 *   which is then closed (from a background thread, so a child that never reads
 *   can't block the host). `true` opens stdin as a stream that stays open for
 *   `process:write` until `process:close_stdin`. Without it the child's stdin is
 *   empty (NUL).
 * @treturn[1] process The running process.
 * @treturn[2] nil
 * @treturn[2] string Error message.
 * @usage local p, err = process.spawn{ argv = { "python", "-u", "engine.py" }, cwd = dir }
 */
static int l_spawn(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);

    /* argv -> command line */
    lua_getfield(L, 1, "argv");
    if (!lua_istable(L, -1)) return luaL_argerror(L, 1, "opts.argv must be a table");
    int argc = (int)lua_objlen(L, -1);
    if (argc < 1) { lua_pushnil(L); lua_pushstring(L, "opts.argv is empty"); return 2; }
    WBuf cmd = { 0 };
    for (int i = 1; i <= argc; i++) {
        lua_rawgeti(L, -1, i);
        if (lua_type(L, -1) != LUA_TSTRING) {
            free(cmd.p);
            lua_pushnil(L);
            lua_pushfstring(L, "opts.argv[%d] is not a string", i);
            return 2;
        }
        size_t n;
        const char *s = lua_tolstring(L, -1, &n);
        wchar_t *w = to_wide(s, n);
        if (!w) { free(cmd.p); return luaL_error(L, "out of memory"); }
        if (i > 1) wb_putc(&cmd, L' ');
        append_quoted(&cmd, w);
        free(w);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    if (cmd.oom) { free(cmd.p); return luaL_error(L, "out of memory"); }

    wchar_t *cwd = NULL;
    lua_getfield(L, 1, "cwd");
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t n;
        const char *s = lua_tolstring(L, -1, &n);
        cwd = to_wide(s, n);
    }
    lua_pop(L, 1);

    wchar_t *env = NULL;
    lua_getfield(L, 1, "env");
    if (lua_istable(L, -1)) env = build_env(L, lua_gettop(L));
    lua_pop(L, 1);

    StdinFeed *feed = NULL;
    lua_getfield(L, 1, "stdin");
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t n;
        const char *s = lua_tolstring(L, -1, &n);
        feed = (StdinFeed *)calloc(1, sizeof(StdinFeed));
        if (feed) feed->data = (char *)malloc(n ? n : 1);
        if (!feed || !feed->data) {
            free(feed ? feed->data : NULL);
            free(feed);
            free(cmd.p); free(cwd); free(env);
            return luaL_error(L, "out of memory");
        }
        memcpy(feed->data, s, n);
        feed->len = n;
    }
    int want_stream = lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1);
    lua_pop(L, 1);

    /* Allocate the userdata first so every later failure path can just return. */
    LProcess *p = (LProcess *)lua_newuserdata(L, sizeof(LProcess));
    memset(p, 0, sizeof(*p));
    luaL_getmetatable(L, PROCESS_MT);
    lua_setmetatable(L, -2);

    if (want_stream) {
        p->stream = stream_new();   /* released by close/__gc on every later path */
        if (!p->stream) {
            free(cmd.p); free(cwd); free(env);
            return luaL_error(L, "out of memory");
        }
    }

    HANDLE out_w = NULL, err_w = NULL, in_r = NULL;
    int ok = make_pipe(&p->out_r, &out_w, 0) && make_pipe(&p->err_r, &err_w, 0);
    if (ok) {
        if (feed) {
            ok = make_pipe(&feed->pipe, &in_r, 1);
        } else if (p->stream) {
            ok = make_pipe(&p->stream->pipe, &in_r, 1);
        } else {
            SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
            in_r = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                               OPEN_EXISTING, 0, NULL);
            ok = in_r != INVALID_HANDLE_VALUE;
        }
    }

    /* Inherit exactly these three handles and nothing else the host holds. */
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = NULL;
    HANDLE inherit[3] = { in_r, out_w, err_w };
    if (ok) {
        SIZE_T size = 0;
        InitializeProcThreadAttributeList(NULL, 1, 0, &size);
        attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(size);
        ok = attrs && InitializeProcThreadAttributeList(attrs, 1, 0, &size)
            && UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                         inherit, sizeof(inherit), NULL, NULL);
    }

    PROCESS_INFORMATION pi = { 0 };
    int spawned = 0;
    if (ok) {
        STARTUPINFOEXW si;
        memset(&si, 0, sizeof(si));
        si.StartupInfo.cb = sizeof(si);
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = in_r;
        si.StartupInfo.hStdOutput = out_w;
        si.StartupInfo.hStdError = err_w;
        si.lpAttributeList = attrs;
        DWORD flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
                    | EXTENDED_STARTUPINFO_PRESENT;
        spawned = CreateProcessW(NULL, cmd.p, NULL, NULL, TRUE, flags, env, cwd,
                                 &si.StartupInfo, &pi);
    }
    DWORD spawn_error = GetLastError();

    if (attrs) { DeleteProcThreadAttributeList(attrs); free(attrs); }
    free(cmd.p);
    free(cwd);
    free(env);
    /* The child holds its own copies now; ours must close or EOF never arrives. */
    close_handle(&out_w);
    close_handle(&err_w);
    close_handle(&in_r);

    if (!spawned) {
        if (feed) {
            close_handle(&feed->pipe);
            SecureZeroMemory(feed->data, feed->len);
            free(feed->data);
            free(feed);
        }
        SetLastError(ok ? spawn_error : GetLastError());
        return push_win_error(L, ok ? "CreateProcess" : "creating pipes");
    }

    p->process = pi.hProcess;
    p->pid = pi.dwProcessId;

    /* Join a kill-on-close job before the first instruction runs. If that is not
     * possible (the host sits in a job that forbids it), refuse rather than run a
     * process tree we couldn't clean up. */
    p->job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    memset(&info, 0, sizeof(info));
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!p->job
        || !SetInformationJobObject(p->job, JobObjectExtendedLimitInformation, &info, sizeof(info))
        || !AssignProcessToJobObject(p->job, pi.hProcess)) {
        DWORD e = GetLastError();
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hThread);
        if (feed) {
            close_handle(&feed->pipe);
            SecureZeroMemory(feed->data, feed->len);
            free(feed->data);
            free(feed);
        }
        SetLastError(e);
        return push_win_error(L, "placing the process in a job");  /* __gc closes the rest */
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    if (feed) {
        p->stdin_thread = CreateThread(NULL, 0, stdin_writer, feed, 0, NULL);
        if (!p->stdin_thread) {
            /* No thread: the child just sees empty input. Clean up here. */
            close_handle(&feed->pipe);
            SecureZeroMemory(feed->data, feed->len);
            free(feed->data);
            free(feed);
        }
    }
    if (p->stream) {
        InterlockedIncrement(&p->stream->refs);   /* the thread's reference */
        p->stdin_thread = CreateThread(NULL, 0, stream_writer, p->stream, 0, NULL);
        if (!p->stdin_thread) {
            /* No writer: every write would queue for nobody. Close the pipe so the
             * child sees empty input, and let writes report the stream as closed. */
            InterlockedDecrement(&p->stream->refs);
            close_handle(&p->stream->pipe);
            p->stream->done = p->stream->failed = 1;
        }
    }
    return 1;  /* the userdata */
}

/* ---------------------------------------------------------------------------
 * Methods
 * ------------------------------------------------------------------------- */

/*** Read what is available on a stream, without blocking.
 * @function process:read
 * @tparam[opt="stdout"] string stream `"stdout"` or `"stderr"`.
 * @tparam[opt=65536] integer max Most bytes to return.
 * @treturn string|nil The data, `""` when nothing is waiting, or `nil` at end of stream.
 */
static int m_read(lua_State *L)
{
    LProcess *p = check_proc(L);
    const char *which = luaL_optstring(L, 2, "stdout");
    lua_Integer max = luaL_optinteger(L, 3, READ_DEFAULT);
    if (max < 1) max = 1;
    if (max > READ_MAX) max = READ_MAX;

    int is_err = strcmp(which, "stderr") == 0;
    if (!is_err && strcmp(which, "stdout") != 0) return luaL_argerror(L, 2, "stdout or stderr");
    HANDLE h = is_err ? p->err_r : p->out_r;
    int *eof = is_err ? &p->err_eof : &p->out_eof;
    if (*eof || !h) { lua_pushnil(L); return 1; }

    DWORD avail = 0;
    if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
        if (GetLastError() == ERROR_BROKEN_PIPE) { *eof = 1; lua_pushnil(L); return 1; }
        return push_win_error(L, "PeekNamedPipe");
    }
    if (avail == 0) { lua_pushliteral(L, ""); return 1; }

    DWORD want = avail < (DWORD)max ? avail : (DWORD)max, got = 0;
    char *buf = (char *)malloc(want);
    if (!buf) return luaL_error(L, "out of memory");
    BOOL ok = ReadFile(h, buf, want, &got, NULL);
    if (!ok) {
        free(buf);
        if (GetLastError() == ERROR_BROKEN_PIPE) { *eof = 1; lua_pushnil(L); return 1; }
        return push_win_error(L, "ReadFile");
    }
    lua_pushlstring(L, buf, got);
    free(buf);
    return 1;
}

/*** Queue bytes for the child's stdin (a process started with `stdin = true`).
 *
 * Returns at once: a writer thread delivers the bytes in order. A child that has
 * stopped reading can't block the host; its backlog grows instead, up to 64 MB,
 * after which writes are refused. Watch `process:pending` to notice a stall
 * sooner.
 * @function process:write
 * @tparam string data
 * @treturn[1] boolean true once queued
 * @treturn[2] nil
 * @treturn[2] string `"stdin is not a stream"`, `"stdin is closed"` or
 *   `"stdin backlog is full"`
 */
static int m_write(lua_State *L)
{
    LProcess *p = check_proc(L);
    size_t n;
    const char *data = luaL_checklstring(L, 2, &n);
    StdinStream *st = p->stream;
    if (!st) { lua_pushnil(L); lua_pushliteral(L, "stdin is not a stream"); return 2; }
    if (n == 0) { lua_pushboolean(L, 1); return 1; }

    StdinChunk *c = (StdinChunk *)malloc(sizeof(StdinChunk) + n);
    if (!c) return luaL_error(L, "out of memory");
    c->next = NULL;
    c->len = n;
    memcpy(c->data, data, n);

    const char *err = NULL;
    EnterCriticalSection(&st->lock);
    if (st->closing || st->abort || st->failed || st->done) err = "stdin is closed";
    else if (st->queued + n > STDIN_BACKLOG_MAX) err = "stdin backlog is full";
    else {
        if (st->tail) st->tail->next = c; else st->head = c;
        st->tail = c;
        st->queued += n;
    }
    LeaveCriticalSection(&st->lock);
    if (err) {
        free(c);
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
    SetEvent(st->wake);
    lua_pushboolean(L, 1);
    return 1;
}

/*** Bytes accepted by `process:write` that the child has not taken yet.
 * @function process:pending
 * @treturn integer 0 when stdin is not a stream
 */
static int m_pending(lua_State *L)
{
    LProcess *p = check_proc(L);
    size_t queued = 0;
    if (p->stream) {
        EnterCriticalSection(&p->stream->lock);
        queued = p->stream->queued;
        LeaveCriticalSection(&p->stream->lock);
    }
    lua_pushnumber(L, (lua_Number)queued);
    return 1;
}

/*** Finish a stdin stream: what is queued is still delivered, then the child
 * sees end of input. Later writes are refused. Safe to call more than once.
 * @function process:close_stdin
 */
static int m_close_stdin(lua_State *L)
{
    LProcess *p = check_proc(L);
    if (p->stream) {
        EnterCriticalSection(&p->stream->lock);
        p->stream->closing = 1;
        LeaveCriticalSection(&p->stream->lock);
        SetEvent(p->stream->wake);
    }
    return 0;
}

/*** Has the process exited?
 * @function process:poll
 * @treturn integer|nil The exit code, or `nil` while it is running.
 */
static int m_poll(lua_State *L)
{
    LProcess *p = check_proc(L);
    if (!p->process) { lua_pushnil(L); return 1; }
    if (WaitForSingleObject(p->process, 0) != WAIT_OBJECT_0) { lua_pushnil(L); return 1; }
    DWORD code = 0;
    GetExitCodeProcess(p->process, &code);
    lua_pushinteger(L, (lua_Integer)code);
    return 1;
}

/*** End the process and everything it started.
 * @function process:kill
 * @tparam[opt=1] integer code Exit code to give the killed processes.
 * @treturn boolean
 */
static int m_kill(lua_State *L)
{
    LProcess *p = check_proc(L);
    UINT code = (UINT)luaL_optinteger(L, 2, 1);
    BOOL ok = FALSE;
    if (p->job) ok = TerminateJobObject(p->job, code);
    else if (p->process) ok = TerminateProcess(p->process, code);
    lua_pushboolean(L, ok);
    return 1;
}

/*** The process id.
 * @function process:pid
 * @treturn integer
 */
static int m_pid(lua_State *L)
{
    LProcess *p = check_proc(L);
    lua_pushinteger(L, (lua_Integer)p->pid);
    return 1;
}

/*** Release the process. A process still running is ended, with its whole tree
 * (closing the last handle to a kill-on-close job ends everything in it).
 * Safe to call more than once; the finaliser calls it too.
 * @function process:close
 */
static int m_close(lua_State *L)
{
    LProcess *p = (LProcess *)luaL_checkudata(L, 1, PROCESS_MT);
    close_handle(&p->out_r);
    close_handle(&p->err_r);
    if (p->stream) {
        /* Drop what is queued: the process is being ended, not drained. */
        EnterCriticalSection(&p->stream->lock);
        p->stream->abort = 1;
        LeaveCriticalSection(&p->stream->lock);
        SetEvent(p->stream->wake);
    }
    close_handle(&p->job);       /* ends the tree if it is still running */
    close_handle(&p->process);
    if (p->stdin_thread) {
        /* With the child gone its write fails and the thread ends promptly. A
         * write still stuck after that is cancelled; the thread holds its own
         * reference to the stream, so it is safe to stop waiting either way. */
        if (WaitForSingleObject(p->stdin_thread, 2000) != WAIT_OBJECT_0 && p->stream) {
            CancelSynchronousIo(p->stdin_thread);
            WaitForSingleObject(p->stdin_thread, 500);
        }
        close_handle(&p->stdin_thread);
    }
    if (p->stream) {
        stream_release(p->stream);
        p->stream = NULL;
    }
    p->out_eof = p->err_eof = 1;
    return 0;
}

static int m_tostring(lua_State *L)
{
    LProcess *p = check_proc(L);
    lua_pushfstring(L, "process (pid %d)", (int)p->pid);
    return 1;
}

static const luaL_Reg methods[] = {
    { "read",        m_read },
    { "write",       m_write },
    { "pending",     m_pending },
    { "close_stdin", m_close_stdin },
    { "poll",        m_poll },
    { "kill",        m_kill },
    { "pid",         m_pid },
    { "close",       m_close },
    { NULL, NULL }
};

static const luaL_Reg functions[] = {
    { "spawn", l_spawn },
    { NULL, NULL }
};

int luaopen_process(lua_State *L)
{
    if (luaL_newmetatable(L, PROCESS_MT)) {
        lua_newtable(L);
        luaL_register(L, NULL, methods);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, m_close);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, m_tostring);
        lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1);
    lua_newtable(L);
    luaL_register(L, NULL, functions);
    return 1;
}
