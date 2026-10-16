#include "subprocess_wrap.h"
#include <lua.h>
#include <lauxlib.h>
#include <subprocess.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>

/* LuaJIT is Lua 5.1 ABI and provides lua_objlen rather than the 5.2+ lua_rawlen.
 * Map lua_rawlen to lua_objlen when building against a runtime that lacks it. */
#if !defined(lua_rawlen) && (!defined(LUA_VERSION_NUM) || LUA_VERSION_NUM < 502)
#define lua_rawlen(L, i) lua_objlen((L), (i))
#endif

/* Process-lifetime ownership via a Windows Job Object.
 *
 * Windows does not terminate child processes when their parent exits, so a CLI
 * spawned by a plugin (and anything that CLI spawns) can outlive the host Lunar
 * process and get "stuck" running. To fix this we place every spawned child in
 * a single kill-on-close job object owned by this process. The job handle is
 * held for the lifetime of the process, so when Lunar exits for ANY reason
 * (clean exit, crash, or being killed), Windows closes the handle and
 * automatically terminates every process in the job, including descendants.
 */
static HANDLE g_job = NULL;

/* Lazily create the shared kill-on-close job object. Returns NULL on failure. */
static HANDLE get_kill_on_close_job(void)
{
    if (g_job != NULL) {
        return g_job;
    }

    HANDLE job = CreateJobObjectA(NULL, NULL);
    if (job == NULL) {
        return NULL;
    }

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    ZeroMemory(&info, sizeof(info));
    /* KILL_ON_JOB_CLOSE terminates all processes in the job when the last
     * handle to the job is closed, i.e. when this process dies. BREAKAWAY_OK
     * lets a deliberately-detached child (see l_start_detached) escape the job
     * so it can outlive the host — required for the self-update relauncher. */
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                                          | JOB_OBJECT_LIMIT_BREAKAWAY_OK;

    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &info, sizeof(info))) {
        CloseHandle(job);
        return NULL;
    }

    g_job = job;
    return g_job;
}

/* Assign a freshly created child process to the kill-on-close job.
 *
 * Best-effort: a failure here must not abort the spawn, since the process is
 * already running. Assignment can legitimately fail on older systems where the
 * child is already part of a job that disallows nesting; on Windows 8+ nested
 * jobs are supported so this normally succeeds.
 */
static void assign_to_job(HANDLE hProcess)
{
    if (hProcess == NULL || hProcess == INVALID_HANDLE_VALUE) {
        return;
    }
    HANDLE job = get_kill_on_close_job();
    if (job != NULL) {
        AssignProcessToJobObject(job, hProcess);
    }
}

/*** Spawn and manage child processes for Windows.
 *
 * Wraps the `subprocess.h` single-header library with a Windows-native
 * kill-on-close Job Object so that every spawned child (and its
 * descendants) is automatically terminated when the Lunar host exits,
 * preventing orphaned processes.
 *
 * @module subprocess
 */

/* subprocess.start(bat_filename, cwd)
 * Spawns: cmd.exe /C <bat_filename> with the given working directory.
 * Returns lightuserdata handle on success, or nil + error string on failure.
 */
/*** Spawn a batch file via `cmd.exe /C`.
 *
 * Changes the working directory to `cwd` before spawning, then restores it.
 * stdout and stderr are merged into a single async-readable stream.
 * The child is added to a kill-on-close Job Object so it is terminated if
 * the host process exits for any reason.
 *
 * @function start
 * @tparam  string bat_filename  Path to the `.bat` file to execute.
 * @tparam  string cwd           Working directory for the child process.
 * @treturn lightuserdata        Opaque process handle on success.
 * @treturn nil                  `nil` on failure.
 * @treturn string               Error message on failure.
 * @usage
 *   local h, err = subprocess.start("build.bat", "C:\\project")
 *   if not h then error(err) end
 */
static int l_start(lua_State *L)
{
    const char *bat = luaL_checkstring(L, 1);
    const char *cwd = luaL_checkstring(L, 2);

    /* Save current directory so we can restore it after spawn */
    char saved_cwd[MAX_PATH];
    GetCurrentDirectoryA(MAX_PATH, saved_cwd);

    if (!SetCurrentDirectoryA(cwd)) {
        lua_pushnil(L);
        lua_pushfstring(L, "SetCurrentDirectory failed for: %s", cwd);
        return 2;
    }

    const char *args[] = { "cmd.exe", "/C", bat, NULL };

    struct subprocess_s *proc = (struct subprocess_s *)malloc(sizeof(struct subprocess_s));
    if (!proc) {
        SetCurrentDirectoryA(saved_cwd);
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }

    int opts = subprocess_option_inherit_environment
             | subprocess_option_combined_stdout_stderr
             | subprocess_option_enable_async
             | subprocess_option_enable_async_no_wait
             | subprocess_option_no_window;

    int rc = subprocess_create(args, opts, proc);
    SetCurrentDirectoryA(saved_cwd);

    if (rc != 0) {
        free(proc);
        lua_pushnil(L);
        lua_pushstring(L, "subprocess_create failed");
        return 2;
    }

    /* Tie the child's lifetime to this process so it can't be orphaned. */
    assign_to_job(proc->hProcess);

    lua_pushlightuserdata(L, proc);
    return 1;
}

/* subprocess.poll(handle)
 * Returns nil if process is still running, or integer exit code if finished.
 */
/*** Check whether a child process has finished (non-blocking).
 *
 * If the process is still running, returns `nil`. When the process has
 * exited, joins it and returns its integer exit code.
 *
 * @function poll
 * @tparam  lightuserdata handle  Handle returned by `start` or `start_argv`.
 * @treturn nil                   Process is still running.
 * @treturn integer               Exit code when the process has finished.
 * @usage
 *   local code = subprocess.poll(h)
 *   if code then print("exited:", code) end
 */
static int l_poll(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    struct subprocess_s *proc = (struct subprocess_s *)lua_touserdata(L, 1);

    if (subprocess_alive(proc)) {
        lua_pushnil(L);
        return 1;
    }

    int exit_code = 0;
    subprocess_join(proc, &exit_code);
    lua_pushinteger(L, exit_code);
    return 1;
}

/* subprocess.destroy(handle)
 * Frees the subprocess struct. Call after poll() returns non-nil.
 */
/*** Free the process handle after the process has finished.
 *
 * Releases the C-side memory allocated for the process. Call this after
 * `poll` has returned a non-`nil` exit code. The handle must not be used
 * after calling `destroy`.
 *
 * @function destroy
 * @tparam lightuserdata handle  Handle returned by `start` or `start_argv`.
 * @usage
 *   local code = subprocess.poll(h)
 *   if code then subprocess.destroy(h) end
 */
static int l_destroy(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    struct subprocess_s *proc = (struct subprocess_s *)lua_touserdata(L, 1);
    subprocess_destroy(proc);
    free(proc);
    return 0;
}

/* subprocess.terminate(handle)
 * Forces a running process to exit. Returns true on success, or nil+error.
 */
/*** Forcibly terminate a running process.
 *
 * Sends a termination signal to the process. Has no effect if the process
 * has already exited.
 *
 * @function terminate
 * @tparam  lightuserdata handle  Handle returned by `start` or `start_argv`.
 * @treturn boolean               `true` on success.
 * @treturn nil                   `nil` on failure.
 * @treturn string                Error message on failure.
 * @usage
 *   local ok, err = subprocess.terminate(h)
 *   if not ok then print("terminate failed:", err) end
 */
static int l_terminate(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    struct subprocess_s *proc = (struct subprocess_s *)lua_touserdata(L, 1);

    int rc = subprocess_terminate(proc);
    if (rc != 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "subprocess_terminate failed (%d)", rc);
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

/* subprocess.read_stdout(handle)
 * Non-blocking read of available stdout+stderr data.
 * Returns a string (possibly empty if no data available yet).
 */
/*** Read available output from the process's stdout/stderr stream.
 *
 * Non-blocking. Returns whatever data is currently in the async read
 * buffer (stdout and stderr are merged). Returns an empty string if no
 * data is available yet. Call repeatedly while `poll` returns `nil` to
 * drain the full output.
 *
 * @function read_stdout
 * @tparam  lightuserdata handle  Handle returned by `start` or `start_argv`.
 * @treturn string                Output data, possibly an empty string.
 * @usage
 *   local out = subprocess.read_stdout(h)
 *   if #out > 0 then io.write(out) end
 */
static int l_read_stdout(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    struct subprocess_s *proc = (struct subprocess_s *)lua_touserdata(L, 1);

    char buf[4096];
    unsigned bytes_read = subprocess_read_stdout(proc, buf, sizeof(buf) - 1);
    if (bytes_read > 0) {
        lua_pushlstring(L, buf, bytes_read);
    } else {
        lua_pushliteral(L, "");
    }
    return 1;
}

/* subprocess.start_argv({ "prog", "arg1", ... }, cwd)
 * Spawns the program directly (no cmd.exe), taking a Lua array of arguments where
 * the first element is the executable. Each argument is passed verbatim and quoted
 * by the subprocess layer, so paths/arguments containing spaces are handled safely.
 * Returns lightuserdata handle on success, or nil + error string on failure.
 */
/*** Spawn a program directly (no `cmd.exe` shell) from an argument array.
 *
 * The first element of `argv` is the executable; subsequent elements are
 * arguments. Each argument is quoted by the subprocess layer so paths and
 * values containing spaces are handled safely.
 * The child is added to the kill-on-close Job Object.
 *
 * @function start_argv
 * @tparam  table  argv  Array of strings `{ executable, arg1, arg2, ... }`.
 * @tparam  string cwd   Working directory for the child process.
 * @treturn lightuserdata        Opaque process handle on success.
 * @treturn nil                  `nil` on failure.
 * @treturn string               Error message on failure.
 * @usage
 *   local h, err = subprocess.start_argv({"git", "pull"}, "C:\\repo")
 *   if not h then error(err) end
 */
static int l_start_argv(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    const char *cwd = luaL_checkstring(L, 2);

    int argc = (int)lua_rawlen(L, 1);
    if (argc < 1) {
        lua_pushnil(L);
        lua_pushstring(L, "argv table is empty");
        return 2;
    }

    /* Build a NULL-terminated argv array from the Lua table (1-based). */
    const char **args = (const char **)malloc(sizeof(char *) * (size_t)(argc + 1));
    if (!args) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    for (int i = 0; i < argc; i++) {
        lua_rawgeti(L, 1, i + 1);
        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_pop(L, 1);
            free(args);
            lua_pushnil(L);
            lua_pushfstring(L, "argv[%d] is not a string", i + 1);
            return 2;
        }
        args[i] = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    args[argc] = NULL;

    /* Save and switch the working directory for the spawn, then restore. */
    char saved_cwd[MAX_PATH];
    GetCurrentDirectoryA(MAX_PATH, saved_cwd);

    if (!SetCurrentDirectoryA(cwd)) {
        free(args);
        lua_pushnil(L);
        lua_pushfstring(L, "SetCurrentDirectory failed for: %s", cwd);
        return 2;
    }

    struct subprocess_s *proc = (struct subprocess_s *)malloc(sizeof(struct subprocess_s));
    if (!proc) {
        SetCurrentDirectoryA(saved_cwd);
        free(args);
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }

    int opts = subprocess_option_inherit_environment
             | subprocess_option_combined_stdout_stderr
             | subprocess_option_enable_async
             | subprocess_option_enable_async_no_wait
             | subprocess_option_no_window;

    int rc = subprocess_create(args, opts, proc);
    SetCurrentDirectoryA(saved_cwd);
    free(args);

    if (rc != 0) {
        free(proc);
        lua_pushnil(L);
        lua_pushstring(L, "subprocess_create failed");
        return 2;
    }

    /* Tie the child's lifetime to this process so it can't be orphaned. */
    assign_to_job(proc->hProcess);

    lua_pushlightuserdata(L, proc);
    return 1;
}

/* subprocess.start_detached(command, cwd)
 * Spawns a fire-and-forget process that is DELIBERATELY NOT tied to this
 * process's kill-on-close job object, so it survives the host exiting. This is
 * used by the self-update flow: the host launches a detached relauncher and then
 * exits, and the relauncher must keep running to install the update and reopen
 * the app.
 *
 * `command` is passed to cmd.exe /C, so it may be any shell command line
 * (e.g. the path to a generated .bat). Returns true on success, or nil + error.
 */
/*** Spawn a fire-and-forget process that outlives the host.
 *
 * Unlike `start` and `start_argv`, the child is **not** placed in the
 * kill-on-close Job Object, so it continues running after the Lunar host
 * exits. This is used by the self-update flow: a detached relauncher
 * installs the update and reopens the application after the host exits.
 *
 * `command` is passed to `cmd.exe /C`, so it may be any shell command
 * line (e.g. a path to a generated `.bat` file).
 *
 * @function start_detached
 * @tparam  string  command      Shell command line to execute.
 * @tparam[opt] string cwd       Working directory; defaults to the current
 *                               directory when omitted.
 * @treturn boolean              `true` on success.
 * @treturn nil                  `nil` on failure.
 * @treturn string               Error message on failure.
 * @usage
 *   local ok, err = subprocess.start_detached("updater.bat", "C:\\update")
 *   if not ok then error(err) end
 */
static int l_start_detached(lua_State *L)
{
    const char *command = luaL_checkstring(L, 1);
    const char *cwd = luaL_optstring(L, 2, NULL);

    /* Build: cmd.exe /C <command>. CreateProcess may modify the command buffer,
     * so use a writable copy. */
    size_t cmdlen = strlen(command);
    size_t buflen = cmdlen + 32;
    char *cmdline = (char *)malloc(buflen);
    if (!cmdline) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }
    _snprintf(cmdline, buflen, "cmd.exe /C %s", command);
    cmdline[buflen - 1] = '\0';

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    /* CREATE_BREAKAWAY_FROM_JOB lets the child escape any kill-on-close job so it
     * outlives the host. CREATE_NO_WINDOW hides the transient cmd console. */
    DWORD flags = CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;

    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                             flags, NULL, cwd, &si, &pi);

    /* If breakaway is not permitted (e.g. the host runs under a job that forbids
     * it), retry without the breakaway flag. */
    if (!ok) {
        _snprintf(cmdline, buflen, "cmd.exe /C %s", command);
        cmdline[buflen - 1] = '\0';
        flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;
        ok = CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                            flags, NULL, cwd, &si, &pi);
    }

    free(cmdline);

    if (!ok) {
        lua_pushnil(L);
        lua_pushfstring(L, "CreateProcess failed (%d)", (int)GetLastError());
        return 2;
    }

    /* Intentionally do NOT assign to the kill-on-close job. Close handles so we
     * don't retain any ownership of the detached process. */
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    lua_pushboolean(L, 1);
    return 1;
}

static const luaL_Reg subprocess_lib[] = {
    { "start",         l_start         },
    { "start_argv",    l_start_argv    },
    { "start_detached", l_start_detached },
    { "poll",          l_poll          },
    { "terminate",     l_terminate     },
    { "read_stdout",   l_read_stdout   },
    { "destroy",       l_destroy       },
    { NULL,            NULL            }
};

int luaopen_subprocess(lua_State *L)
{
    luaL_newlib(L, subprocess_lib);
    return 1;
}
