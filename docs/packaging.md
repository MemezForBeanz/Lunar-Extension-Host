# Packaging and shipping an extension

## Where extensions live

A packaged Lunar installation keeps extensions beside the executable:

```text
LunarExtensionHost.exe
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

## MSI features

`scripts\build.ps1 -Mode installer` builds the MSI with WiX 3. The layout is:

- the application (`LunarExtensionHost.exe` and the embedded Lua tree) is the
  required *core* feature;
- **each extension becomes its own optional MSI feature**, generated from what is
  present under `plugins\` — a folder extension becomes a directory component,
  a single-file extension a file component.

So an extension that lands in `plugins\` automatically appears on the standard
MSI feature-selection screen; its feature title comes from the extension name.
Give the extension a clear `name` in its manifest, because that is what users see
when choosing what to install.

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
