# Lunar Extension Host

Lunar Extension Host (Lunar) is a desktop host for tool extensions. The host
supplies the window, extension lifecycle, settings, themes, menus, status bar,
`lunar://` routing and native services; every tool is an extension that adds
its own tabs, settings and commands.

Organizations can install an **org pack**: a profile that sets and locks default
settings and ships the organization's own extensions. Lunar looks the same in
every organization; a pack's tools open together in its own tab group (say,
"Acme Tools"), and its logo sits in the status bar.

The current release is **1.0.0**. Lunar runs on Windows today; Linux (GTK, under
XWayland first) is in progress.

## What's in this repository

| | |
|---|---|
| **The host** | `src\c` (IUP 3.32 + LuaJIT bootstrap, native modules) and `src\lua\core` (the shell, services and UI kit) |
| **Themes** | Classic and Classic Dark, IBM Carbon (White, G10, G90, G100) and One Dark Pro, plus a motion system |
| **An example extension** | `exampleplugins\hello.lua` |

Lunar ships with **no** bundled tools: `plugins\` is empty. Tools come from
extensions you write or from an org pack.

## Running

Packaged builds need no Lua, CMake or compiler.

- **Setup program (recommended).** Download `Lunar-Setup-<version>.exe` (Windows) or
  `Lunar-Setup-<version>-x86_64.run` (Linux: `sh Lunar-Setup-<version>-x86_64.run`).
  Both open the same wizard: license, install type, the extensions to install, progress,
  done. On Linux you choose *Just for me* (`~/.local/opt/lunar`, no password) or
  *Everyone* (`/opt/lunar`, asks for the administrator password); running setup again
  upgrades in place, and `lunar-uninstall` (or the "Uninstall Lunar" menu entry)
  removes it. On Windows the setup program drives the MSI below.
- **MSI (IT / silent installs):** `LunarExtensionHost-<version>.msi` (per-machine, under
  `C:\Program Files\Lunar Extension Host\`; needs elevation). Choose extensions with
  `msiexec /i ... ADDLOCAL=Ft_Core,Ft_ext_<id> /qn`.
- **Portable:** extract `Lunar-portable-<version>.zip` and run
  `Lunar.exe`, keeping it beside its `assets\` and `certs\` folders.
- **Linux .deb** (for people who prefer the package manager; Ubuntu 24.04+, Mint 22+, Debian 13): `sudo apt install
  ./lunar-extension-host_<version>_amd64.deb` installs to `/opt/lunar` with the
  `lunar` command and a menu entry.
- **Linux AppImage** (no install): `chmod +x Lunar-<version>-x86_64.AppImage` and run it. It
  uses the system's GTK 3 and OpenSSL 3 (any current desktop distribution has them).

The process shows as **Lunar** on every platform (Task Manager, `ps`, the taskbar).

Settings live per user in `%APPDATA%\Lunar Extension Host\settings.json`
(`~/.config/lunar/` on Linux). Extensions keep their state under the same folder.

## Org packs

A pack is a folder with a `profile.json` and the files it references:

```jsonc
{
  "schema": 1,
  "id": "acme",                              // must equal the folder name
  "name": "Acme Corp",
  "match": { "domains": ["acme.com"] },      // exact domain or a subdomain
  "tool_group": "Acme Tools",                 // tab group for the pack's tools (default: name)
  "brand": { "logo": "logo.svg" },           // small status-bar logo
  "settings": { "backend_url": "https://tools.acme.example", "theme": "acme_dark" },
  "locked": ["backend_url"],                 // users can't change these
  "retired_defaults": { "backend_url": ["https://old.acme.example"] },
  "legacy_config_dir": "Acme Tools"           // copy this %APPDATA% folder on first run
}
```

Packs that carry extensions put them in the pack's `extensions\` folder; their
tabs default into the tool group (a manifest `group` nests inside it), and users
can rearrange them like any other tab. A pack may also register a theme and make
it the default with `settings.theme`. Settings may name files inside the pack as
`"pack:certs/backend.crt"`.

**Where packs come from.** An administrator installs packs into
`%ProgramData%\Lunar Extension Host\profiles\<id>\` (`/etc/lunar/profiles/<id>/` on
Linux). Lunar only trusts that location when ordinary users can't change it. That
means the folder, `profiles`, `policy.json` and each pack must be owned by
Administrators/SYSTEM (root on Linux) and must not be writable by anyone else.
On a stock Windows install, users *can* create folders under `%ProgramData%`, so an
installer must create `Lunar Extension Host` with admin-only permissions. Anything
that fails the check is ignored, and Help > Window Diagnostics says why.

**Which pack applies**, first match wins:

1. `policy.json` beside `profiles` (`{ "profile": "<id>" }`), from the trusted
   location only.
2. The machine's DNS domain, as Windows or `/etc/resolv.conf` reports it, matching
   exactly one pack's `match.domains`.
3. Otherwise none: plain Lunar.

**For development**, point `LUNAR_PROFILE_DIR` at a folder of packs. Packs found
there are *untrusted*: their settings apply, but their locks and
extensions don't. A development build also accepts `LUNAR_PROFILE=<id>` to pick
one by id.

## Writing an extension

An extension is `<name>.lua` or `<name>\init.lua` with a manifest, returning a
table whose `register(ctx)` uses the host API to add tabs, settings, menus,
shortcuts, routes, timers and status items. The host records what each extension
created and removes all of it on unload or reload (Extensions > Reload Extensions).

```json
{
  "schema_version": 2,
  "id": "example",
  "name": "Example",
  "version": "1.0.0",
  "platforms": ["windows", "linux"],
  "host_api": 2,
  "capabilities": ["tabs", "settings"],
  "provides": { "tabs": ["Example"] }
}
```

Extensions load from the built-in `plugins\` folder, then from the selected
trusted org pack. Ids must be unique. Extensions share the host's Lua state and
are trusted by where they are installed; there is no sandbox (see
`docs\trust-model.md`). See `exampleplugins\hello.lua` and the guides
under `docs\`: getting started, extension lifecycle, manifest, routing, theming,
tab groups, logging, native services and API stability.

## Building from source

### Prerequisites

- Windows 10/11, PowerShell 5.1+
- [MSYS2](https://www.msys2.org/) MinGW-w64 at `C:\msys64\mingw64`:
  `pacman -S mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-python perl`
  (gcc, `mingw32-make`, CMake 3.21+, Python 3 for the embedding steps, Perl for OpenSSL)
- [Git for Windows](https://git-scm.com/download/win) on PATH: the IUP fork build applies
  its patch series with `git apply` (use Git for Windows, not MSYS2's git: putting
  `C:\msys64\usr\bin` on PATH breaks the MinGW Makefiles generator)

Then, once per checkout:

```powershell
scripts\bootstrap.ps1 -Dev   # LuaJIT, IUP libraries, OpenSSL, the rock tree, and the dev tools
```

The small dependencies CMake compiles (LuaFileSystem, lua-cjson, LuaSocket,
LuaSec, Copas, NanoSVG) are in Git under `vendor\`. `bootstrap.ps1` restores the
rest from pinned, hash-checked sources; `vendor\README.md` lists both.

The IUP changes Lunar needs (gradients, rounded corners, a few fixes) live as a
patch series in `iup-fork\`. The build downloads pristine IUP 3.32, applies the
patches and builds `libiup.a`.

### Build, run, test

CMake presets drive the build. VS Code users get the same through
**Ctrl+Shift+B** and "Tasks: Run Task"; `mingw32-make` wraps it on the command line.

```powershell
cmake --preset dev; cmake --build --preset dev   # build\win  (loads plugins\ from the repo)
build\win\bin\Lunar.exe

cmake --preset release; cmake --build --preset release   # build\rel  (what ships)
```

On Linux (X11 or XWayland, GTK 3; LuaJIT 2.1 installed in `/usr/local`):

```sh
scripts/dev.sh bootstrap && python3 scripts/build_iup.py
cmake --preset linux-dev && cmake --build --preset linux-dev   # build/linux
build/linux/bin/lunar
scripts/dev.sh check                                            # test + lint + docs
```

| `make` target | Does |
|---|---|
| `build`, `release` | the two presets above |
| `run`, `run-packs` | start the dev build, optionally with `..\lunar-orgpacks` as dev packs |
| `test`, `lint`, `docs`, `check` | busted, luacheck, LDoc, all three |
| `harness` | the end-to-end process check |

Lunar uses **one** Lua everywhere: LuaJIT 2.1. The app, busted, luacheck and ldoc
all run on it. That's deliberate: a different test VM hides real behavior
differences, and `ffi` code would go untested. `spec\support\runtime_host.lua`
aborts a test run on any other interpreter.

A **dev** build (`LUNAR_DEV_BUILD=ON`) loads extensions from the repo's `plugins\`
and honors `LUNAR_PROFILE`. A **release** build loads code only from its own
folder and trusted org packs, and ignores the working directory and `LUA_PATH`.

Things that are easy to break:

- `src\Lunar.def` is the exe's export list, regenerated by
  `scripts\gen-exports.ps1`. Symbols reached only through FFI (`nsvg*`, `Iup*`) must
  be listed, or the linker drops them and startup fails with
  `cannot resolve symbol`.
- `vendor\subprocess.h` carries a local quoting fix for drive roots and UNC
  paths; don't replace it with upstream.
- After rebuilding OpenSSL, run `build\win\bin\LunarCLI.exe`
  `scripts\tls_check.lua <host> [port]`. It prints the negotiated protocol and cipher;
  a downgraded handshake still returns 200, so functional tests won't catch it.

## API documentation

The host API is documented with [LDoc](https://github.com/lunarmodules/LDoc) and
published with the guides in the **[wiki](https://github.com/MemezForBeanz/Lunar-Extension-Host/wiki)**
(rebuilt by `.github/workflows/docs.yml` on every push to `main`; `scripts/build_wiki.sh`
builds the pages locally). To build the HTML reference locally:

```powershell
.\scripts\docs.ps1          # build dist\docs
.\scripts\docs.ps1 -Serve   # build and open
.\scripts\docs.ps1 -Check   # fail on warnings
```

New public APIs need a `@module`/`@classmod` block, `@tparam`/`@treturn` for
every parameter and result (including `nil, err`), and a `@usage` example.

## Packaging

```powershell
.\scripts\build.ps1 -Mode portable   # dist\release-assets\Lunar-portable-<version>.zip
.\scripts\build.ps1 -Mode installer  # ...\LunarExtensionHost-<version>.msi (WiX 3, fetched on first use) + Lunar-Setup-<version>.exe (IExpress)
.\scripts\build.ps1 -Mode all
```

```sh
cmake --preset linux-release && cmake --build --preset linux-release
scripts/package_linux.sh   # dist/linux: Lunar-Setup-<version>-x86_64.run + lunar-extension-host_<version>_amd64.deb + Lunar-<version>-x86_64.AppImage
```

The version comes from `APP_VERSION` in `src\lua\core\main.lua`. Publishing
targets have no defaults: `-PublishGitHub` needs `-Repo owner/name`, and
`-PublishShare` needs `-HostRoot \\server\share\path`.

CI (`.github/workflows/ci.yml`) builds, tests and packages both platforms on every
push and pull request; pushing a `vX.Y.Z` tag runs `release.yml`, which builds the
same way and stages a **draft** GitHub release with every package and `SHA256SUMS`.

## Repository layout

```text
assets\           icons, theme fonts, the exe manifest and resources
docs\             guides for the API reference site
exampleplugins\   a minimal extension
iup-fork\         Lunar's IUP patch series and its verification harness
plugins\          built-in extensions (empty in this repository)
scripts\          dependency, build, test, docs and packaging scripts
spec\             busted specs and fixtures
src\c\            native host and modules
src\lua\core\     the Lua shell, services and UI kit
vendor\           third-party sources and toolchains (mostly machine-local)
```

## License

[MIT](LICENSE). The vendored third-party code under `vendor\` keeps its own
licenses (listed in `vendor\README.md`); the IBM Plex fonts under
`assets\Themes\Carbon` are under the SIL Open Font License.
