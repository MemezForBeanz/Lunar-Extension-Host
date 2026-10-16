# API stability

## What is public

Public API is what this site documents:

- `core.classes.HostAPI` — the `ctx` handed to `register(ctx)`;
- `core.classes.Extension` — the optional base class;
- `core.classes.SettingsManager`, `core.classes.ThemeManager`, and the other
  documented host classes;
- the `core.lib.*` helpers and the `core.ui.*` widget toolkit;
- the native modules (`subprocess`, `logscan`, `svgicon`, `themeapply`,
  `winredraw`, `iupraw`);
- the manifest schema and the `lunar://` address grammar.

Everything else is internal, including:

- methods whose names begin with `_` (for example `HostAPI:_markShown`,
  `HostAPI:_applyTabScopes`) — they exist for the host's own bootstrap and are
  documented only so host maintainers can follow the flow;
- file-local functions;
- the internals of extensions, including `exampleplugins\`. They are good
  references for the Host API, but they are not API.

## Versioning

The documented version tracks `APP_VERSION` in `src\lua\core\main.lua`. Host API
changes ride along with host releases:

- **Additive changes** (new methods, new optional option-table fields) may appear
  in any release.
- **Behavioral changes** to documented APIs are called out in
  `RELEASE_NOTES.md`.
- **Removals** are avoided; where an API had to change shape, the old spelling is
  kept as a thin wrapper — `HostAPI:addStatusWidget` delegating to
  `HostAPI:addStatusElement` is the pattern to expect.

Extensions declare the surfaces they use in their manifest `capabilities`, which
gives the host a place to reason about compatibility as the schema evolves. The
manifest itself is versioned by `schema_version`; a manifest with an unsupported
schema version is rejected rather than silently misread.

## Conventions for contributors

New public host APIs must ship with LDoc annotations:

- a module or class block ending in `@module`/`@classmod` with the runtime
  `require` path;
- `@tparam`/`@treturn` for every parameter and return value, including the
  `nil, err` failure shape;
- option tables documented field by field with types and defaults;
- an `@usage` example for anything an extension author would call;
- `@local` on internal methods.

Build the site locally before pushing:

```powershell
.\scripts\fetch-deps.ps1 -Dev
.\scripts\docs.ps1 -Serve
.\scripts\docs.ps1 -Check     # fails on LDoc warnings
```
