# UI recipes

The host exposes a small reusable widget toolkit as `ctx.ui` (also available via
`require("core.ui.X")`), plus IUP itself as `ctx.iup`. The GUI runs on LuaJIT
with a Lua 5.1 ABI, so extension UI code must stay Lua 5.1 compatible.

## Layout and spacing

Spacing comes from the Carbon scale, not from hand-tuned pixel counts. Every
`MARGIN` and `GAP` in the host and the bundled extensions goes through
`core.lib.CarbonLayout`:

```lua
local L = require("core.lib.CarbonLayout")

iup.vbox{ ..., MARGIN = L.margin(5), GAP = L.gap(3) }   --> "16x16", "8"
iup.hbox{ ..., MARGIN = L.margin(5, 3) }                --> "16x8"
```

Steps are Carbon's own token numbers (`L.margin(5)` is `$spacing-05`), so a value
can be checked against the published scale directly. `L.ROLE` names the handful of
decisions worth stating once — `page`, `section`, `section_gap`, `row`, `row_gap`,
`inline_gap`, `label_gap` — and `L.nearest(px)` reports which step a legacy literal
should have been.

The builders assemble the Carbon page structure:

```lua
local panel = L.page(iup, {
    L.pageHeader(iup, "Trace Parser",
        "Decode a captured trace and list what it contains."),

    L.stack(iup, {
        L.sectionTitle(iup, "Trace File"),
        L.row(iup, { file_box, browse_btn, parse_btn }),
        L.hint(iup, "Choose a file of hex bytes, then Parse File."),
    }),
})
```

`stack` and `row` are Carbon's `Stack`: the parent owns the distance between its
children, so a layout is adjustable from one place instead of from every child's
margin. `page` applies the outer padding and the distance between top-level
sections, which is what makes every extension's content start at the same inset.

Controls should be sized to their content, not stretched — `L.FIELD` carries the
standard widths, and `L.CONTENT_MAX` the page caps to pass as `max_content_width`.
A field sized to a maximised window implies its value should be that long, and puts
the control thousands of pixels from its own label.

## Tabs

```lua
local panel = iup.vbox{ ... }
ctx:addTab("Example", panel, M, { max_content_width = 1400 })
```

`addTab` is lifecycle-aware: it defers mapping to `IupShow` while the dialog is
not yet visible, which is what keeps dynamically-populated children (scrollboxes
that gain rows later) from being corrupted. Never call `iup.Map` on a tab during
`register`.

Layout options (`side_padding`, `scale_side_padding`, `base_screen_width`,
`max_content_width`) let a tab center its content and cap its width on wide
monitors — see `core.classes.HostAPI`.

## Menus

```lua
ctx:addMenuItem("Open Repo...", open_repo, "file", M)
ctx:addMenuItem("Reports", show_reports, "extensions", M)
```

`"file"` and `"help"` insert above the host's pinned `Exit` and `About` entries;
`"extensions"` appends to the Extensions menu. Items are shown only while one of
the owner's tabs is active.

## Status bar

```lua
ctx:setStatus("Scanning...")

local icon = ctx.ui and build_icon() or nil
ctx:addStatusElement(icon, {
    persistent = false,     -- visible only on this extension's tabs
    position   = 2,         -- lower values sit closer to the right edge
    padding    = 4,
    tooltip    = "Queue state",
    on_click   = function(widget, button, pressed) ... end,
}, M)
```

`core.ui.StatusIcon` and `core.ui.VectorIcon` build themed, optionally spinning
status indicators from SVG assets.

## Keyboard shortcuts

```lua
ctx:registerShortcut(iup.K_cR, rescan, M)
```

Shortcuts are dialog-level and tab-scoped, so they do not steal keys from other
tabs.

## Settings

```lua
ctx:addSettings("Example", {
    entries = {
        { label = "Repo root", description = "Where scans start", widget = repo_text },
        { label = "Verbose",   description = "Log every file",    widget = verbose_toggle },
    },
}, M)
```

Sections appear in the host's single searchable Settings tab under a collapsible
category header. Two things follow from that:

- **Give every entry a `description`.** A row that has one becomes individually
  expandable — its label highlights under the pointer and clicking it reveals the
  description — so the explanation is one click away instead of permanently in the
  way. A row without one is an inert label.
- **Do not size your control.** Every entry's widget is laid into a fixed column,
  so `EXPAND = "HORIZONTAL"` fills that column rather than the window. Controls
  line up down the page regardless of which extension registered them.

Whether a category is collapsed is remembered per user across restarts, and a
search force-expands whatever holds a match without disturbing that.

Persist the values yourself through `ctx.settings`
(`core.classes.SettingsManager`):

```lua
ctx.settings:set("example.repo_root", value)
ctx.settings:save()
local root = ctx.settings:get("example.repo_root")
```

Settings live in `%APPDATA%\Lunar Extension Host\settings.json`; namespace your keys
with the extension id to avoid collisions.

## Context menus

```lua
local menu = ctx.ui.ContextMenu:new(iup, {
    { title = "Build", action = build_selected },
    { separator = true },
    { title = "Remove", action = remove_selected },
})
menu:popup(x, y)
```

Rebuild the item list with `setItems` when the available actions change, and call
`destroy` when the owning UI goes away.

## Dropdowns

Use `ctx.ui.FlatDropdown` for every pick-one-from-a-list control, not
`iup.list{ DROPDOWN = "YES" }`. A native dropdown takes the operating system's
look (a stock combo on Windows, the desktop's GTK theme on Linux) and ignores
Lunar's theme; the flat one is drawn by IUP and themed with the rest of the UI.

```lua
local dd = ctx.ui.FlatDropdown.new(iup, {
    items = { "Debug", "Release" },
    value = 1,
    width = 180,
    on_change = function(index, label) ctx:setStatus("Build: " .. label) end,
})
-- Place dd.widget in your layout; dd:setItems(...) and dd:setValue(...) change it
-- from code without calling on_change.
```

It closes on a pick (including re-picking the current item), ignores drags and
scrollbar clicks, keeps a long list scrolling inside a capped popup, and gives each
instance its own drop child, so none of that needs re-deriving per extension.

The keyboard works as on a native combo box: Space or Enter opens it, the arrow
keys move through the open list from the selected item, Enter picks and Escape
closes; while it is closed, Up, Down, Home and End change the selection directly.

One known gap: it is a drawn control, so a screen reader announces a button with
its current caption rather than a list with items. If a choice must be fully
screen-reader accessible today, a native list is still the safer pick.

## Lists

- `core.ui.ReorderableList` — multi-select list with drag-to-reorder and a drop
  indicator (`setEntries`, `append`, `getSelection`, `setReorderEnabled`, …).
- `core.ui.CheckList` — scrollable checkbox browser with selection helpers
  (`setItems`, `getChecked`, `toggleSelectionChecked`, `invertSelection`, …).

Both wrap the IUP details (hit testing, drag state, theming) that every extension
would otherwise reimplement.

## Building UI after startup

Widgets created after the window is shown are not themed yet. Tell the host:

```lua
ctx:notifyTreeChange(new_subtree)
```

Pass a specific widget to re-theme just that subtree, or omit it for the whole
dialog.

## Long-running work

The IUP event loop is single-threaded, so external tools run as processes the
host drives without blocking. A tool that speaks the JSON-lines protocol runs as
a job (see `core.lib.ProcessJob`):

```lua
ctx:startJob({
    argv = { engine, "collect", "--json" },
    on_event = function(ev) ctx:setStatus(ev.message or ev.type) end,
    on_exit = function(res) ctx:setStatus(res.status .. ": " .. tostring(res.summary)) end,
}, M)
```

Anything else uses `ctx:spawn`, polled from a host-owned timer:

```lua
local proc = assert(ctx:spawn({ argv = { "git", "status", "--porcelain" }, cwd = repo }, M))
ctx:addTimer({ time = 200, run = true, action = function()
    local out = proc:read("stdout")
    local code = proc:poll()
    ...
end }, M)
```

Both belong to the owner you pass: unloading or reloading the extension ends the
process and everything it started, and a job's callbacks stop.
Timers created through the host are destroyed on unload, and a throwing timer
callback is disarmed instead of looping on errors.

## Network requests

A blocking socket call inside a callback freezes the whole window, so use
`ctx:http`. The request runs on the host's shared scheduler and the callback
runs on the UI thread when it finishes, so it can update widgets directly:

```lua
ctx:http({
    url = "https://api.example.com/v1/items",
    headers = { accept = "application/json" },
    timeout = 15,
}, function(res, err)
    if not res then
        return ctx:setStatus("Couldn't load items: " .. err)   -- no response at all
    end
    if not res.ok then
        return ctx:setStatus("Items: HTTP " .. res.status)      -- the server said no
    end
    local items = res:json()
    ...
end, M)
```

- Send JSON with `json = { ... }` (POST by default) or raw bytes with `body`.
- HTTPS checks the certificate chain against the bundled CA store and that the
  certificate names the host. For an internal CA, pass `cafile`; `verify =
  "none"` encrypts without checking who answered, so keep it to servers you
  can't fix.
- GET and HEAD follow up to five redirects, never from https:// to http://.
- Responses over 32 MB fail unless you raise `max_bytes`.
- The callback is dropped if the extension unloads first; `ctx:http` returns a
  handle whose `cancel()` drops it sooner.

For other work that talks to the network (raw sockets, `async():probeTcp`),
wrap it in `ctx:runAsync(fn, callback)`.
