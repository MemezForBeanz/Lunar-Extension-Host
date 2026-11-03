# Headless host

`lunar-cli --headless` runs Lunar's extension host without a window: the same
org-pack resolution, trust rules and extension loader as the desktop app, but
no IUP. It is meant for servers, where an extension schedules work, runs tools,
talks to other services, keeps its state in SQLite and answers HTTP requests.

```text
lunar-cli --headless [--pack ID] [--dev] [--extensions DIR]...
                     [--until-idle] [--for SECONDS] [--log-level LEVEL]
                     [--require ID]... [--stop-grace SECONDS]
                     [--listen HOST:PORT --tokens-file PATH]
                     [--tls-cert PATH --tls-key PATH]
                     [--state-dir DIR] [--secrets-dir DIR]
```

| Option | Meaning |
|---|---|
| `--pack ID` | Use org pack `ID`. It must be installed for all users and trusted (see [Trust model](trust-model.md)) unless `--dev` is given. Without it, the pack is chosen the way the desktop app chooses it. |
| `--dev` | Development: accept an untrusted pack and allow `--extensions`. |
| `--extensions DIR` | Also load extensions from `DIR` (with `--dev`; repeatable). |
| `--until-idle` | Exit once no timer, job or request is left (tests, one-shot runs). |
| `--for SECONDS` | Exit after `SECONDS`. |
| `--log-level LEVEL` | `DEBUG`, `INFO` (default), `WARN` or `ERROR`. Logs go to stderr. |
| `--require ID` | Fail to start unless extension `ID` loads (repeatable). A service that exists to run one extension shouldn't sit there running nothing. |
| `--stop-grace SECONDS` | On stop, let running jobs finish for up to `SECONDS` (default 60). |
| `--listen HOST:PORT` | Serve HTTP(S). The host is required; off by default. Needs `--tokens-file`. |
| `--tokens-file PATH` | Bearer tokens, one `name token` per line. See [Tokens](#tokens). |
| `--tls-cert PATH`, `--tls-key PATH` | Serve HTTPS with this PEM certificate and key (give both). Required to listen on anything but localhost. |
| `--state-dir DIR` | Where extension databases live. Default `$XDG_STATE_HOME/lunar`, else `~/.local/state/lunar`. |
| `--secrets-dir DIR` | Read secrets from root-owned files in `DIR` instead of the keyring. See [Secrets](#secrets). |

The headless code is embedded in the executable, like the desktop app's, so it
needs nothing beside it.

## Stopping

`SIGTERM`/`SIGINT` (Ctrl+C, a closed console or a shutdown on Windows) end the
loop. Then, in order:

1. `ctx:isStopping()` turns true and the HTTP server closes. Once it's true, don't
   start new work, such as the next job of a sequence.
2. Running jobs get `--stop-grace` seconds to finish. Whatever is left is ended.
3. Every extension's `shutdown()` runs, its timers and jobs are cleaned up and its
   databases are closed.

A crash skips all of this, so a service should mark anything it finds still
"running" in its database as abandoned when it starts.

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
| `ctx:addTimer` | Returns a loop timer: `timer:start()`, `timer:stop()` (not `iup.SetAttribute`). A callback that raises stops its timer, unless you pass `keep_on_error = true`. |
| `ctx:startJob`, `ctx:spawn` | Jobs are driven by the loop. |
| `ctx:http`, `ctx:runAsync`, `ctx:async()` | The loop steps the copas scheduler. |
| `ctx:onReady` | Runs once every extension has registered. |
| `ctx:notify`, `ctx:setStatus` | Written to the log. |
| `ctx:getLogger`, settings, `ctx:getManifest` | As on the desktop. |
| `ctx:addRoute`, `ctx:removeRoute` | With `--listen`; see [Serving HTTP](#serving-http). |
| `ctx:openDatabase` | See [Storing data](#storing-data). |
| `ctx:getSecret` | See [Secrets](#secrets). |
| `ctx:isStopping` | See [Stopping](#stopping). |

What doesn't: anything that builds UI (`ctx:addTab`, menus, status elements,
`ctx:pickFolder`, `ctx.iup`). Check `ctx.mode` before calling them.

## Serving HTTP

An extension that declares the `http` capability can add routes under
`/ext/<manifest id>`. Every route needs a bearer token; extensions can't add
public ones. The host itself serves `GET /health` without a token, answering
`{"ok": true}` while it runs.

```lua
local ok, err = ctx:addRoute("GET", "/runs/:id", function(req)
    local run = find_run(tonumber(req.params.id))
    if not run then return { status = 404, json = { error = "no such run" } } end
    return { status = 200, json = run }
end, nil, M)
if not ok then log:warn("no HTTP API: " .. tostring(err)) end
```

- **The request** has `method`, `path`, `params` (`:name` parts of the path),
  `query`, `headers`, `body` and `auth`, the name of the token that signed it.
- **The response** is `{ status, json | body, headers }`. A table without those
  fields is sent as JSON with status 200.
- `ctx:addRoute` returns `nil, "HTTP server disabled"` without `--listen`, so an
  extension can run with or without an API.
- **Handlers run on the event loop, so they must not wait.** To do slow work, start
  a job, answer `202` and let the client ask again; serve the result from your
  database once it's ready.

### Tokens

The tokens file has one `name token` per line, and the name appears in the request
log and as `req.auth`. It must be a regular file owned by root or the service user,
with mode 0600 or 0640. Tokens are read at startup, so restart after changing them.

```sh
printf 'alice %s\n' "$(openssl rand -hex 32)" >> /etc/myservice/http-tokens
```

### TLS

Bearer tokens must not cross a network in the clear, so `--listen` on anything but
localhost refuses to start without `--tls-cert` and `--tls-key`. For a self-signed
certificate, include every name clients use, and have them trust it with `cafile`
in `ctx:http`:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -keyout server.key -out server.pem -subj "/CN=host.example.com" \
    -addext "subjectAltName=DNS:host.example.com,DNS:host"
```

The service user needs to read the key, and nobody else should.

## Storing data

An extension that declares the `database` capability gets its own SQLite files
under the state directory, at `<state dir>/<extension id>/<name>.sqlite3`.
`ctx:openDatabase` refuses a state directory on CIFS, SMB or NFS, because SQLite
isn't safe there.

```lua
local db, err = ctx:openDatabase("server", M)
if not db then error("database: " .. tostring(err), 0) end

local ok, why = db:migrate(2, function(d, previous)
    if previous < 1 then
        local done, e = d:exec("CREATE TABLE runs (id INTEGER PRIMARY KEY, state TEXT)")
        if not done then return nil, e end
    end
    if previous < 2 then
        return d:exec("CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT)")
    end
    return true
end)
```

`db:migrate(version, fn)` runs `fn` in a transaction when the file is older than
`version`, so add a step for each schema change and keep the data. A database newer
than `version` is refused. Other calls: `db:exec(sql)`, `db:transaction(fn)` and
`db:prepare(sql)`, which gives a statement with `bind(index, value)`, `step()` (a row table, then `false` when done),
`reset()` and `finalize()`. SQL `NULL` reads back as
`require("core.lib.sqlite").NULL`. Failures return `nil, message`.

SQLite calls block the loop, so keep transactions short. Databases close when the
extension unloads.

## Secrets

The desktop keyring (`secret-tool`) usually isn't available on a server. With
`--secrets-dir DIR`, `ctx:getSecret` reads files an administrator provisions, and
`ctx:setSecret` refuses, because a service never writes its own credentials:

```text
DIR/                       root, no group or world write (e.g. 0755)
  <extension id>/          root:<service group>, 0750
    <secret name>          root:<service group>, 0640, the value
```

No symlinks. Everything must be owned by root with no group or world write, and a
secret file must not be world-readable; anything else is refused with the reason.
One trailing newline is stripped, so `echo token > file` works.

## Running as a service

```ini
[Unit]
Description=My Lunar service
Wants=network-online.target
After=network-online.target

[Service]
User=myservice
ExecStart=/opt/lunar/bin/lunar-cli --headless --pack example --require myext \
    --listen 0.0.0.0:8470 --tokens-file /etc/myservice/http-tokens \
    --tls-cert /etc/myservice/server.pem --tls-key /etc/myservice/server.key \
    --secrets-dir /etc/myservice/secrets --state-dir /var/lib/myservice \
    --stop-grace 60
Restart=on-failure
RestartSec=30
TimeoutStopSec=90
KillMode=mixed
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/myservice

[Install]
WantedBy=multi-user.target
```

Set `TimeoutStopSec` longer than `--stop-grace`, so jobs get their full grace
period. `KillMode=mixed` sends the stop signal to Lunar alone, and Lunar stops its
jobs.

On Linux, `-DLUNAR_HEADLESS=ON` builds only `lunar-cli`, without GTK.

## Linux servers with an old glibc

The Linux build needs glibc 2.34 or newer (`process` uses `close_range` and
`_Fork`), so the simplest answer is a current distribution such as a RHEL 9-family
one, where Lunar builds with the system compiler and libraries.

If the OS can't change (CentOS 7 has glibc 2.17), don't upgrade the system glibc:
give Lunar a private runtime, so only Lunar uses it. On CentOS 7 this works with
nothing installed system-wide:

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
