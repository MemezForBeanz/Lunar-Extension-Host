# Lunar Extension Host release notes

## 1.6.1

- **Extension installation:** Windows and Linux setup now offer compatible extensions
  from the project's `extensions/` folder alongside built-in plugins. Each is a
  separate installer choice; Windows MSI deployments can select individual features.
  Portable packages carry the same extension payload. Packaging rejects duplicate
  extension IDs and conflicting payload names.
- **Contained media tools:** Windows Media and Media Server extensions bundle their
  playback, analysis and extraction tools, with automatic private-cache preparation
  when a runtime payload is missing.
- **Media discovery and metadata:** browse supported website catalogs, save selected
  entries, look up public movie and TV metadata, and correct matches through the
  title page. Website playback depends on the selected video host's support.
- **Development:** added a VS Code task that loads project extensions and runs a
  private local media server. Fixed Windows PowerShell task executable paths.
- **Build checks:** resolved media lint warnings and documented redirect origin
  restrictions so CI lint and API reference checks pass.

## 1.6.0

Lunar adds a personal media library, native playback and streaming, with more
control over appearance and background services.

- **Lunar Media:** browse movies, shows and music, open title and episode pages,
  search and filter libraries, and save collections. Local artwork, metadata and
  generated thumbnails enrich your library without an outside metadata service.
- **Playback:** native playback includes a persistent player dock, volume,
  progress, resume and episode queues. Playback Forecast explains device delivery
  choices, and Fits Tonight builds a viewing plan for the time available.
- **Sources and repair:** combine local libraries and supported remote providers,
  inspect available copies and source health, fall back when a copy fails, and
  use catalog repair actions to diagnose and retry problems. Torrent sources
  require accepting a notice before enabling them.
- **Background services:** closing the window hides Lunar to the tray; opening
  Lunar again restores it. Headless extensions can run in a service at sign-in,
  with service status and start/stop controls in Settings.
- **Appearance and navigation:** palettes have separate light and dark modes,
  with a title-bar toggle and optional transitions. New view controls hide the
  tool rail and status bar; the Lunar terminal runs CLI commands in the app.
- **Organization branding:** packs can provide themes, tab icons and corner
  logos, including icons that retain one color across themes.
- **Fixes:** improved layout, theme contrast, media filtering and queued playback;
  corrected Linux build and documentation issues.

## 1.5.0

Lunar gives your tools more room, with independent top and left toolbars, simpler
navigation, and commands, background work and code tools in the same window.

| Download | Use it for |
|---|---|
| `Lunar-Setup-1.5.0.exe` | Windows: the installer (choose extensions) |
| `LunarExtensionHost-1.5.0.msi` | Windows: IT deployment and silent installs (`msiexec /i ... /qn`) |
| `Lunar-portable-1.5.0.zip` | Windows: run without installing |
| `Lunar-Setup-1.5.0-x86_64.run` | Linux: the installer (just for you, or for everyone) |
| `lunar-extension-host_1.5.0_amd64.deb` | Ubuntu, Mint, Debian: `sudo apt install ./<file>` |
| `Lunar-1.5.0-x86_64.AppImage` | Linux: run without installing |

Check downloads against `SHA256SUMS`.

- **GitHub updates:** every installation now checks published GitHub releases at
  startup and every six hours, with a manual check from the update icon or
  **Check for Updates** command. Windows downloads the versioned MSI, verifies its
  published SHA-256, then installs and reopens Lunar after approval. Failed or
  cancelled downloads leave Lunar running. Linux opens the release's package
  downloads. Update shares are no longer used or required.
- **Top and left toolbars:** place tabs or whole groups on either toolbar by
  dragging them or choosing **Move to Top Toolbar** or **Move to Left Toolbar**
  from the right-click menu. The sidebar shows icons or first letters until you
  expand it with the chevron at its foot or Ctrl+B. Ctrl+1 through Ctrl+9 selects
  sidebar entries. Placement and expansion are remembered across restarts.
- **Bottom toolbar:** search and the app menu return to the bottom of the window.
  The menu sits at the far left, search is centered, and Focus Pane is at the
  right. Settings moves to the upper-left gear; Ctrl+, still opens it, and pressing
  the gear again returns to the previous tab. Search and menu popups open above
  the bottom bar.
- **Nested tabs stay nested:** opening a group on either toolbar reveals a
  horizontal row of its members. Further groups open further rows. Choosing a top
  group keeps the sidebar's contents in place. Moving and ungrouping tabs preserves
  their toolbar placement, and temporarily unavailable extensions retain their
  saved positions.
- **Split panes and Focus Pane:** drag tools into side-by-side or stacked panes,
  then use Focus Pane to work in the active pane alone. Press it again or Esc to
  restore the split. Fixed a native layout issue that could re-show other panes
  while one was focused.
- **Command palette and tasks:** Ctrl+P searches commands, opens `lunar://`
  addresses and runs configured tasks. Results show categories, shortcuts and
  recent commands. The application menu uses the same searchable surface.
- **Code and Problems tabs:** a Scintilla-based code view supports viewing files,
  optional editing and saving. With a compatible language server installed and
  configured, it provides diagnostics, hover information, completions and
  go-to-definition. Extensions can register language servers through the host API.
- **Background activity:** the status bar shows running work and its outcome.
  Open the Activity panel for details, cancel supported jobs, or return to the
  related tool. Sidebar entries also indicate running work and unseen failures.
- **Appearance and Settings:** more consistent typography, spacing, field borders,
  selection states and theme-aware icons. Settings uses a category list and
  breadcrumb navigation, and tool layouts adapt to narrow panes. Resizing is
  faster, pages no longer paint over each other, and the workspace has rounded
  upper-left and lower-left junctions with the toolbars.
- **Microchip org pack:** **Microchip Tools** has four direct child tabs:
  **Black Duck Scan**, **Black Duck Server**, **Black Duck Review**, and
  **Time Clock**. Removed the unnecessary intermediate extension groups and gave
  the Black Duck tabs names that stand on their own. Existing saved layouts are
  repaired on startup, including old pack names, duplicate groups and misplaced
  organization groups, while preserving tab identities and selection.
- **Extension development:** expanded page-layout helpers, themed list and
  segmented controls, responsive layouts and requirements displays. Added an
  interactive GUI demo and script-launch tasks for checking populated pages.

**Updating:** earlier builds with the broken share-only updater need one manual
upgrade to this version; later releases can then be discovered through GitHub.
Restart Lunar after updating to apply the saved-layout repairs. The Microchip tab
changes also require the updated Microchip org pack.

## 1.2.0

Lunar now runs without a window, as a service, and has a new look.

| Download | Use it for |
|---|---|
| `Lunar-Setup-1.2.0.exe` | Windows: the installer (choose extensions) |
| `LunarExtensionHost-1.2.0.msi` | Windows: IT deployment and silent installs (`msiexec /i ... /qn`) |
| `Lunar-portable-1.2.0.zip` | Windows: run without installing |
| `Lunar-Setup-1.2.0-x86_64.run` | Linux: the installer (just for you, or for everyone) |
| `lunar-extension-host_1.2.0_amd64.deb` | Ubuntu, Mint, Debian: `sudo apt install ./<file>` |
| `Lunar-1.2.0-x86_64.AppImage` | Linux: run without installing |

Check downloads against `SHA256SUMS`.

- **Headless mode:** `lunar-cli --headless` runs extensions with no window, so an
  extension can be a scheduled service. `--require` refuses to start unless a named
  extension loads, and on stop, running jobs get `--stop-grace` seconds to finish.
  The `LUNAR_HEADLESS` CMake option builds only `lunar-cli` on Linux, without GTK.
  Extensions opt in with the manifest's `modes` (host API 3). See `docs/headless.md`.
- **Extensions can serve and store data:** `ctx:addRoute` adds authenticated HTTP
  routes under `/ext/<id>` (`http` capability), and `ctx:openDatabase` opens an
  SQLite database with versioned migrations (`database` capability). A headless
  service can read secrets from root-owned files with `--secrets-dir`.
- **HTTPS listener:** `--listen` takes bearer tokens from `--tokens-file` and serves
  HTTPS with `--tls-cert` and `--tls-key`. Listening beyond localhost requires TLS.
- **Lunar Dark and Lunar Light:** new default themes with dim lines, soft depth and
  selective rounding, paired for Match system theme. Existing installs keep the
  theme they chose.
- **Polished IUP patches:** In every theme, buttons are compact, with primary,
  secondary, hidden-until-hover, link and icon styles, and disabled buttons look
  disabled. In the Lunar themes, the selected tab is a rounded card and lists have
  rounded corners. Focus outlines follow rounded corners.
- **Collapsible tab bars:** hide a group's tab bar with its chevron. Bring it back by
  double-clicking the group's tab, from its right-click menu, or with View > Show
  all tab bars. The choice is saved.
- **Status bar fix:** it no longer clips off the bottom of a maximized window.
- **New top bar:** on Windows 11 the bar is the title bar, with the app menu, tab groups,
  the command field (Ctrl+P) and the window buttons, and Snap still works. Windows 10 and
  Linux keep their system title bar above the same bar.
- **Settings is a gear:** at the right of the bar, or Ctrl+,. Press it again to go back.
- **New app icon.**


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
