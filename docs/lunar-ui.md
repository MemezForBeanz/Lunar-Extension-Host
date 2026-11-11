# Lunar UI (`core.lui`)

Lunar UI is a component layer for Lunar's Lua UI. You describe what should be on screen
as plain Lua tables, keep state in hooks or stores, and the reconciler turns that into
`iup` widgets and keeps them in step. It runs on top of the `iup` API, so it works on
the native IUP build and on the ImGui emulator, and its widgets are ordinary iup handles
that existing code can hold, append and theme.

```lua
local ui = require("core.lui")

local function Counter(props)
  local n, setN = ui.useState(props.start or 0)
  return ui.HBox{ gap = 8, align = "center",
    ui.Text{ "Clicked " .. n .. " times" },
    ui.Button{ "Add", variant = "primary", onClick = function() setN(n + 1) end },
  }
end

local root = ui.mount(Counter, { props = { start = 1 } })
iup.Append(some_box, root:widget())     -- an ordinary iup handle
```

Compare the same thing in raw IUP: a `flatlabel` and a `flatbutton` built with string
attributes (`GAP = "8"`, `ALIGNMENT = "ACENTER"`), a `flat_action` that sets the label's
`TITLE` by hand and calls `iup.Refresh`, and a local variable holding the count that
nothing keeps in sync with what is drawn.

Contents: [concepts](#concepts) · [primitives](#primitives) · [props](#props-every-primitive-takes) ·
[events](#events) · [hooks](#hooks) · [roots and scheduling](#roots-and-scheduling) ·
[interop](#interop-with-iup-code) · [testing](#testing) · [worked example](#a-worked-example) ·
[design](#design-rationale) · [the first two migrations](#the-first-two-migrations) ·
[migration plan](#migrating-the-main-interface) · [deprecating `iup.*`](#a-deprecation-timeline-for-iup)

## Concepts

**Elements** are tables built by constructors: `ui.VBox{ ... }`. The array part holds
children; string keys are props. Children may be elements, strings and numbers (text),
plain lists of elements (flattened, so `ui.VBox{ header, rows }` works), and `nil` or
`false` holes (skipped, so `cond and ui.Text{ "x" }` reads naturally). Two props are
reserved: `key` (identity among siblings) and `ref` (receives the host handle).

`ui.h(type, props, ...)` is the explicit form: `ui.h(Card, { title = "x" }, child1, child2)`.
`ui.Fragment{ a, b }` groups children without a widget of its own.

**Components** are functions `props -> element` (or a list, a string, or `nil` for
nothing). They are called by the reconciler, never by you; inside them, hooks give state
and effects. `ui.component(fn, "Name")` makes a callable component, so `Card{ title = "x" }`
works like a primitive; a plain function works with `ui.h(Card, props)`.

**Primitives** are the host elements: each creates one iup widget (`ui.Button` is a
`flatbutton`). Their props are typed (`gap = 8`, `expand = "horizontal"`, `hidden = true`)
and mapped to iup attributes by one declarative table per primitive.

**A root** (`ui.mount`) owns one tree. State updates are queued and batched; a flush
renders the components whose state, props or context changed and commits the difference:
only changed attributes are written, children are inserted, moved and removed in place,
and the layout is refreshed once.

## Primitives

| Primitive | iup class | Props (besides the [common ones](#props-every-primitive-takes)) | Events |
|---|---|---|---|
| `VBox` | `vbox` | `gap`, `padding` (MARGIN), `align` (`start`/`center`/`end` = ALEFT/ACENTER/ARIGHT), `homogeneous` | |
| `HBox` | `hbox` | `gap`, `padding`, `align` (`start`/`center`/`end` = ATOP/ACENTER/ABOTTOM), `homogeneous` | |
| `ZBox` | `zbox` | `value` (1-based child shown, VALUEPOS), `gap`, `padding`, `align` | |
| `Spacer` | `fill` | (`size` for a fixed one) | |
| `Frame` | `flatframe` | `title`, `padding`, `gap` | |
| `Scroll` | `flatscrollbox` | `padding` | |
| `Tabs` | `flattabs` | `value` (1-based page); each page gives its own `tabTitle`, `tabImage` | `onChange(index, previous)` |
| `Split` | `split` | `orientation` (`"vertical"` = side by side, IUP's naming), `value` (0..1000), `barSize` | `onChange(value)` |
| `Text` | `flatlabel` | text children = TITLE; `wrap`, `ellipsis`, `align` (`"left:center"`), `padding`, `image` | |
| `Label` | `label` | text children = TITLE; `wrap`, `ellipsis`, `align`, `padding`, `image` | `onClick()` |
| `Image` | `label` | `image` (a handle name or a handle), `align`, `padding` | `onClick()` |
| `Button` | `flatbutton` | text children = TITLE (`&` is a mnemonic: write `&&`); `variant` (`primary`, `secondary`, `ghost`, or a role name), `padding`, `align`, `image`, `imagePosition`, `spacing`, `ellipsis` | `onClick()` |
| `Toggle` | `flattoggle` | text children = TITLE; `checked` (controlled), `switch` | `onChange(checked)` |
| `Input` | `text` | `value` (controlled), `placeholder`, `readonly`, `password`, `border`, `columns` | `onChange(value)`, `onKey(code)`, `onFocus()`, `onBlur()` |
| `Separator` | `flatseparator` | `orientation` | |
| `List` | `flatlist` | `items` (list of strings), `value` (1-based, controlled), `lines`, `columns` | `onChange(index, text)`, `onActivate(index, text)` |
| `Dropdown` | `dropbutton` (`core.ui.FlatDropdown`) | `items`, `value`, `placeholder`, `width`, `expand` (boolean), `font`, `role`, `columns`, `lines` | `onChange(index, label)` |
| `Canvas` | `canvas` | | `onDraw(handle)`, `onMouse(button, pressed, x, y, status)`, `onMotion(x, y, status)`, `onResize(w, h)` |
| `Dialog` | `dialog` | `title`, one child | `onKey(code)`, `onClose()`, `onShow(state)` |

`ui.host("flatseek")` makes a primitive for any other iup class: the common props, raw
attributes and raw callbacks. `ui.host(class, { leaf = true, content = "TITLE" })` makes
a leaf whose text children go to an attribute. `ui.definePrimitive{ ... }` registers a
full one (see the header of `core/lui/primitives.lua` for the shape).

Not built yet: data-driven `ui.Rows`/`ui.Grid` over `flatrows`/`flatgrid` (the provider
widgets behind `core.ui.RowList` and `CellGrid`). Until then embed them with `ui.Native`.

## Props every primitive takes

| Prop | Attribute | Values |
|---|---|---|
| `visible` | VISIBLE | boolean |
| `hidden` | FLOATING + VISIBLE | `true`: out of the layout and invisible (`FLOATING=YES VISIBLE=NO`, the shell's way of hiding without a gap); `false` writes both back |
| `enabled` | ACTIVE | boolean |
| `expand` | EXPAND | `true`, `false`, `"horizontal"`, `"vertical"`, `"horizontalfree"`, `"verticalfree"` |
| `size`, `width`, `height` | RASTERSIZE | `size = { w, h }` (either may be nil: natural), `width = 220` gives `"220x"` |
| `minSize`, `maxSize` | MINSIZE, MAXSIZE | `{ w, h }` or `"WxH"` |
| `tip` | TIP | string |
| `font` | FONT | an IUP font string |
| `bg`, `fg` | BGCOLOR, FGCOLOR | `"r g b"`, `{ r, g, b }`, `"#rrggbb"`, `"#rgb"`, or a palette token name (`"text_secondary"`), see below |
| `role` | THEMEROLE | a ThemeManager role, so the theme keeps styling the widget |
| `name` | NAME | string |
| `canFocus` | CANFOCUS | boolean |
| `tabTitle`, `tabImage` | TABTITLE, TABIMAGE | on a page inside `Tabs` |
| `cursor` | CURSOR | string |

Numbers become integers (`gap = 8` is `"8"`) and strings always pass through unchanged,
so values from `core.lib.CarbonLayout` (`gap = L.gap(3)`) work as they are.

**Palette tokens.** `bg = "surface_raised"` reads the active theme's palette through
`core.ui.ThemeReactor` and is resolved again on every theme switch, and re-asserted after
each theme pass in case an inherited role wrote over it. A token the palette lacks leaves
the attribute unset; `ui.token("name", "40 40 40")` gives it a fallback. A widget with a
`role` should normally leave colours to the theme and not set `bg`/`fg` at all.

**Escape hatches.** Any UPPERCASE prop is a raw attribute (`TEXTELLIPSIS = true`,
`SELECTION = "ALL"`, `ICON = "IUP"`); a raw attribute wins over a typed prop that maps
to the same name. Any lower-case `*_cb` function prop (and `flat_action`, `action`) is a
raw callback with iup's own arguments, `self` first.

## Events

`onClick = function() ... end` and friends are installed once per widget as a stable
trampoline that calls whatever handler the latest render gave. A new closure every render
(the normal case) never rewrites the widget's callback.

- The handler's return value is returned to IUP; `nil` becomes `iup.DEFAULT`. Return
  `iup.CLOSE` from a dialog's `onKey` to close a popup, `iup.IGNORE` to swallow a key.
- The handler runs in a batch: state it sets is rendered and committed **before the
  trampoline returns to IUP**, so the widgets are up to date when the event ends.
- An error in a handler is reported (see `onError`) and the trampoline returns
  `iup.DEFAULT`.
- After the handler, a controlled widget (`Input.value`, `Toggle.checked`, `List.value`,
  `Tabs.value`, `Split.value`) whose value differs from its prop is put back: if the
  handler did not accept the change, it does not stick.

**Controlled inputs** compare against the widget, not against the last value written:
`VALUE` is written only when it differs from what the widget holds, so typing into
`ui.Input{ value = v, onChange = setV }` never resets the caret.

## Hooks

Call hooks only at the top level of a component, in the same order every render.
Breaking that rule is reported with the component's name and the hook's position, and
the previous output stays on screen.

| Hook | |
|---|---|
| `local v, set = ui.useState(initial)` | `set(x)` or `set(function(prev) return next end)`. `initial` may be a function, called once. Setting the value it already has does nothing. |
| `local s, dispatch = ui.useReducer(reducer, initialArg, init)` | `dispatch` is stable across renders. |
| `ui.useEffect(fn, deps)` | After the commit. `fn` may return a cleanup, run before the next run and on unmount. `deps = nil` runs after every commit, `{}` once, otherwise when an entry changes (`~=`). |
| `ui.useLayoutEffect(fn, deps)` | Same, but before any `useEffect` of the commit: the place to touch or measure a widget through a ref. |
| `local v = ui.useMemo(fn, deps)` / `ui.useCallback(fn, deps)` | Recompute only when deps change. |
| `local ref = ui.useRef(initial)` | `ref.current`, stable across renders; changing it does not render. Pass it as `ref = ref` to get a widget. |
| `local v = ui.useContext(Ctx)` | The nearest `Ctx.Provider{ value = v, ... }` above, or the default from `ui.createContext(default)`. Consumers re-render when the value changes, even under a `ui.memo` component that did not. |
| `local v = ui.useStore(store, selector)` | A slice of a store shared with non-component code; re-renders when the selected value changes. |

Order guarantees: within a commit, all layout effects run before all effects; a child's
effects run before its parent's; all cleanups of a phase run before its setups. On
unmount, a component's layout cleanups run before its effect cleanups, children first.
An effect that sets state renders again in the same flush; a loop of those stops after
50 rounds with "maximum update depth exceeded".

**Stores** (`ui.createStore(initial)`) are for state that plain Lua code owns or shares:
`store:get()`, `store:set(table)` (a shallow merge into a table state; listeners hear
only real changes), `store:set(v, true)` (replace), `store:update(fn)`,
`store:subscribe(fn) -> unsubscribe`. `core.ui.StatusBar` is the example: its methods
write the store, its components read slices of it.

**`ui.memo(component, areEqual)`** skips re-rendering while props are shallow-equal
(childless elements share one empty `children` list, so they compare equal).

**`ui.ErrorBoundary{ fallback = el | function(err, reset) return el end, onError = fn, ...children }`**
catches an error thrown while rendering anything below it, renders the fallback instead,
and drops everything the failed subtree did in that render (its effects never run, its
state updates are discarded). `reset()` tries the children again. Without a boundary, a
render error keeps the previous output on screen and is reported through the root's
`onError` (default: `core.lib.log`, logger `lui`).

## Roots and scheduling

```lua
local root = ui.mount(App, {
  iup = iup,               -- default: the global iup
  props = { ... },         -- when the first argument is a component
  parent = some_box,       -- optional: render the children into an existing container
  onError = function(message, err) end,
  layout = "auto",         -- or "manual"
  theme = nil,             -- fn(handle) for subtrees added later; false for none
})
root:widget()        -- the top widget (root:widgets() for all of them)
root:update(props)   -- new props for the root component (or a new element); synchronous
root:flush()         -- render pending updates now
root:unmount()       -- cleanups run, widgets destroyed (Native ones only detached)
root:layoutChanged() -- the containers the last flush changed the layout of
```

The first render happens inside `ui.mount`. Later updates are batched: outside an event
handler, the first update starts a 1 ms `iup.timer` and everything queued until it fires
renders once. `ui.flushSync(fn)` runs `fn` with updates batched and flushes before
returning; the shell needs this where it sets state inside a resize callback and lays out
in the same call.

**Layout.** With `layout = "auto"`, a flush that changed a layout attribute (sizes,
margins, visibility, text, images...) or the children of a container calls `iup.Refresh`
once, on the lowest container that holds every change. With `"manual"` it never does;
the owner refreshes, using `root:layoutChanged()` if it likes. The status bar uses manual,
to keep the refreshes it always had (see below).

**Theming.** The ThemeManager themes a tree when it is shown. Widgets a root adds after
its first commit (a conditional child appearing) are handed to the bound ThemeManager's
`themeWidget`, or to `opts.theme`.

## Interop with iup code

- **Components inside iup trees.** `root:widget()` is an iup handle: append it anywhere,
  theme it, pass it to `HostAPI:addTab`. Or mount with `parent = box` to render into a box
  you own.
- **iup handles inside components.** `ui.Native{ handle = h }` (or a bare handle as a
  child) places an existing widget. The reconciler moves it into place and, on unmount,
  only detaches it, even when the widget it sat in is destroyed. It never writes its
  attributes or children.
- **Children added by other code are left alone.** A host element that was given no
  component children is never touched: extensions append their status elements into the
  status bar's extension box, a `ui.HBox{ ref = ext_box }`, and survive every re-render.
  When a box has both, the reconciler moves only its own children (a new one appended
  last goes after the foreign ones).
- **Refs.** `ref = tbl` sets `tbl.current` to the widget after the commit (and to nil on
  unmount); `ref = function(h) end` is called the same way. Use it for imperative work:
  focus, measuring, a `MotionDirector` animation.
- **Any class.** `ui.host("scintilla")`.

## Testing

`core.lui.test` renders a component on the ImGui host's headless Null backend and drives
it through real input events, so clicks hit-test the laid-out widgets and fire the same
callbacks a mouse would:

```lua
local T = require("core.lui.test")

it("adds", function()
  local r = T.render(Counter, { start = 1 })
  r:click(r:getByText("Add"))
  assert.truthy(r:getByText("Clicked 2 times"))
  r:unmount()
end)
```

`T.render(componentOrElement, props, { w, h, onError })` (a `Dialog` is shown; anything
else is mounted into a dialog). Queries: `getByText` / `queryAllByText` (TITLE, or VALUE
of an entry; `{ pattern = "..." }` for a Lua pattern), `getByRole` (THEMEROLE),
`getByName` (NAME), `queryAllByClass`, `queryAll(pred)`; `get*` errors on none or many.
Actions: `click(h)`, `type(h, "text")` (clicks it, then one character event each),
`key(iup.K_CR)`, `flush()`, `rerender(props)`, `unmount()`. Inspect with `attr(h, name)`
and `rect(h)`; `r.errors` collects reported errors. `T.boot()` starts a bare host for
specs that mount by hand. See `spec/lui_*_spec.lua`.

## A worked example

A page with state, a filtered list and a dialog. It uses a store so a service outside the
UI can add entries.

```lua
local ui = require("core.lui")

local bookmarks = ui.createStore({ items = { "Build Queue", "iLO", "Log Parser" } })

-- A dialog component: a controlled entry, Enter and Escape on the dialog.
local function AddDialog(p)
  local name, setName = ui.useState("")
  local function done(value) p.onDone(value); return iup.CLOSE end
  return ui.Dialog{ title = "Add bookmark", RASTERSIZE = "360x140",
    onKey = function(c)
      if c == iup.K_CR then return done(name) end
      if c == iup.K_ESC then return done(nil) end
    end,
    ui.VBox{ padding = 16, gap = 8,
      ui.Label{ "Name:", role = "settingslabel" },
      ui.Frame{ title = "", padding = 4, expand = "horizontal", role = "text",
        ui.Input{ value = name, onChange = setName, border = false, role = "text", expand = "horizontal" } },
      ui.HBox{ gap = 8, ui.Spacer{},
        ui.Button{ "Add", variant = "primary", padding = { 12, 5 }, onClick = function() return done(name) end },
        ui.Button{ "Cancel", variant = "secondary", padding = { 12, 5 }, onClick = function() return done(nil) end } } },
  }
end

local function showAddDialog()
  local result
  local root = ui.mount(AddDialog, { props = { onDone = function(v) result = v end } })
  iup.Popup(root:widget(), iup.CENTERPARENT, iup.CENTERPARENT)  -- or ModalMotion.popup
  root:unmount()
  return result
end

local function BookmarksPage()
  local items = ui.useStore(bookmarks, function(s) return s.items end)
  local filter, setFilter = ui.useState("")
  local selected, setSelected = ui.useState(nil)
  local shown = ui.useMemo(function()
    local out = {}
    for _, it in ipairs(items) do
      if it:lower():find(filter:lower(), 1, true) then out[#out + 1] = it end
    end
    return out
  end, { items, filter })
  return ui.VBox{ padding = 16, gap = 8,
    ui.HBox{ gap = 8, align = "center",
      ui.Input{ value = filter, onChange = setFilter, placeholder = "Filter", expand = "horizontal" },
      ui.Button{ "Add...", variant = "primary", onClick = function()
        local name = showAddDialog()
        if name and name ~= "" then
          bookmarks:update(function(s) local t = { unpack(s.items) }; t[#t + 1] = name; return { items = t } end)
        end
      end } },
    ui.List{ items = shown, value = selected, expand = true, onChange = function(i) setSelected(i) end },
    ui.Text{ #shown .. " of " .. #items .. " bookmarks", fg = "text_secondary", hidden = #items == 0 },
  }
end

-- In an extension today: self:addTab("Bookmarks", ui.mount(BookmarksPage, { iup = iup }):widget())
```

## Design rationale

**Why components and hooks.** The ~16,000 lines in `src/lua/core/ui` are mostly about
keeping widgets in step with data: write `TITLE` here, `FLOATING`+`VISIBLE` there,
remember to `iup.Refresh`, remember which closure holds the current value. A render
function says what the screen is for the current state, and the reconciler works out the
writes. Hooks keep the state next to the code that draws it, compose without classes or
inheritance, and are what most people who have written UI in the last decade already
know; an extension author coming from React reads `useState`/`useEffect` without a manual.
Plain Lua tables as elements need no build step and no new syntax.

**Why the iup driver first.** Going through the public `iup` API (`iup[class]`,
`SetAttribute`, `Append`/`Insert`/`Reparent`/`Detach`/`Destroy`, `Map`, `Refresh`) means:

1. the layer runs on the native IUP build and on the ImGui emulator, today, with no
   change to either, so the shell can migrate one module at a time while both builds ship;
2. every component widget is an ordinary iup handle: the ThemeManager themes it,
   `scripts/ui_probe.lua` walks it, `HostAPI` accepts it, extensions can append into it;
3. the migration is checkable: the StatusBar produces the same tree, attribute for
   attribute, so a probe diff and a pixel diff prove the rewrite.

The driver is a dozen functions (`core/lui/driver.lua`). When `iup.*` is retired for
extensions, a driver that builds emulator elements directly can replace it without any
component changing; components never see a handle's type or the renderer.

**Render is pure, commit is atomic.** Rendering builds new fibers and never touches a
widget or committed state. If a component throws, the new fibers are dropped and every
hook keeps its previous value, which is what makes `ErrorBoundary` and "keep the previous
output" possible.

**Only changed attributes are written** (compared with the last value written, or with the
widget itself for controlled values), and only containers whose child list changed are
touched. IUP pays per attribute write (a native call, often a relayout), so this matters
more here than in a browser.

## The first two migrations

### `core.ui.StatusBar`

The public API, the constants and the tree are unchanged: same classes, attributes,
THEMEROLEs and child order, so `main.lua`, `HostAPI`, `UpdateCheck` and `ViewLayout` did
not change. Every method writes a store and flushes, so a call still takes effect before
it returns. Six small components read slices of the store (`Settings`, `Activity`,
`StatusLine`, `CommandField`, `Logo`, `Focus`), all `ui.memo`, so a status message
renders the status line and nothing else.

| | before | after |
|---|---|---|
| lines | 327 | 384 |
| non-comment lines | 242 | 272 |

It is **not shorter**, and only partly simpler. The tree itself reads better (one
declaration per widget, typed props, no `FLOATING`/`VISIBLE` pairs, no hand-written
"did it change?" checks), but the class keeps a large imperative API that existing code
calls, and each method is now "compute the store slice, set, flush" where it used to be
"set two attributes". What stayed imperative, and what the framework would need for it
not to:

- **The status fade** animates `FGCOLOR` on the label, which the theme also writes. A prop
  cannot express "a colour the theme owns, animated from the background up to it". Needed:
  an animated-value hook over `MotionDirector` (`ui.useTransition`/`useAnimatedValue`) and a
  notion of theme-owned attributes the component can read the resting value of.
- **The Settings gear's pressed colour** is written on every call because the theme pass
  restyles the same attribute; diffing against the last write would miss a theme switch.
  Needed: the same theme-awareness (re-assert role-contested props after a pass, as tokens
  already are).
- **Refreshes**: the bar mounts with `layout = "manual"` and refreshes exactly where it did
  before (the activity box when it appears or goes, the logo box when the logo changes
  size or visibility), because `main.lua` lays the window out after `fit()` and
  `setReveal()` itself. Auto mode would add a refresh per status message and per reveal
  frame on the native build (on the emulator a refresh only marks the layout dirty, which
  the attribute write already did).
- **The two spinners** are `core.ui.StatusIcon` widgets embedded with `ui.Native`; they keep
  their own timers. A `StatusIcon` primitive would make `spinning = true` a prop.

`spec/status_bar_spec.lua` was rewritten to test the same behaviours through the public
API on the Null backend (16 tests, no private fields); it passes on the old and the new
implementation, as does the rewritten activity-slot block of `spec/activity_spec.lua`.

### `core.ui.NameDialog`

| | before | after |
|---|---|---|
| lines | 147 | 108 |
| non-comment lines | 82 | 54 |

Simpler: the dialog is one declaration, the entry is controlled (no reading `VALUE` back),
Enter and Escape are an `onKey` prop, and the four forward-declared locals and the
method-style callbacks are gone. `NameDialog.Prompt` is exported for reuse.
`spec/name_dialog_spec.lua` drives it with real input (6 tests, passing on both
implementations). One behaviour is deliberately different: once the dialog is closed and
its root unmounted, its handlers are detached, so `spec/dialog_flat_controls_spec.lua`
now presses its keys while the dialog is up.

### Evidence

(Probe and pixel comparison of the running app before and after: in progress, see status.)

## Migrating the main interface

The order goes by dependency (what the shell needs first) and by risk (how much a module
moves widgets between parents, animates, or owns native windows). Every step keeps the
module's public API, comes with a public-API spec that passes before and after, and is
checked with `ui_probe.lua` and `ui_capture.lua` as the status bar was.

**Wave 1: leaves with no reparenting (low risk).**

1. `AddressDialog`, `FeedbackDialog`, `ContextMenu` (menus: a `Menu`/`Item` primitive
   pair over `iup.menu`/`item` is needed), `ProblemsPanel`, `Diagnostics`.
2. `StatusIcon`, `ModeIcon` as primitives with `state`/`spinning` props (they wrap
   `VectorIcon`; the canvas animation stays inside).
3. `FlatField`, `CheckList`, `AppearanceSettings` (forms: controlled inputs, toggles,
   dropdowns).
   Needs from the framework: `Menu`, a `StatusIcon` primitive, an `icon` prop replacing
   `Kit.bindIcon` (it sets `IMAGE*` per theme today).

**Wave 2: panels with their own state (medium).**

4. `ActivityPanel` (already has a store: `core.classes.Activity`), `CommandPalette`,
   `Toast`, `WelcomeTour`.
5. `ToolRail`, `TitleBar`, `MenuBar`, `SettingsView` (the settings cards extensions add
   become `addSettings` taking an element).
6. `RowList`, `CellGrid`, `ReorderableList`, `ListEntrance`: needs `ui.Rows`/`ui.Grid`
   over the provider widgets, keyed by row id, and an entrance-motion hook.
   Needs: `useAnimatedValue` over `MotionDirector` (fades, entrances, the status fade),
   theme-owned attributes (above), portal-style overlays for the palette and toasts
   (today they are separate dialogs; a `ui.Popup`/`ui.Overlay` primitive).

**Wave 3: the workspace (high risk).**

7. `Terminal`, `ViewLayout`, `ShellBudget`, `WorkspaceFrame`, `Adaptive`: the layout
   arithmetic becomes state and props; `ViewLayout`'s reveal animations need the motion hook.
8. `TabGroups`, `TabOrder`, `PaneGrid`, `TabStripView`, `TabTransition`, `TabDragMotion`:
   the strips are `ui.Tabs`, the pages are extension handles embedded as
   `ui.Native{ handle = page, key = page_id }`, and which strip a page is in is state
   (page id -> zone). Moving a page is then a state change. Two things must hold, and the
   first is **not implemented yet**: (a) a `Native` that moves from one parent to another in
   one commit must be moved with `iup.Reparent` and never detached in between, or IUP
   unmaps the page and destroys its native windows (the video host's HWND, Scintilla);
   today the reconciler detaches a deleted `Native` before placing the new one, so it needs
   a cross-parent move (deletions of `Native` fibers deferred until placement, skipped if
   the handle was placed elsewhere). (b) Tab titles and images must be set on the strip
   (`TABTITLEn`) rather than on the page, since the reconciler never writes a `Native`'s
   attributes: a `titles`/`images` prop on `Tabs`. The drag itself (`TabDragMotion`'s
   snapshots and drop targets) stays imperative behind refs: it is pointer-driven motion
   over draw-call snapshots, not state.
9. `CodeView`, `CodeBinder`, `CodeWorkbench`, `CodePopup`: Scintilla stays an
   `ui.host("scintilla")` with refs for the message API; only the surrounding chrome moves.
10. `VideoHost`, `BackgroundWindow`, `Fullscreen`, `MonitorFit`, `WindowChrome`: native
    windows and OS state; they stay imperative services that components call through refs.

**Stays imperative (services, not views):** `ThemeReactor` (becomes the framework's theme
source), `ThemeTransition`, `ModalMotion`, `Scrim`, `ProgressMotion`, `AnimatedIcon`,
`VectorIcon`, `Kit` (until the `icon` prop), `PosterCache`, `UpdateCheck` (it drives the bar
through its API already).

**`main.lua`** is assembly: it builds the dialog, the content box, the workspace, the
strips and panes, wires callbacks and handles resize. In order: (1) the bottom half (status
bar done, then terminal dock and content box) as one `Shell` component mounted into the
dialog, with `fit`/`setReveal` replaced by a `window` store the resize callback writes
inside `ui.flushSync`; (2) the title bar and rail; (3) the workspace once wave 3 lands. The
dialog itself, the main loop, the tray, `HostAPI` wiring and the shortcut table stay
imperative; they are not views.

## A deprecation timeline for `iup.*`

Stages, each gated on the one before rather than on a date:

1. **Available (now).** `core.lui` ships in the exe; `iup.*` is fully supported everywhere.
2. **New core UI uses components.** Code added under `src/lua/core/ui` and in `main.lua`
   builds UI with `core.lui`; raw `iup.*` constructors there need a comment saying why
   (a native window, a class with no primitive yet). A spec greps new files for raw
   constructors outside an allowlist.
3. **Shell migrated.** Waves 1-3 above. Core code then uses `iup.*` only inside primitives,
   drivers, and the documented imperative services.
4. **Extension API published.** `ctx.ui` (this module) is part of the host API with the
   guide and examples; `addTab`, `addSettings`, `addStatusElement` and the dialogs accept
   elements and components as well as handles; `exampleplugins` are rewritten with it; the
   org packs and Lunar Media start migrating. `iup.*` keeps working unchanged.
5. **Warnings.** Direct `ctx.iup`/global `iup` use from an extension logs a one-time
   deprecation warning per extension and API name, and the extension manager shows it; a
   manifest field (`"ui": "lui"`) declares an extension migrated and turns the warnings
   into errors for it.
6. **Opt-in only.** `iup.*` for extensions needs a manifest capability
   (`"legacy_iup"`); new extensions cannot request it.
7. **Removal.** `ctx.iup` is removed; the iup driver is replaced by a direct driver over
   the emulator's elements, and `iup` becomes internal to the host.

## Status

- Done: the framework (`src/lua/core/lui.lua`, `src/lua/core/lui/*`), specs
  (`spec/lui_*_spec.lua`), the StatusBar and NameDialog migrations with public-API specs,
  this guide and the migration plan.
- In progress: before/after probe and pixel comparison of the running app.
- Not started: nothing else planned for this pass.
