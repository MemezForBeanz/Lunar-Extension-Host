# Lunar Extension Host

Lunar Extension Host (Lunar) is a desktop host for tool extensions. The host
supplies the window, extension lifecycle, settings, themes, menus, status bar,
`lunar://` routing and native services; every tool is an extension that adds
its own tabs, settings and commands.

Organizations can install an **org pack**: a profile that sets and locks default
settings and ships the organization's own extensions. Lunar looks the same in
every organization; a pack's tools open together in its own tab group (say,
"Acme Tools"), and its logo sits in the status bar.

Lunar runs on Windows and Linux (GTK 3, under X11 or XWayland).

## What's in this repository

| | |
|---|---|
| **The host** | `src\c` (IUP 3.32 + LuaJIT bootstrap, native modules) and `src\lua\core` (the shell, services and UI kit) |
| **Themes** | Classic, Lunar and One palettes, each with light and dark modes, plus a motion system |
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

## Updates

Lunar checks published GitHub releases on startup and every six hours. Click the
update icon in the bottom toolbar, or use **Check for Updates** in Ctrl+P, to check
and accept an update. Windows downloads and verifies the MSI before installing
and reopening Lunar. Linux opens the release's package downloads. Updates always
come from GitHub; an organization profile or network share is not required.

Older builds with the share-only updater need one manual upgrade to this version.

## Org packs

A pack is a folder with a `profile.json` and the files it references:

```jsonc
{
  "schema": 1,
  "id": "acme",                              // must equal the folder name
  "name": "Acme Corp",
  "match": { "domains": ["acme.com"] },      // exact domain or a subdomain
  "tool_group": "Acme Tools",                 // tab group for the pack's tools (default: name)
  "brand": {
    "icon": "assets/mark.svg",              // theme-tinted tool-group icon
    "icon_color": "#01A982",                // optional: one colour in every theme instead
    "logo": { "light": "assets/logo.png", "dark": "assets/logo-white.png",
              "themes": { "acme_dark": "assets/logo-white.png" } }
  },
  "adopt_theme": true,                      // optional, one adoption per settings.theme value
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
there are *untrusted*: their settings apply, but their locks don't; their
extensions load only in dev builds. A development build accepts
`LUNAR_PROFILE=<id>` to pick one, or `LUNAR_PROFILE="*"` to load all packs in that
directory. VS Code provides **Run Lunar with all org packs (dev)** for the latter;
see [the trust model](docs/trust-model.md) for ordering and shared settings.

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

For an interactive preview, use **Run Lunar with demo data (dev)**. It starts the
normal app, applies the same page fixtures as UI capture, and stays open until you
close it. Choose all org packs and supply their folder to include their tool pages.
Use **Help > Reload demo data** to restore the sample data after interacting.
Only pages with capture fixtures are populated; these fixtures are UI examples,
not a complete simulation of build, filesystem, or device operations.
`ui_fixtures.lua` itself is a data module, not an application launcher.

Two other dev tasks run Lua scripts automatically after building:

- **Run Lunar with a test script (dev)** offers a dropdown of `scripts/*.lua`
  and an optional filename override (with or without `.lua`). Leave the override
  blank to use the dropdown. New scripts can be typed immediately; the dropdown
  list lives in `.vscode/tasks.json`.
- **Run Lunar with multiple test scripts (dev)** accepts comma- or semicolon-separated
  filenames, such as `layout_dump, scrim_check`. Each runs in a fresh Lunar process,
  in the order entered. Close interactive harness windows to advance. Failures are
  reported, remaining scripts still run, and the task fails if any script fails.

Both ask whether to load all org packs and for the packs folder (ignored for No).
No uses normal org-pack selection without the development environment overrides.
These tasks use Lunar's existing script entry point: the script controls startup
and shutdown. For example, `ui_capture` and `layout_dump` start the normal app;
helper files such as `ui_fixtures` only return data. Scripts requiring command-line
arguments should still be run directly with those arguments.

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

Release packaging combines the built-in `plugins/` with every compatible extension
in the project's `extensions/` folder. Folder extensions (`init.lua` plus a manifest)
and single-file Lua extensions appear as individual choices in the Windows and
Linux setup wizard; Windows also exposes each as an MSI feature. Names, descriptions,
versions and IDs come from extension manifests. Portable packages carry the same
extension payload. ZIP downloads and loose notes in `extensions/` are not installer
features. Duplicate IDs or staging names cause packaging to fail instead of replacing
another extension. Adding an extension does not require maintaining an installer list.

On Windows, **Tasks: Run Task > Run Lunar with all project extensions (dev)** builds
and runs the desktop with every compatible extension in `extensions/`, alongside
the built-in plugins. New extension folders are discovered on the next run or
extension reload. The task also runs headless extensions (including media-server)
in a private local server on port 18421, with a separate catalog under
`build/dev-extensions/`. Closing the desktop stops that server. It does not change
the installed server configuration. Missing extension runtimes prepare their own
caches. For a different port, run `scripts/run-dev-extensions.ps1 -Port 18422`.

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

Org brand paths must remain inside the pack and exist. Icons accept SVG only;
logos accept SVG or PNG. A logo string applies to every theme. A logo object
resolves `themes[theme_id]`, then `dark` or `light`, then `default`; a missing dark
variant never selects a light-only entry. Bad entries warn and are dropped.
Group icons follow the theme's `brandMark` palette color, falling back to neutral,
and appear after the title or in the left tool rail. The Lunar moon stays.
The selected pack's status logo switches live and hides below 1000px window width.
`adopt_theme` clears saved theme/light/dark choices once per pack default theme
value (except locked settings); subsequent user choices survive. A failed save
retries next launch. Omit it to preserve existing user theme choices from the start.
