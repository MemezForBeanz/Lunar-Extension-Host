# Trust model

Lunar trusts extensions the way an operating system trusts installed programs:
by where they were installed, not by what they do. **There is no sandbox.**

## What an extension can do

Every extension runs in the host's single Lua state, with the user's own
privileges. It can:

- read and change the host's globals, modules and widgets, and other extensions'
  state (the per-extension `require` keeps module *names* apart; it is not a
  boundary);
- call any C function through LuaJIT `ffi`, load native modules, and use the
  file system, the network and child processes;
- read any setting, including another extension's, and call the OS credential
  store directly.

Install an extension only if you would run it as a program.

## Where trusted code comes from

The host decides what code to load, in this order, before any of it runs:

1. **Built-in extensions:** the `plugins\` folder next to the executable.
2. **The selected org pack's `extensions\` folder**, only when the pack is in
   the system profiles folder (`%ProgramData%\Lunar Extension Host\profiles`,
   `/etc/lunar/profiles`) *and* that folder, the pack and every file in it can be
   changed only by administrators (root on Linux). A pack that fails the check is
   ignored and Help > Window Diagnostics says why. If the platform can't perform
   the check at all, nothing there is trusted.

A **release build** loads code only from those places. It ignores the current
directory, `LUA_PATH` and `LUA_CPATH`, and if it can't determine its own folder
it refuses to start rather than falling back to the working directory.

A **development build** (`LUNAR_DEV_BUILD=ON`) also loads the repository's
`plugins\` and honors `LUNAR_PROFILE`. Packs found through `LUNAR_PROFILE_DIR` are
*untrusted*: their settings apply, but their locks and extensions don't.

## What the host checks, and what it doesn't

Before an extension's code runs, the host validates its manifest, refuses an
unsupported platform or a newer `host_api`, and refuses a duplicate id. While it
runs, the host records everything it registers (tabs, menus, timers, HTTP
requests, jobs and processes) and removes all of it on unload. These are
**correctness** guarantees, not security ones:

- `ctx:getSecret` and `ctx:setSecret` namespace secrets by extension id so
  extensions don't collide. Another extension could still read them.
- An org pack's `locked` settings stop users from changing values through the
  UI. They are configuration, not enforcement: extension code, or a user who can
  edit their own files, can work around them. Anything that must be enforced,
  such as access to a backend, belongs on the server.
- Choosing an org pack by DNS domain selects configuration. It doesn't
  authenticate the machine or the user.

## For organizations shipping a pack

A pack's extensions run with every user's privileges on every machine that
installs it. Treat a pack like an installer: build it from reviewed sources,
install it so only administrators can change it (owner Administrators or SYSTEM
with no other writers on Windows; root-owned, not group- or world-writable on
Linux), and keep credentials out of `profile.json`.
