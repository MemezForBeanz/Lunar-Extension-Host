# Extension lifecycle and ownership

## Phases

1. **Discovery** — `core.classes.ExtensionManager` scans `plugins\` for
   `<name>.lua` or `<name>\init.lua`.
2. **Manifest load** — `core.lib.ExtensionManifest` loads and validates the
   manifest beside the entry point, or synthesizes one from the file name.
3. **Compile and initialize** — the entry point is compiled and executed; it must
   return a table containing `register`.
4. **Identity registration** — `HostAPI:registerExtension` records the manifest.
   Duplicate manifest ids are rejected.
5. **`register(ctx)`** — the extension builds its UI and registers contributions.
   If it raises, `HostAPI:removeOwned` rolls back everything it created and the
   failure is reported.
6. **Version entry** — the host adds a disabled `<name>  v<version>` item to the
   top of the Help menu.
7. **`shutdown()`** — called on unload and reload, before the host removes the
   extension's tracked resources.

The dialog is not visible during `register`. Anything that requires mapped
widgets belongs in a `HostAPI:onReady` callback, which runs immediately after the
window is shown (or immediately, if the window is already up).

## Ownership

Every registration API takes an optional `owner`:

```lua
ctx:addTab("Example", panel, M)
ctx:addMenuItem("Run", run, "extensions", M)
ctx:addTimer({ time = 500, action = poll, run = true }, M)
ctx:addStatusElement(icon, { persistent = true }, M)
ctx:addSettings("Example", { entries = entries }, M)
ctx:registerShortcut(iup.K_cR, rescan, M)
ctx:registerRouteHandler("run", handle_run, M)
```

`HostAPI:removeOwned(owner)` then destroys the tabs, menu items, status
elements, settings sections, timers, shortcuts, route handlers, and pending
`onReady` callbacks that owner created. This is what makes extension reload
possible without leaking widgets or leaving dead menu entries behind.

Omitting `owner` files the registration under a shared default owner that lives
for the lifetime of the process — appropriate for host code, not for extensions.

## Tab scoping

Contributions are scoped to the owning extension's tabs:

- menu items contributed to File, Help, or Extensions are visible only while one
  of the owner's tabs is active;
- status-bar elements behave the same unless registered with
  `persistent = true`;
- keyboard shortcuts fire only while one of the owner's tabs is active.

An owner that contributes no tabs is always in scope, so headless extensions
still work.

Win32 menu items do not honor the IUP `VISIBLE` attribute, so scoping is
implemented by detaching and re-inserting items. Do not cache menu positions.

## Reload

**Extensions > Reload Extensions** runs `shutdown()` for every loaded extension,
removes their owned resources, resets the lazily created File/Help separators,
and loads everything again with a fresh context. Extensions must therefore be
safe to load twice in one process: keep module-level state out of file scope, or
reset it in `register`.

## Error isolation

- A throwing timer callback disarms its timer and reports once through the
  status bar, instead of re-firing and flooding the app with error dialogs.
- Route handler errors are converted into route error records.
- `onReady` callbacks are called under `pcall`; failures land on the status bar.
