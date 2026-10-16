# Lunar Extension Host API

Lunar Extension Host (Lunar) is a Windows desktop host for firmware QA and
validation workflows. The host supplies the window, extension lifecycle,
settings, themes, menus, status bar, routing, and native services; every
user-facing tool is an extension loaded from `plugins\`.

This site documents the API those extensions are written against.

## Where to start

- **Getting started** — write and load your first extension.
- **Extension lifecycle** — `register(ctx)`, ownership, unload, and reload.
- **`HostAPI`** — the context object (`ctx`) handed to every extension. Tabs,
  menus, status elements, settings, timers, shortcuts, routes, and logging all
  hang off it.
- **Manifest reference** — the `manifest.json` identity and capability schema.
- **Tab groups** — how the tab strip nests, scrolls, and persists its layout.
- **Motion** — the Carbon-derived animation system, and `ctx:animate`.

## Layers

1. **Native host (`src\c`)** — starts IUP and LuaJIT, registers native modules,
   and executes the embedded Lua application.
2. **Lua shell (`src\lua\core`)** — application chrome plus the extension,
   settings, theme, route, status, and lifecycle services documented here.
3. **Extensions (`plugins\`)** — all workflow-specific UI and behavior.

The GUI runs on LuaJIT 2.1 with a Lua 5.1 ABI, so extension code must stay
Lua 5.1 compatible. The busted suite, luacheck, and ldoc run on that same LuaJIT,
so tests exercise extensions exactly as the application does — including the
`ffi` library, which is available to extension code.

## Minimal extension

```lua
local M = {}

function M.register(ctx)
    local iup = ctx.iup
    local tab = iup.vbox{ iup.label{ title = "Hello from an extension" } }
    ctx:addTab("Hello", tab, M)
end

function M.shutdown()
    -- Optional. Host-tracked resources are removed automatically.
end

return M
```

Drop that in `plugins\hello.lua` (with a `plugins\hello.manifest.json` beside
it) and it loads on the next launch. A complete worked version ships in
`exampleplugins\` — kept out of `plugins\` so it is not loaded until you copy it
there.
