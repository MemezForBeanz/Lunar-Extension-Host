# Getting started

An extension is a Lua module in `plugins\` that returns a table with a
`register(ctx)` function. The host discovers it at startup, validates its
manifest, calls `register`, and tracks everything it creates.

## Discovery

The `core.classes.ExtensionManager` accepts two layouts:

```text
plugins\<name>.lua          single-file extension
plugins\<name>\init.lua     folder extension
```

A folder extension may ship its own modules in `classes\`, `ui\`, and `libs\`
subdirectories (required as `classes.X`, `ui.X`, `libs.X`), plus native `.dll`
modules in the extension root or a `native\` subdirectory (`.so` on Linux).
Each extension gets its own `require`: it finds these modules in the
extension's folder whenever they are required (also later, from callbacks),
keeps them in a cache of its own, and falls back to the host's `require` for
everything else. Two extensions can both ship `classes.Util` without
colliding, and Extensions > Reload Extensions runs the current code.

Extensions are loaded in sorted path order.

## Manifest

Declare identity beside the entry point:

```text
plugins\<name>.manifest.json    for plugins\<name>.lua
plugins\<name>\manifest.json    for plugins\<name>\init.lua
```

See the manifest reference for the schema. An extension without a manifest still
loads with synthesized identity metadata, but new extensions should ship one.

## Plain-table extension

```lua
local M = {}

function M.register(ctx)
    local iup = ctx.iup

    local panel = iup.vbox{
        iup.label{ TITLE = "Hello from an extension" },
    }
    ctx:addTab("Example", panel, M)

    ctx:addMenuItem("Say hello", function()
        ctx:setStatus("hello")
    end, "extensions", M)

    ctx:onReady(function()
        ctx:setStatus("Example ready")
    end, M)
end

function M.shutdown()
    -- Optional. Everything registered through ctx with M as the owner is
    -- removed by the host automatically.
end

return M
```

Pass the extension table itself as the `owner` argument so the host can tear the
registration down precisely on unload or reload.

## `core.classes.Extension` subclass

`core.classes.Extension` is a middleclass base that fills in the owner argument
for you:

```lua
local Extension = require("core.classes.Extension")

local Hello = Extension:subclass("HelloExtension")

function Hello:initialize()
    Extension.initialize(self, "Hello Extension", "1.0")
end

function Hello:register(ctx)
    local iup = ctx.iup
    self:addTab("Hello", iup.vbox{ iup.label{ TITLE = "Hello!" } })
    self:addMenuItem("Hello Extension...", function()
        iup.Message("Hello Extension", "Version: " .. self.version)
    end)
    self:log("loaded successfully")
end

return Hello:new()
```

`exampleplugins\hello.lua` is the complete worked version of this example. It
lives outside `plugins\` on purpose: the host scans `plugins\` at startup, so a
sample kept there is loaded as a real extension. Copy it into `plugins\` when you
want it to run.

## Load failures

Failures are surfaced in the app rather than swallowed. The manager reports the
phase that failed — `manifest validation`, `compile`, `initialization`,
`validation`, `manifest registration`, or `register` — and rolls back anything a
partially-registered extension already created.

## Running against a development build

```powershell
cmake -S . -B build -G "MinGW Makefiles"
cmake --build build
.\build\bin\Lunar.exe
```

`plugins\` and `assets\` are staged under `build\bin\`, so a development build
loads the same extensions as a packaged one.
