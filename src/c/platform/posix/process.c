/*** Child processes with separate, non-blocking output streams (POSIX/Linux).
 *
 * Programs receive an argv array, never a shell command. A bare executable is
 * resolved against the host's PATH before the child changes directory or env.
 * The child's cwd and environment do not change the host. stdout and stderr
 * are separate; read returns "" while open and empty, nil at EOF.
 *
 * A supervisor acts as a child subreaper. The child owns a separate process
 * group; the supervisor kills that group and reaps its descendants when the
 * host closes the lifeline, including after host death. Escaped process-group
 * members are also killed while they remain descendants of the subreaper.
 * A daemon reparented elsewhere is beyond the supervisor's reach.
 *
 * If the supervisor itself is killed from outside, the host ends the child's
 * group directly, but only after checking (pgid and start time in /proc) that
 * the group leader is still the process it started. When the leader has
 * already exited, that can't be verified and the host leaves any remaining
 * grandchildren alone rather than risk signalling a reused process group.
 *
 * @module process
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <lua.h>
#include <lauxlib.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
#define PROCESS_MT "lunar.process"
#define READ_DEFAULT 65536
#define READ_MAX (1024 * 1024)

enum { REC_PID = 1, REC_EXIT = 2, REC_ERROR = 3, REC_KILLED = 4 };
enum { ERR_SETUP = 1, ERR_CHDIR = 2, ERR_EXEC = 3 };
typedef struct { int type, value; } Record;
typedef struct { int stage, error; } ExecError;
typedef struct {
    pid_t supervisor, pid;
    int out_r, err_r, status_r, lifeline_w;
    int out_eof, err_eof, status_bytes, has_exit, exit_code;
    int kill_code, kill_requested, fallback_killed, reaped, supervisor_clean, exit_killed;
    unsigned long long child_start_time;
    unsigned char status_buf[sizeof(Record)];
} LProcess;
typedef struct { int fd; char *data; size_t len; } StdinFeed;

static void fd_close(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }
static void wipe(void *p, size_t n) { volatile unsigned char *v = p; while (n--) *v++ = 0; }
static void free_feed(StdinFeed *f)
{
    if (!f) return;
    fd_close(&f->fd);
    if (f->data) wipe(f->data, f->len);
    free(f->data);
    free(f);
}
static void *stdin_writer(void *arg)
{
    StdinFeed *f = arg;
    size_t off = 0;
    while (off < f->len) {
        ssize_t n = write(f->fd, f->data + off, f->len - off);
        if (n > 0) off += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else break; /* EPIPE is normal when the child exits or ignores input. */
    }
    free_feed(f);
    return NULL;
}
static int error_result(lua_State *L, const char *reason, int err)
{
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", reason, strerror(err));
    return 2;
}
static int set_nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}
static int make_pipe(int p[2]) { return pipe2(p, O_CLOEXEC) == 0; }
static int write_all(int fd, const void *data, size_t len)
{
    const char *p = data;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n > 0) { p += n; len -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else return 0;
    }
    return 1;
}
static int read_record(int fd, void *data, size_t len)
{
    char *p = data;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n > 0) { p += n; len -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else return n == 0 ? 0 : -1;
    }
    return 1;
}
static int valid_string(const char *s, size_t n) { return strlen(s) == n; }
static char *string_copy(const char *s, size_t n)
{
    char *out = malloc(n + 1);
    if (out) { memcpy(out, s, n); out[n] = 0; }
    return out;
}
static void free_strings(char **v)
{
    if (!v) return;
    for (size_t i = 0; v[i]; i++) free(v[i]);
    free(v);
}
static char **build_env(lua_State *L, int idx)
{
    size_t inherited = 0, overrides = 0;
    while (environ[inherited]) inherited++;
    lua_pushnil(L);
    while (lua_next(L, idx)) { overrides++; lua_pop(L, 1); }
    char **env = calloc(inherited + overrides + 1, sizeof(char *));
    if (!env) return NULL;
    size_t count = 0;
    for (size_t i = 0; i < inherited; i++) {
        const char *entry = environ[i];
        const char *eq = strchr(entry, '=');
        int overridden = 0;
        if (eq) {
            lua_pushlstring(L, entry, (size_t)(eq - entry));
            lua_rawget(L, idx);
            overridden = !lua_isnil(L, -1);
            lua_pop(L, 1);
        }
        if (!overridden) {
            env[count] = strdup(entry);
            if (!env[count++]) { free_strings(env); return NULL; }
        }
    }
    lua_pushnil(L);
    while (lua_next(L, idx)) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TSTRING) {
            size_t kn, vn;
            const char *key = lua_tolstring(L, -2, &kn);
            const char *val = lua_tolstring(L, -1, &vn);
            if (!kn || memchr(key, '=', kn) || !valid_string(key, kn) || !valid_string(val, vn)) {
                lua_pop(L, 1); free_strings(env); return NULL;
            }
            char *entry = malloc(kn + vn + 2);
            if (!entry) { lua_pop(L, 1); free_strings(env); return NULL; }
            memcpy(entry, key, kn); entry[kn] = '=';
            memcpy(entry + kn + 1, val, vn); entry[kn + vn + 1] = 0;
            env[count++] = entry;
        }
        lua_pop(L, 1);
    }
    return env;
}
/* Host PATH lookup. Resolve each relative PATH component before child chdir. */
static char *find_executable(const char *name, int *err)
{
    if (strchr(name, '/')) {
        if (name[0] == '/') return strdup(name);
        char *cwd = getcwd(NULL, 0);
        if (!cwd) { *err = errno; return NULL; }
        size_t n = strlen(cwd), m = strlen(name);
        char *absolute = malloc(n + m + 2);
        if (!absolute) { free(cwd); *err = ENOMEM; return NULL; }
        memcpy(absolute, cwd, n);
        absolute[n] = '/';
        memcpy(absolute + n + 1, name, m + 1);
        free(cwd);
        return absolute;
    }
    const char *path = getenv("PATH");
    if (!path) path = "/bin:/usr/bin";
    char *cwd = getcwd(NULL, 0);
    if (!cwd) { *err = errno; return NULL; }
    int denied = 0;
    for (const char *part = path;;) {
        const char *end = strchr(part, ':');
        size_t n = end ? (size_t)(end - part) : strlen(part);
        const char *base = n ? part : cwd;
        size_t blen = n ? n : strlen(cwd);
        int absolute = base[0] == '/';
        size_t prefix = absolute ? 0 : strlen(cwd) + 1;
        char *candidate = malloc(prefix + blen + strlen(name) + 2);
        if (!candidate) { free(cwd); *err = ENOMEM; return NULL; }
        size_t off = 0;
        if (prefix) { memcpy(candidate, cwd, prefix - 1); off = prefix - 1; candidate[off++] = '/'; }
        memcpy(candidate + off, base, blen); off += blen;
        candidate[off++] = '/'; strcpy(candidate + off, name);
        struct stat st;
        if (stat(candidate, &st) == 0 && S_ISREG(st.st_mode)) {
            if (access(candidate, X_OK) == 0) { free(cwd); return candidate; }
            if (errno == EACCES) denied = 1;
        }
        free(candidate);
        if (!end) break;
        part = end + 1;
    }
    free(cwd);
    *err = denied ? EACCES : ENOENT;
    return NULL;
}
/* These functions run only after fork: libc allocation, Lua and pthread APIs
 * are deliberately absent. The source descriptors are duplicated above 15 by
 * the parent, making the fixed-descriptor dup2 sequence collision-free. */
static void child_error(int stage, int error)
{
    ExecError e = { stage, error };
    write_all(3, &e, sizeof(e));
    _exit(127);
}
static int close_extras(unsigned int first, unsigned int limit)
{
    if (close_range(first, ~0U, 0) == 0) return 1;
    if (limit == 0 || limit < first) return 0;
    for (unsigned int fd = first; fd < limit; fd++)
        if (close((int)fd) < 0 && errno != EBADF) return 0;
    return 1;
}
/* A lowered hard limit can be below fds that were already open. Include those
 * in the pre-fork bound; if /proc cannot be inspected, disallow the fallback. */
static unsigned int parent_fd_limit(void)
{
    struct rlimit nofile;
    if (getrlimit(RLIMIT_NOFILE, &nofile) < 0 || nofile.rlim_max == RLIM_INFINITY ||
        nofile.rlim_max > (rlim_t)INT_MAX + 1) return 0;
    unsigned int limit = (unsigned int)nofile.rlim_max;
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) return 0;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        char *end;
        unsigned long fd = strtoul(entry->d_name, &end, 10);
        if (*end == 0 && fd <= INT_MAX && fd + 1 > limit) limit = (unsigned int)(fd + 1);
        errno = 0;
    }
    int read_error = errno;
    closedir(dir);
    return read_error ? 0 : limit;
}
static void supervisor_error(int error)
{
    Record r = { REC_ERROR, error };
    write_all(4, &r, sizeof(r));
    _exit(127);
}
static int reset_dispositions(void)
{
    struct sigaction action = { .sa_handler = SIG_DFL };
    sigemptyset(&action.sa_mask);
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig == SIGKILL || sig == SIGSTOP) continue;
        if (sigaction(sig, &action, NULL) < 0 && errno != EINVAL) return 0;
    }
    return 1;
}
static int clear_signal_mask(void)
{
    sigset_t empty;
    sigemptyset(&empty);
    return sigprocmask(SIG_SETMASK, &empty, NULL) == 0;
}
static int supervisor_signal_mask(void)
{
    sigset_t blocked;
    sigfillset(&blocked);
    sigdelset(&blocked, SIGCHLD);
    sigdelset(&blocked, SIGCONT);
    return sigprocmask(SIG_SETMASK, &blocked, NULL) == 0;
}
static int64_t monotonic_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
/* Only direct children are signalled: their PIDs cannot be reused until reaped. */
static void kill_direct_children(void)
{
    char path[64] = "/proc/self/task/";
    char digits[24];
    unsigned int pid = (unsigned int)getpid();
    int count = 0;
    do { digits[count++] = (char)('0' + pid % 10); pid /= 10; } while (pid);
    size_t pos = sizeof("/proc/self/task/") - 1;
    while (count) path[pos++] = digits[--count];
    const char suffix[] = "/children";
    for (size_t i = 0; i < sizeof(suffix); i++) path[pos++] = suffix[i];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char buf[4096];
    pid_t child = 0;
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] >= '0' && buf[i] <= '9') child = child * 10 + (buf[i] - '0');
            else if (child > 0) { kill(child, SIGKILL); child = 0; }
        }
    }
    if (child > 0) kill(child, SIGKILL);
    close(fd);
}
static void cleanup_descendants(pid_t child, int direct_done, int killed)
{
    /* The unreaped leader pins its PID and PGID. Never use a stale PGID. */
    if (!direct_done) kill(-child, SIGKILL);
    int64_t deadline = monotonic_ms() + 2000;
    for (unsigned int attempts = 0; attempts < 200; attempts++) {
        kill_direct_children();
        int status;
        pid_t got;
        while ((got = waitpid(-1, &status, WNOHANG)) > 0) {
            if (got == child) {
                Record r = { killed ? REC_KILLED : REC_EXIT, status };
                write_all(4, &r, sizeof(r));
                direct_done = 1;
            }
        }
        if (got < 0 && errno == ECHILD) return;
        if (monotonic_ms() >= deadline) break;
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
        nanosleep(&delay, NULL);
    }
    static const char message[] = "process supervisor: descendant cleanup timed out\n";
    ssize_t reported = write(2, message, sizeof(message) - 1);
    (void)reported;
    _exit(127);
}
static void supervisor_run(pid_t host_pid, unsigned int fd_limit,
                           const int fixed[6], const char *exe,
                           char *const argv[], char *const env[], const char *cwd)
{
    if (prctl(PR_SET_PDEATHSIG, SIGCONT) < 0 || getppid() != host_pid) _exit(127);
    for (int i = 0; i < 6; i++) if (dup2(fixed[i], 3 + i) < 0) _exit(127);
    if (!close_extras(9, fd_limit)) supervisor_error(errno ? errno : EIO);
    if (!reset_dispositions() || prctl(PR_SET_CHILD_SUBREAPER, 1) < 0 ||
        !supervisor_signal_mask()) supervisor_error(errno);
    pid_t child = _Fork();
    if (child < 0) supervisor_error(errno);
    if (child == 0) {
        if (dup2(5, 3) < 0 || fcntl(3, F_SETFD, FD_CLOEXEC) < 0 ||
            dup2(6, 0) < 0 || dup2(7, 1) < 0 || dup2(8, 2) < 0)
            child_error(ERR_SETUP, errno);
        if (!close_extras(4, fd_limit)) child_error(ERR_SETUP, errno ? errno : EIO);
        if (setpgid(0, 0) < 0) child_error(ERR_SETUP, errno);
        if (cwd && chdir(cwd) < 0) child_error(ERR_CHDIR, errno);
        if (!reset_dispositions() || !clear_signal_mask()) child_error(ERR_SETUP, errno);
        execve(exe, argv, env);
        child_error(ERR_EXEC, errno);
    }
    if (setpgid(child, child) < 0 && errno != EACCES && errno != ESRCH) {
        int error = errno;
        kill(child, SIGKILL);
        cleanup_descendants(child, 0, 0);
        supervisor_error(error);
    }
    Record r = { REC_PID, (int)child };
    if (!write_all(4, &r, sizeof(r))) {
        cleanup_descendants(child, 0, 0); _exit(127);
    }
    close(5); close(6); close(7); close(8);
    int direct_done = 0;
    for (;;) {
        int status;
        pid_t got;
        while ((got = waitpid(-1, &status, WNOHANG)) > 0) {
            if (got == child) {
                Record exit_record = { REC_EXIT, status };
                write_all(4, &exit_record, sizeof(exit_record));
                direct_done = 1;
            }
        }
        struct pollfd watch = { .fd = 3, .events = POLLIN | POLLHUP };
        int ready = poll(&watch, 1, direct_done ? 100 : 20);
        if (ready > 0 && (watch.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
            char b;
            ssize_t n = read(3, &b, 1);
            if (n == 0 || n > 0 || (n < 0 && errno != EINTR)) {
                /* Check for an already exited child before classifying a kill. */
                if (!direct_done) {
                    got = waitpid(child, &status, WNOHANG);
                    if (got == child) {
                        Record exit_record = { REC_EXIT, status };
                        write_all(4, &exit_record, sizeof(exit_record));
                        direct_done = 1;
                    }
                }
                cleanup_descendants(child, direct_done, !direct_done && n > 0);
                _exit(0);
            }
        }
    }
}
static void drain_status(LProcess *p)
{
    if (p->status_r < 0) return;
    for (;;) {
        ssize_t n = read(p->status_r, p->status_buf + p->status_bytes,
                         sizeof(Record) - (size_t)p->status_bytes);
        if (n > 0) {
            p->status_bytes += (int)n;
            if (p->status_bytes != (int)sizeof(Record)) continue;
            Record r; memcpy(&r, p->status_buf, sizeof(r)); p->status_bytes = 0;
            if ((r.type == REC_EXIT || r.type == REC_KILLED) && !p->has_exit) {
                p->exit_code = WIFEXITED(r.value) ? WEXITSTATUS(r.value) :
                    WIFSIGNALED(r.value) ? 128 + WTERMSIG(r.value) : 128 + SIGKILL;
                p->exit_killed = r.type == REC_KILLED;
                p->has_exit = 1;
            }
        } else if (n < 0 && errno == EINTR) continue;
        else { if (n == 0) fd_close(&p->status_r); break; }
    }
}
static void reap_supervisor(LProcess *p, int blocking)
{
    if (p->supervisor <= 0 || p->reaped) return;
    int status;
    pid_t got;
    do { got = waitpid(p->supervisor, &status, blocking ? 0 : WNOHANG); }
    while (got < 0 && errno == EINTR);
    if (got == p->supervisor) {
        p->supervisor_clean = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        p->reaped = 1;
    } else if (got < 0 && errno == ECHILD) p->reaped = 1;
}
/* /proc stat has a parenthesized comm field, which can contain spaces. */
static int process_identity(pid_t pid, pid_t *group, unsigned long long *start)
{
    char path[64], buf[4096];
    int len = snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    if (len < 0 || (size_t)len >= sizeof(path)) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n;
    do { n = read(fd, buf, sizeof(buf) - 1); } while (n < 0 && errno == EINTR);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    char *p = strrchr(buf, ')');
    if (!p || p[1] != ' ') return 0;
    p += 2;
    for (int field = 3; field <= 22; field++) {
        char *end = strchr(p, ' ');
        if (!end) end = p + strlen(p);
        if (field == 5 || field == 22) {
            errno = 0;
            char *parsed;
            unsigned long long value = strtoull(p, &parsed, 10);
            if (errno || parsed != end) return 0;
            if (field == 5) *group = (pid_t)value;
            else *start = value;
        }
        if (field < 22 && *end != ' ') return 0;
        p = end + 1;
    }
    return 1;
}
static int fallback_kill(LProcess *p)
{
    pid_t group = 0;
    unsigned long long start = 0;
    /* A reaped leader can release its PGID for reuse. Verify both identity
     * fields before signalling a group after unexpected supervisor death. */
    if (p->pid <= 0 || !p->child_start_time ||
        !process_identity(p->pid, &group, &start) ||
        group != p->pid || start != p->child_start_time) return 0;
    return kill(-p->pid, SIGKILL) == 0;
}
static void close_process(LProcess *p)
{
    fd_close(&p->out_r); fd_close(&p->err_r);
    if (p->supervisor > 0) {
        fd_close(&p->lifeline_w);
        int64_t deadline = monotonic_ms() + 2000;
        for (unsigned int attempts = 0;
             !p->reaped && attempts < 200 && monotonic_ms() < deadline; attempts++) {
            reap_supervisor(p, 0);
            if (!p->reaped) {
                struct timespec delay = { .tv_sec = 0, .tv_nsec = 10000000 };
                nanosleep(&delay, NULL);
            }
        }
        if (!p->reaped) kill(p->supervisor, SIGKILL);
        if (!p->supervisor_clean) fallback_kill(p);
        if (!p->reaped) reap_supervisor(p, 1);
    }
    fd_close(&p->status_r);
    fd_close(&p->lifeline_w);
    p->supervisor = 0;
    p->out_eof = p->err_eof = 1;
}
static LProcess *check_proc(lua_State *L) { return luaL_checkudata(L, 1, PROCESS_MT); }

/*** Start a program.
 * @function spawn
 * @tparam table opts
 * @tparam table opts.argv `{ executable, arg1, ... }`; bare executables use the host PATH.
 * @tparam[opt] string opts.cwd Child working directory.
 * @tparam[opt] table opts.env String values set, `false` removes, over the host env.
 * @tparam[opt] string opts.stdin Written and closed by a background thread.
 *   Without it, stdin is empty (/dev/null).
 * @treturn[1] process The running process.
 * @treturn[2] nil
 * @treturn[2] string Error message.
 * @usage local p, err = process.spawn{ argv = { "python", "-u", "engine.py" }, cwd = dir }
 */
static int l_spawn(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    int rc = 2, err = 0;
    const char *reason = "spawn";
    char **argv = NULL, **env = NULL, *exe = NULL, *cwd = NULL;
    StdinFeed *feed = NULL;
    int out[2] = {-1,-1}, serr[2] = {-1,-1}, in[2] = {-1,-1};
    int status[2] = {-1,-1}, life[2] = {-1,-1}, execerr[2] = {-1,-1};
    int fixed[6] = {-1,-1,-1,-1,-1,-1};
    LProcess *p = lua_newuserdata(L, sizeof(*p));
    memset(p, 0, sizeof(*p));
    p->out_r = p->err_r = p->status_r = p->lifeline_w = -1;
    luaL_getmetatable(L, PROCESS_MT); lua_setmetatable(L, -2);
    lua_getfield(L, 1, "argv");
    if (!lua_istable(L, -1)) return luaL_argerror(L, 1, "opts.argv must be a table");
    int argc = (int)lua_objlen(L, -1);
    if (argc < 1) { lua_pushnil(L); lua_pushliteral(L, "opts.argv is empty"); return 2; }
    argv = calloc((size_t)argc + 1, sizeof(char *));
    if (!argv) { err = ENOMEM; goto cleanup; }
    for (int i = 1; i <= argc; i++) {
        lua_rawgeti(L, -1, i);
        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_pushnil(L); lua_pushfstring(L, "opts.argv[%d] is not a string", i); rc = 2;
            goto cleanup;
        }
        size_t n; const char *s = lua_tolstring(L, -1, &n);
        if (!valid_string(s, n)) { err = EINVAL; reason = "argv"; goto cleanup; }
        argv[i-1] = string_copy(s, n);
        if (!argv[i-1]) { err = ENOMEM; goto cleanup; }
        lua_pop(L, 1);
    }
    if (!argv[0][0]) { err = ENOENT; reason = "executable"; goto cleanup; }
    exe = find_executable(argv[0], &err);
    if (!exe) { reason = "executable"; goto cleanup; }
    lua_pop(L, 1);
    lua_getfield(L, 1, "cwd");
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t n; const char *s = lua_tolstring(L, -1, &n);
        if (!valid_string(s, n)) { err = EINVAL; reason = "cwd"; goto cleanup; }
        cwd = string_copy(s, n);
        if (!cwd) { err = ENOMEM; goto cleanup; }
    }
    lua_pop(L, 1);
    lua_getfield(L, 1, "env");
    if (lua_istable(L, -1)) env = build_env(L, lua_gettop(L));
    else { env = calloc(1, sizeof(char *)); if (env) {
        size_t i = 0; while (environ[i]) i++;
        free(env); env = calloc(i + 1, sizeof(char *));
        if (env) for (size_t j = 0; j < i; j++) {
            env[j] = strdup(environ[j]); if (!env[j]) { free_strings(env); env = NULL; break; }
        }
    } }
    if (!env) { err = ENOMEM; reason = "environment"; goto cleanup; }
    lua_pop(L, 1);
    lua_getfield(L, 1, "stdin");
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t n; const char *s = lua_tolstring(L, -1, &n);
        feed = calloc(1, sizeof(*feed));
        if (!feed) { err = ENOMEM; goto cleanup; }
        feed->fd = -1; feed->data = malloc(n ? n : 1);
        if (!feed->data) { err = ENOMEM; goto cleanup; }
        memcpy(feed->data, s, n);
        feed->len = n;
    }
    lua_pop(L, 1);
    if (!make_pipe(out) || !make_pipe(serr) || !make_pipe(status) ||
        !make_pipe(life) || !make_pipe(execerr)) { err = errno; reason = "pipe"; goto cleanup; }
    if (feed) { if (!make_pipe(in)) { err = errno; reason = "pipe"; goto cleanup; } }
    else { in[0] = open("/dev/null", O_RDONLY | O_CLOEXEC); if (in[0] < 0) {
        err = errno; reason = "open /dev/null"; goto cleanup;
    } }
    int sources[6] = { life[0], status[1], execerr[1], in[0], out[1], serr[1] };
    for (int i = 0; i < 6; i++) {
        fixed[i] = fcntl(sources[i], F_DUPFD_CLOEXEC, 16);
        if (fixed[i] < 0) { err = errno; reason = "dup"; goto cleanup; }
    }
    unsigned int fd_limit = parent_fd_limit();
    pid_t host_pid = getpid();
    sigset_t all_signals, old_mask;
    sigfillset(&all_signals);
    int mask_error = pthread_sigmask(SIG_SETMASK, &all_signals, &old_mask);
    if (mask_error) { err = mask_error; reason = "pthread_sigmask"; goto cleanup; }
    pid_t supervisor = fork();
    int fork_error = errno;
    if (supervisor != 0) pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    if (supervisor < 0) { err = fork_error; reason = "fork"; goto cleanup; }
    if (supervisor == 0) supervisor_run(host_pid, fd_limit, fixed, exe, argv, env, cwd);
    p->supervisor = supervisor;
    p->lifeline_w = life[1]; life[1] = -1;
    for (int i = 0; i < 6; i++) fd_close(&fixed[i]);
    fd_close(&life[0]); fd_close(&status[1]); fd_close(&execerr[1]);
    fd_close(&in[0]); fd_close(&out[1]); fd_close(&serr[1]);
    Record initial;
    int read_ok = read_record(status[0], &initial, sizeof(initial));
    if (read_ok != 1 || initial.type != REC_PID) {
        err = read_ok == 1 && initial.type == REC_ERROR ? initial.value : ECHILD;
        reason = "supervisor"; goto spawned_failure;
    }
    p->pid = initial.value;
    pid_t initial_group = 0;
    process_identity(p->pid, &initial_group, &p->child_start_time);
    ExecError execution;
    read_ok = read_record(execerr[0], &execution, sizeof(execution));
    if (read_ok != 0) {
        err = read_ok == 1 ? execution.error : EIO;
        reason = read_ok == 1 && execution.stage == ERR_CHDIR ? "chdir" :
                 read_ok == 1 && execution.stage == ERR_EXEC ? "execve" : "child setup";
        goto spawned_failure;
    }
    fd_close(&execerr[0]);
    if (!set_nonblock(out[0]) || !set_nonblock(serr[0]) || !set_nonblock(status[0]) ||
        !set_nonblock(p->lifeline_w)) {
        err = errno; reason = "fcntl"; goto spawned_failure;
    }
    if (feed) {
        feed->fd = in[1]; in[1] = -1;
        pthread_t thread;
        int thread_err = pthread_create(&thread, NULL, stdin_writer, feed);
        if (thread_err) { err = thread_err; reason = "pthread_create"; goto spawned_failure; }
        pthread_detach(thread);
        feed = NULL;
    }
    p->out_r = out[0]; p->err_r = serr[0]; p->status_r = status[0];
    out[0] = serr[0] = status[0] = -1;
    rc = 1;
    goto cleanup;
spawned_failure:
    close_process(p);
    p->supervisor = p->pid = 0;
cleanup:
    for (int i = 0; i < 6; i++) fd_close(&fixed[i]);
    fd_close(&out[0]); fd_close(&out[1]); fd_close(&serr[0]); fd_close(&serr[1]);
    fd_close(&in[0]); fd_close(&in[1]); fd_close(&status[0]); fd_close(&status[1]);
    fd_close(&life[0]); fd_close(&life[1]); fd_close(&execerr[0]); fd_close(&execerr[1]);
    free_feed(feed); free_strings(argv); free_strings(env); free(exe); free(cwd);
    if (rc != 1 && err) return error_result(L, reason, err);
    return rc;
}

/*** Read available bytes without blocking.
 * @function process:read
 * @tparam[opt="stdout"] string stream `"stdout"` or `"stderr"`.
 * @tparam[opt=65536] integer max Most bytes to return.
 * @treturn string|nil Data, `""` while open and empty, `nil` at EOF.
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
    int *fd = is_err ? &p->err_r : &p->out_r;
    if (*fd < 0) { lua_pushnil(L); return 1; }
    char *buf = malloc((size_t)max);
    if (!buf) return luaL_error(L, "out of memory");
    ssize_t n;
    do { n = read(*fd, buf, (size_t)max); } while (n < 0 && errno == EINTR);
    if (n > 0) { lua_pushlstring(L, buf, (size_t)n); free(buf); return 1; }
    free(buf);
    if (n == 0) { fd_close(fd); lua_pushnil(L); return 1; }
    if (errno == EAGAIN || errno == EWOULDBLOCK) { lua_pushliteral(L, ""); return 1; }
    return error_result(L, "read", errno);
}
/*** Has the direct child exited?
 * @function process:poll
 * @treturn integer|nil Exit code, or `nil` while running. If the supervisor
 *   dies before reporting the exit, returns 137 (or the requested kill code).
 */
static int m_poll(lua_State *L)
{
    LProcess *p = check_proc(L);
    if (p->supervisor <= 0) { lua_pushnil(L); return 1; }
    drain_status(p);
    reap_supervisor(p, 0);
    if (p->has_exit) lua_pushinteger(L,
        p->exit_killed && p->exit_code == 128 + SIGKILL ? p->kill_code : p->exit_code);
    else if (p->reaped) lua_pushinteger(L,
        p->fallback_killed ? p->kill_code : 128 + SIGKILL);
    else lua_pushnil(L);
    return 1;
}
/*** End the process and its process group.
 * @function process:kill
 * @tparam[opt=1] integer code Exit code to report after killing.
 * @treturn boolean
 */
static int m_kill(lua_State *L)
{
    LProcess *p = check_proc(L);
    int code = (int)luaL_optinteger(L, 2, 1);
    if (p->supervisor <= 0) { lua_pushboolean(L, 0); return 1; }
    drain_status(p);
    reap_supervisor(p, 0);
    int ok;
    if (p->reaped) {
        ok = !p->supervisor_clean && fallback_kill(p);
        if (ok && !p->has_exit) { p->fallback_killed = 1; p->kill_code = code; }
    } else {
        char request = 'K';
        if (p->kill_requested) ok = 1;
        else {
            ssize_t sent;
            do { sent = p->lifeline_w >= 0 ? write(p->lifeline_w, &request, 1) : -1; }
            while (sent < 0 && errno == EINTR);
            ok = sent == 1 || (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
        }
        if (ok && !p->kill_requested) { p->kill_requested = 1; p->kill_code = code; }
        if (!ok) {
            reap_supervisor(p, 0);
            if (p->reaped && !p->supervisor_clean) {
                ok = fallback_kill(p);
                if (ok && !p->has_exit) { p->fallback_killed = 1; p->kill_code = code; }
            }
        }
    }
    lua_pushboolean(L, ok);
    return 1;
}
/*** The direct child's process id.
 * @function process:pid
 * @treturn integer
 */
static int m_pid(lua_State *L)
{ LProcess *p = check_proc(L); lua_pushinteger(L, (lua_Integer)p->pid); return 1; }
/*** Release this process and end any remaining descendants. Idempotent.
 * @function process:close
 */
static int m_close(lua_State *L)
{ close_process(check_proc(L)); return 0; }
static int m_tostring(lua_State *L)
{ LProcess *p = check_proc(L); lua_pushfstring(L, "process (pid %d)", (int)p->pid); return 1; }
static const luaL_Reg methods[] = {
    { "read", m_read }, { "poll", m_poll }, { "kill", m_kill },
    { "pid", m_pid }, { "close", m_close }, { NULL, NULL }
};
static const luaL_Reg functions[] = { { "spawn", l_spawn }, { NULL, NULL } };
int luaopen_process(lua_State *L)
{
    signal(SIGPIPE, SIG_IGN);
    if (luaL_newmetatable(L, PROCESS_MT)) {
        lua_newtable(L); luaL_register(L, NULL, methods); lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, m_close); lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, m_tostring); lua_setfield(L, -2, "__tostring");
    }
    lua_pop(L, 1); lua_newtable(L); luaL_register(L, NULL, functions); return 1;
}
