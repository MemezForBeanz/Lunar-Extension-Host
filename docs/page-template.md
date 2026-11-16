# Tool page template

Use `core.ui.Kit.page(iup, options)` and return `page:widget()` from the extension.
Regions appear in keyboard order: header, optional toolbar, config/nav, main,
optional inspector and output dock. All surfaces are opaque and use theme roles.
Use `Kit.emptyPane` for content that has no rows; it has no permanent border.

```lua
local Kit = require("core.ui.Kit")
local page
local output = iup.text{ MULTILINE = "YES", READONLY = "YES", EXPAND = "YES" }
page = Kit.page(iup, {
    id = "example", title = "Example", icon = "task", settings = ctx.settings,
    state = { kind = "info", text = "Choose a location" },
    primary = { title = "Run", run = "run", action = function()
        page:setState("working", "Processing the selected location")
        page:setRunState("working", 0.25)
        -- Start your existing asynchronous operation here.
    end },
    secondary = { { title = "Copy", action = function() end } },
    config = { title = "Location", widget = location_fields, width = 280 },
    main = result_list,
    inspector = { title = "Details", widget = selection_details, open = false },
    dock = { title = "Output", widget = output, summary = "No output yet" },
    archetype = "list-detail",
})
self:addTab("Example", page:widget())
ctx:fitPage(page:widget(), function(width) page:fit(width) end)
```

`setState(kind, sentence)` updates the visible state line; kinds are info, working,
success, warning and error. `setRunState(state, progress)` drives StateIcon when
available and uses a static glyph otherwise. `setPrimary(spec)` and
`setSecondary(specs)` change actions; only two secondaries are shown, with the rest
in More alongside `menu` actions. A primary may take `widget` to retain an existing
button and its callbacks. Call `destroy()` when unloading a manually owned page.

`openInspector(boolean)` reveals selection details. Below 1000px they take the main
area until closed; below 800px Configure reveals the config column. These thresholds
use the page's own width. `openDock(boolean)` expands raw output;
`setDockSummary(kind, sentence, action)` opens failures and closes successes, keeping
the summary visible. The optional action is labelled Open error.

Split widths and dock height are bounded and persisted under `page.<id or title>.*`
when `settings` is supplied. Call `fit(width, height)` from resize handling; height
may be omitted. Dashboard pages can use `Kit.cards(iup, { cards = {...} })`, passing
`cards.widget` as main and calling `cards:fit(width)` on resize. Cards use the shared
12-column vocabulary and a 240px minimum width with 16px gutters.
