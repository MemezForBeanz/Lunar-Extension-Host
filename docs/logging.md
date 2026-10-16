# Logging

`core.lib.log` is the single logging entry point for the host and every
extension. It is built on LuaLogging, with `date` for ISO-8601 timestamps and
`serpent` for readable table formatting, and fans one call out to a console sink
and an optional size-rotated file.

## Getting a logger

From an extension context:

```lua
local log = ctx:getLogger("example")   -- namespaced logger
log:info("scan finished", { files = n, failures = k })
```

Or directly:

```lua
local applog = require("core.lib.log")
local log = applog.get("example")
```

`core.classes.Extension` subclasses can call `self:getLogger()`, which defaults
the namespace to the extension name.

## Levels

`debug`, `info`, `warn`, `error` are available on every logger, plus
`log:dump(label, value)` for a multi-line structured dump. The active level is a
process-wide setting configured by the host:

```lua
applog.configure{ level = "INFO", file = cfg_dir .. "\\lunar.log" }
applog.setLevel("DEBUG")
```

Extensions should not reconfigure the root logger; they only obtain namespaced
loggers.

## Structured arguments

Any table argument is pretty-printed with serpent, so records can be logged
directly instead of hand-encoding JSON:

```lua
log:info("queued", { target = name, preset = preset, count = #items })
```

## Status bar vs log

Two different channels:

- `ctx:setStatus(msg)` (or `Extension:log(msg)`) writes to the status bar — user
  facing, transient.
- `ctx:getLogger(name)` writes to the console and rotated log file — diagnostic,
  persistent.

## Degraded mode

Every dependency is loaded with `pcall`. If LuaLogging, `date`, or `serpent` are
unavailable — for example in an ad-hoc script run outside the packaged app — the
loggers fall back to formatted lines on stderr with their own level filtering, so
logging never hard-fails. `applog.available` reports whether real sinks are in
use.
