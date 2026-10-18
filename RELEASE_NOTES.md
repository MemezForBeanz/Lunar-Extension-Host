# Lunar Extension Host release notes

## 1.1.0

Lunar now runs on Linux, and installs the same way on both platforms.

| Download | Use it for |
|---|---|
| `Lunar-Setup-1.1.0.exe` | Windows: the installer (choose extensions) |
| `LunarExtensionHost-1.1.0.msi` | Windows: IT deployment and silent installs (`msiexec /i ... /qn`) |
| `Lunar-portable-1.1.0.zip` | Windows: run without installing |
| `Lunar-Setup-1.1.0-x86_64.run` | Linux: the installer (just for you, or for everyone) |
| `lunar-extension-host_1.1.0_amd64.deb` | Ubuntu, Mint, Debian: `sudo apt install ./<file>` |
| `Lunar-1.1.0-x86_64.AppImage` | Linux: run without installing |

Check downloads against `SHA256SUMS`.

- **Linux support (X11 and XWayland):** the full app on GTK 3, including interface
  motion: tab transitions, drag feedback, modal entrances and the dimmed page
  behind dialogs. Native Wayland sessions run without motion.
- **Installers:** a graphical setup for Windows (`Lunar-Setup-<version>.exe`) and
  Linux (`Lunar-Setup-<version>-x86_64.run`) that lets you choose which
  extensions to install. On Windows it runs the MSI, which is still available on
  its own for IT and silent installs. Linux also gets a `.deb` and an AppImage.
- **The app is called Lunar everywhere:** the Windows executable is `Lunar.exe`,
  Task Manager and the taskbar show "Lunar", and on Linux the `lunar` command shows
  as "Lunar" with the Lunar icon.
- **Match system theme:** an Appearance setting that uses your light theme in
  light mode and your dark theme in dark mode, following Windows and the Linux
  desktop as they change.
- **Motion:** the dimmed page behind dialogs, tab transitions and drag feedback are
  drawn by a new native compositor, which is cheaper and works on both platforms.
- **Dropdowns** in Settings are drawn by Lunar instead of the system, so they follow
  the theme; they work with the keyboard like a regular dropdown.
- **Extensions:** each extension gets its own module namespace, so reloading one
  picks up changed files and two extensions can't clash over a module name.
  Processes an extension starts are stopped when it unloads.
- **Security and robustness:** release builds no longer fall back to the working
  directory to find their files; an org profile without `fs.secure` is treated as
  untrusted; teardown finishes even if one extension's cleanup fails; Windows
  file and path APIs are fully Unicode (UTF-8 throughout). See
  `docs/trust-model.md`.
- **Building:** CI builds, tests and packages Windows and Linux on every push, and
  tagged releases are staged as draft GitHub releases with checksums.

**Updating from 1.0.0:** the update installs normally, but 1.0.0's updater tries to
reopen the old `LunarExtensionHost.exe` afterwards, which no longer exists. Reopen
Lunar from the Start menu once; later updates reopen it automatically.

## 1.0.0

The first public release.

- **Extension host:** tabs, menus, settings, status bar items, timers and
  `lunar://` routes, all owned by the extension that created them and removed
  when it unloads. Manifests declare the host API version and supported
  platforms.
- **Org packs:** an admin-installed profile can set and lock settings and ship
  its own extensions, which open together in the organization's tab group.
  Packs are trusted only from an admin-only folder.
- **Tab groups:** drag tabs to reorder them or combine them into groups; the
  arrangement is saved.
- **Themes:** Carbon-based light and dark themes plus Classic and One Dark Pro;
  extensions can register their own.
- **Motion:** tab transitions, modal entrances and progress animations that
  follow the system's reduced-motion setting.
- **Network:** `ctx:http` makes HTTP(S) requests without blocking the window;
  HTTPS checks the certificate chain and the host name by default.
- **Native services:** a process runner with a JSON-lines event protocol, the OS
  credential store for secrets, and signing in to file servers.
- **Building:** `scripts\bootstrap.ps1` restores every dependency from pinned,
  hash-checked sources, so a fresh checkout builds and tests on its own.
