# Native services

The native host registers a handful of C modules into the Lua state. They are
available to extensions through `require`. For processes, prefer the owned
`ctx:startJob` and `ctx:spawn` (see `HostAPI`): they end the process when the
extension unloads.

| Module | Purpose |
|---|---|
| `process` | Child processes: argv only, separate non-blocking stdout/stderr, the whole tree ends with the handle (Windows and Linux). |
| `subprocess` | Legacy command-line processes (Windows only; also `ctx.subprocess`). |
| `logscan` | Fast log enumeration, directory listing, scanning, and source context extraction. |
| `svgicon` | Rasterize SVG paths into IUP image handles. |
| `themeapply` | Apply and restore native (Win32) theme handles. |
| `winredraw` | Lock and unlock window redraw around bulk UI updates. |
| `iupraw` | Obtain the raw pointer behind an IUP handle. |

See the module pages in the reference for the exact Lua-visible signatures.

## Subprocess rules

- The IUP event loop is single-threaded. Start a process, then poll it from a
  host-owned timer (`HostAPI:addTimer`) instead of blocking.
- `ctx.subprocess.start` and `start_argv` take an optional trailing owner; an
  owned handle is terminated and destroyed when that extension unloads.
- Processes started with `subprocess.start` live in a kill-on-close job object,
  so they die when the host exits. That is deliberate: it prevents orphaned
  builds. Use `subprocess.start_detached` only for work that must outlive the
  host — the self-update relauncher is the one place the host does this.
- Always `destroy` a handle once you are done with it.

Argument quoting on Windows is handled by the locally patched
`vendor\subprocess.h`; do not replace it with an upstream copy, because the patch
fixes trailing-backslash quoting for arguments such as drive roots and UNC paths.

## Folder extensions with their own native modules

A folder extension may ship `.dll` modules in its root or in a `native\`
subdirectory (`.so` on Linux). The extension's own `require` searches both, so
`require("logcheck")` resolves to `plugins\<name>\native\logcheck.dll`. Build
them against the same LuaJIT 2.1 (Lua 5.1 ABI) the host uses; the host exports
the Lua C API for them. A native module can't be unloaded, so a reload reuses it.

## Redraw batching

Bulk updates flicker unless redraw is suspended:

```lua
local winredraw = require("winredraw")
winredraw.lock(handle)
-- rebuild many rows
winredraw.unlock(handle)
```

The theme manager uses the same mechanism when repainting a subtree.
