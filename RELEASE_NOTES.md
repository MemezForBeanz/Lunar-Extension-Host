# Lunar Extension Host release notes

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
