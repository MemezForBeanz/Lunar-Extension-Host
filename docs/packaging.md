# Packaging and shipping an extension

## Where extensions live

A packaged Lunar installation keeps extensions beside the executable:

```text
Lunar.exe
plugins\<name>.lua
plugins\<name>.manifest.json
plugins\<name>\init.lua
plugins\<name>\manifest.json
plugins\<name>\native\*.dll
```

Removing a directory or file from `plugins\` removes that feature from the next
launch. Nothing else in the host needs to change.

## Portable builds

`scripts\build.ps1 -Mode portable` produces
`dist\release-assets\Lunar-portable-<version>.zip` containing the executable plus
`plugins\`, `assets\`, and the supporting runtime directories. Extensions are
picked up from `build\bin\plugins\`, which the CMake build stages from the
repository `plugins\` tree.

## The setup programs

`Lunar-Setup-<version>.exe` (Windows) and `Lunar-Setup-<version>-x86_64.run` (Linux)
are the recommended downloads. They open the same wizard, drawn with Lunar's own
flat controls and themed dark or light with the system:

1. **Welcome and license** - the license must be accepted to continue.
2. **Install type** - on Linux *Just for me* (default) or *Everyone*; on Windows
   only *Everyone* (see below). If Lunar is already installed the wizard says so and
   will upgrade it.
3. **Extensions** - one checkbox per extension in the package. Lunar itself is
   always installed. The list is the one the MSI turns into optional features;
   extensions that are already installed, or were chosen last time, start checked.
4. **Progress**
5. **Done** - with a *Launch Lunar* checkbox.

The wizard is a Lua program in `src/lua/installer/` (embedded in the executable like
the rest of the host), started by running the Lunar executable on a script:
`lunar setup/setup.lua` on Linux, `Lunar.exe setup.lua` on Windows. The executable
already runs any `.lua` path it is given in place of the application (the same
mechanism as the `scripts/*_check.lua` harnesses), so the installer needs no new
executable and no command-line flag in the application. The split is:
`installer/plan.lua` (what the package offers, defaults, the command line; pure),
`installer/linux.lua` and `installer/windows.lua` (what each platform does; no UI),
`installer/backend.lua` (adapters) and `installer/ui.lua` (the window). OS calls go
through `core.platform` (`spawn`, `elevate`, `set_mode`, `launch`,
`msi_installed_features`).

Options (both platforms; the `.run` passes them through): `--quiet` (no window),
`--type user|system`, `--extensions all|none|id,id`, `--no-launch`. On Linux a
quiet install runs the small console executable, so it needs no display:
`sh Lunar-Setup-1.0.0-x86_64.run --quiet --type user --extensions all`.

### Windows: `Lunar-Setup-<version>.exe`

`scripts\build.ps1 -Mode installer` builds the MSI and then wraps it with **IExpress**
(`iexpress.exe`, part of Windows; the `.SED` file is generated, see `New-SetupExe`).
The self-extractor carries `Lunar.exe`, `setup.lua`, `LICENSE`, `payload.json` (the
version and the extension list with each extension's MSI feature id, written from the
very list the MSI is built from) and the MSI, unpacks them to a temp folder and runs
`Lunar.exe setup.lua`. IExpress packs a flat folder, so the installer does not carry
`assets\` or `certs\`; it needs neither.

**The MSI stays the engine.** The wizard runs, elevated (one UAC prompt):

```text
msiexec /i LunarExtensionHost-<version>.msi ADDLOCAL=Ft_Core,Ft_ext_<id>,... [REMOVE=Ft_ext_<id>,...] /qn /norestart /l*v %TEMP%\Lunar-Setup-<version>.log
```

(`REMOVE` names the extensions that were left unchecked: running the MSI over an
installed copy of the same version only adds what `ADDLOCAL` lists, so unchecking an
installed extension has to remove it explicitly. A newer version is a major upgrade,
which replaces the old product with just what `ADDLOCAL` names.)

and maps the exit code: 0 done; 3010 and 1641 done, restart needed; 1602 or declining
the UAC prompt, cancelled; 1618 another install is running; anything else is shown
with the path of the log. Upgrades use the MSI's `MajorUpgrade`; the wizard preselects
the extensions that `MsiQueryFeatureState` reports installed for this product family.
IT deployments and the in-app updater keep using the MSI directly.

There is no *Just for me* choice on Windows: the MSI is per-machine (Program Files,
`%ProgramData%\Lunar Extension Host` with an admin-only ACL, an all-users Start menu
entry), and a per-user install would need a different package.

### Linux: `Lunar-Setup-<version>-x86_64.run`

A shell stub (`scripts/packaging/linux/setup-stub.sh`) followed by a tar.xz of the app
folder plus `setup/`; no `makeself`. It checks its own SHA-256, unpacks to a private
`mktemp -d` folder, runs the wizard with the packaged `lunar` and removes the folder.
(`--check` verifies it, `--extract DIR` only unpacks.) It needs `tar` and `xz`.

- **Just for me:** `~/.local/opt/lunar`, a link `~/.local/bin/lunar`,
  `~/.local/share/applications/lunar.desktop`, hicolor icons under `~/.local/share/icons`.
- **Everyone:** `/opt/lunar`, `/usr/local/bin/lunar`, `/usr/share/applications`,
  `/usr/share/icons`. The wizard starts `setup/lunar-cli setup/root_helper.lua` through
  `pkexec` with an argument list (`install <payload> <extension ids>`); it takes no
  paths to write to, rebuilds the plan itself and only uses these fixed locations. It
  refuses a payload that contains symbolic links. (The helper runs from the unpacked
  temp folder, which only your user can write to, and which the polkit dialog names.)
- Only the checked extensions are copied into `plugins/` (and anything in `plugins/`
  that isn't an extension, such as a README). Extensions with a bad manifest, for
  another OS or needing a newer host are not offered; the wizard says why.
- Files are written to a temporary name and renamed, so a running `lunar` can be
  upgraded. The icon cache and desktop database are refreshed when the tools exist.
- **Install record:** `<app>/install.json` lists every file, link and folder created,
  the install type, the version and the extensions chosen and available.
- **Upgrade:** run the setup again. It finds the record (per-user first), offers the
  same install type and the earlier extension choice (extensions that are new in the
  package start checked), replaces files and removes the old files and extensions the
  new install no longer has. Files you added yourself are left alone.
- **Uninstall:** `lunar-uninstall` or the "Uninstall Lunar" menu entry (it runs
  `<app>/setup/uninstall.lua`; for *Everyone* installs it asks for the password again).
  It removes exactly the recorded files and links, only below the recorded install
  locations, then the folders it created if they are empty. Settings in `~/.config/lunar`
  stay.

## MSI features (the engine on Windows)

`scripts\build.ps1 -Mode installer` builds the MSI with WiX 3. The layout is:

- the application (`Lunar.exe` and the embedded Lua tree) is the
  required *core* feature (`Ft_Core`);
- **each extension becomes its own optional MSI feature**, generated from what is
  present under `plugins\` — a folder extension becomes a directory component,
  a single-file extension a file component.

So an extension that lands in `plugins\` automatically appears in the setup program's
extension list (and on the MSI's own feature screen when it is run directly); its title
comes from the extension's manifest `name`.
Give the extension a clear `name` in its manifest, because that is what users see
when choosing what to install.

## Linux packages

`scripts/package_linux.sh` turns a release build into the Linux packages (all three
by default; `cmake --build --preset linux-release` runs it):

```sh
cmake --preset linux-release && cmake --build --preset linux-release
scripts/package_linux.sh [--setup] [--deb] [--appimage] [--build-dir build/linux-rel] [--out dist/linux]
```

The `.run` is described above. All three carry the same app folder as the portable zip: the `lunar` executable with
`assets/`, `certs/` and `plugins/` beside it.

- **`.deb`** (`lunar-extension-host_<version>_amd64.deb`): the app folder in
  `/opt/lunar`, `/usr/bin/lunar`, a menu entry (`lunar.desktop`) and hicolor icons.
  Dependencies are computed from the executable with `dpkg-shlibdeps`. It conflicts
  with Ubuntu's unrelated `lunar` calendar package, which also installs
  `/usr/bin/lunar`.
- **AppImage** (`Lunar-<version>-x86_64.AppImage`): one file, no install. GTK 3,
  OpenSSL 3, fontconfig and X11 come from the host, so it runs on current desktop
  distributions (glibc 2.39 or newer: Ubuntu 24.04, Mint 22, Fedora 40, Rocky 10).
  `appimagetool` and the AppImage runtime are pinned by version and SHA-256.

Extensions ship the same way as on Windows: put them in `plugins/` before packaging.
The process name is `Lunar` and the window class `Lunar`, which the menu entry's
`StartupWMClass` matches so the panel shows the Lunar icon.

## Continuous integration and releases

- `.github/workflows/ci.yml` runs on every push to `main` and every pull request:
  Windows (MSYS2) and Linux (Ubuntu 24.04) each build, run the specs, lint, the docs
  check, the compositor goldens and the process harness, then build their packages
  (MSI + setup `.exe` + portable zip; setup `.run` + `.deb` + AppImage). The Linux
  packages are smoke-tested under Xvfb (the `.run` is installed per user into a
  throwaway HOME, started and uninstalled). Packages are uploaded as workflow artifacts.
- `.github/workflows/release.yml` runs when a `vX.Y.Z` tag is pushed (or by hand).
  The tag must equal `APP_VERSION`. It builds with the CI workflow and creates a
  **draft** GitHub release with every package and `SHA256SUMS`; publish it by hand
  after checking.

## Versioning

- The host version is `APP_VERSION` in `src\lua\core\main.lua`; `build.ps1`
  refuses a `-Version` that disagrees with it.
- Each extension carries its own `version` in its manifest. The host surfaces it
  as a disabled entry at the top of the Help menu, and the update check compares
  installed extension versions against the published release metadata.

## Publishing

```powershell
.\scripts\build.ps1 -Mode all -Version <version> -PublishGitHub
.\scripts\build.ps1 -Mode all -Version <version> -PublishShare
.\scripts\build.ps1 -Mode all -Version <version> -Publish       # both
```

GitHub Releases is the canonical versioned store (`-Repo owner/name`); an SMB
share (`-HostRoot`) can mirror it with a stable latest-MSI pointer. Neither has a
default, so a build never publishes somewhere by accident.

## Checklist for a new extension

1. `plugins\<name>\init.lua` returning a table with `register(ctx)`.
2. `plugins\<name>\manifest.json` with a unique `id`, a display `name`, and a
   `version`.
3. Everything registered through `ctx` with the extension as owner, so unload and
   reload are clean.
4. Lua 5.1 compatible code (the GUI runs on LuaJIT 2.1).
5. `scripts\lint.ps1` and `scripts\test.ps1` pass.
6. Specs under `spec\` for any non-UI logic worth protecting.
