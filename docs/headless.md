# Headless host

`lunar-cli --headless` runs Lunar's extension host without a window: the same
org-pack resolution, trust rules and extension loader as the desktop app, but
no IUP. It is meant for servers, where an extension schedules work, runs tools,
talks to other services and (with `core.lib.HttpServer`) answers HTTP requests.

```text
lunar-cli --headless [--pack ID] [--dev] [--extensions DIR]...
                     [--until-idle] [--for SECONDS] [--log-level LEVEL]
```

| Option | Meaning |
|---|---|
| `--pack ID` | Use org pack `ID`. It must be installed for all users and trusted (see [Trust model](trust-model.md)) unless `--dev` is given. Without it, the pack is chosen the way the desktop app chooses it. |
| `--dev` | Development: accept an untrusted pack and allow `--extensions`. |
| `--extensions DIR` | Also load extensions from `DIR` (with `--dev`; repeatable). |
| `--until-idle` | Exit once no timer, job or request is left (tests, one-shot runs). |
| `--for SECONDS` | Exit after `SECONDS`. |
| `--log-level LEVEL` | `DEBUG`, `INFO` (default), `WARN` or `ERROR`. Logs go to stderr. |

The headless code is embedded in the executable, like the desktop app's, so it
needs nothing beside it. `SIGTERM`/`SIGINT` (Ctrl+C, a closed console or a
shutdown on Windows) end the loop; every extension's `shutdown()` then runs and
its timers, jobs and requests are cleaned up.

## Writing an extension that runs headless

Say so in the manifest. An extension without `modes` is desktop-only and is
skipped by the headless host before its code runs (and the reverse for
`["headless"]`):

```json
{
  "schema_version": 2,
  "id": "nightly",
  "name": "Nightly",
  "version": "1.0.0",
  "host_api": 3,
  "modes": ["headless"]
}
```

`ctx.mode` is `"gui"` or `"headless"`, so one extension can serve both:

```lua
local M = {}

function M:register(ctx)
    local log = ctx:getLogger("nightly")
    if ctx.mode == "gui" then
        -- tabs, menus, settings widgets ...
    end
    ctx:onReady(function()
        ctx:addTimer({ time = 60 * 60 * 1000, run = true, action = function()
            ctx:startJob({
                argv = { "python3", "-m", "tool", "run", "--json" },
                on_exit = function(res) log:info("run " .. tostring(res.status)) end,
            }, M)
        end }, M)
    end, M)
end

return M
```

What works headless:

| Works | Notes |
|---|---|
| `ctx:addTimer` | Returns a loop timer: `timer:start()`, `timer:stop()` (not `iup.SetAttribute`). |
| `ctx:startJob`, `ctx:spawn` | Jobs are driven by the loop. |
| `ctx:http`, `ctx:runAsync`, `ctx:async()` | The loop steps the copas scheduler. |
| `ctx:onReady` | Runs once every extension has registered. |
| `ctx:notify`, `ctx:setStatus` | Written to the log. |
| `ctx:getLogger`, settings, `ctx:getManifest` | As on the desktop. |

What doesn't: anything that builds UI (`ctx:addTab`, menus, status elements,
`ctx:pickFolder`, `ctx.iup`). Check `ctx.mode` before calling them.

Secrets: the desktop keyring (`secret-tool`) usually isn't available on a
server; a file-based store is planned. Until then, pass credentials in the
service's environment.

## Linux servers with an old glibc

The Linux build needs glibc 2.34 or newer (`process` uses `close_range` and
`_Fork`). On an older distribution (CentOS 7 has 2.17), don't upgrade the
system glibc: give Lunar a private runtime, so only Lunar uses it. On CentOS 7
this works with nothing installed system-wide:

1. **Runtime:** unpack (don't install) RHEL 9-family `glibc`, `openssl-libs`,
   `openssl-devel`, `zlib` and `libgcc` packages into
   `/opt/lunar-runtime/sysroot`, with `lib64 -> usr/lib64`.
2. **Toolchain:** the `ziglang`, `cmake`, `ninja` and `patchelf` wheels from PyPI
   are standalone binaries that run on glibc 2.17. Compile with
   `zig cc -target x86_64-linux-gnu.2.34 -fno-sanitize=undefined -funwind-tables`.
3. **LuaJIT:** static, `HOST_CC=gcc` (its build-time tools run on the host),
   `XCFLAGS="-O2 -DLUAJIT_UNWIND_EXTERNAL"` (its unwind probe reads stdin, which
   `zig cc` doesn't), and `TARGET_XLIBS` adding the runtime's `libgcc_s.so.1`
   plus `-Wl,--allow-shlib-undefined` (that libgcc_s uses a glibc symbol RHEL
   backported to 2.34).
4. **lunar-cli:** `cmake -DLUNAR_HEADLESS=ON -DLUNAR_DEV_BUILD=OFF` with the zig
   wrapper as the compiler and the OpenSSL paths pinned to the sysroot.
5. **Point it at the runtime:** `patchelf --set-interpreter
   <sysroot>/usr/lib64/ld-linux-x86-64.so.2 --force-rpath --set-rpath
   <sysroot>/usr/lib64` (`DT_RPATH`, so libssl's own dependencies resolve there
   too), and put `vendor/certs/cacert.pem` at `bin/certs/` next to it.

Child processes the host starts (Python tools, shell scripts) run on the system
libraries as usual; nothing is exported to them.

## Status

Built so far: the event loop (`core.lib.EventLoop`), the headless mode of
`HostAPI`, manifest `modes`, `core.headless` and `lunar-cli --headless`, and
`core.lib.HttpServer` (not yet exposed to extensions), and `LUNAR_HEADLESS`
(CMake: only lunar-cli, no GTK). Verified on CentOS 7.9 with the private
runtime: JIT, errors unwinding through C, jobs, HTTPS, SIGTERM. Next:
`ctx:addRoute` on top of the HTTP server, a file-based secret store, and local
SQLite storage.
