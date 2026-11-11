# Lunar UI (`core.lui`)

Lunar UI is a component layer for Lunar's Lua UI. You describe what should be on screen
as plain Lua tables, keep state in hooks or stores, and the reconciler turns that into
widgets and keeps them in step. Today it drives widgets through the `iup` API, so it
works on the native IUP build and on the ImGui emulator, and its widgets are ordinary iup
handles that existing code can hold, append and theme.

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
[events](#events) · [hooks](#hooks) · [roots, scheduling and disposal](#roots-scheduling-and-disposal) ·
[styling ownership](#styling-ownership) · [interop](#interop-with-iup-code) · [testing](#testing) ·
[worked example](#a-worked-example) · [design](#design-rationale) · [the driver contract](#the-driver-contract) ·
[the first two migrations](#the-first-two-migrations) · [migration plan](#migrating-the-main-interface) ·
[deprecating `iup.*`](#a-deprecation-timeline-for-iup)

## Concepts

**Elements** are tables built by constructors: `ui.VBox{ ... }`. The array part holds
children; string keys are props. Children may be elements, strings and numbers (text),
plain lists of elements (flattened, so `ui.VBox{ header, rows }` works), and `nil` or
`false` holes, which are skipped. Two props are reserved: `key` (identity among
siblings) and `ref` (receives the widget).

**Conditional children.** Write `cond and ui.Text{ "x" }` (a `false` hole) or
`cond and ui.Text{ "x" } or nil` (a `nil` hole); both are skipped wherever they are. A
Lua table constructor with `nil` holes has no reliable length (`#t` may stop at the first
hole), so the children are collected up to the table's largest integer key
(`table.maxn`), and `ui.h(type, props, ...)` counts its varargs with `select("#", ...)`;
nothing in Lunar UI uses `#` or `ipairs` on a props table. Positions of unkeyed children
are their positions after the holes are dropped; give children that come and go a `key`.

`ui.h(type, props, ...)` is the explicit form: `ui.h(Card, { title = "x" }, child1, child2)`.
`ui.Fragment{ a, b }` groups children without a widget of its own.

**Components** are functions `props -> element` (or a list, a string, or `nil` for
nothing). They are called by the reconciler, never by you; inside them, hooks give state
and effects. `ui.component(fn, "Name")` makes a callable component, so `Card{ title = "x" }`
works like a primitive; a plain function works with `ui.h(Card, props)`.

**Primitives** are the host elements: each creates one widget (`ui.Button` is a
`flatbutton`). Their props are typed and named for what they mean, not for IUP's
attributes, and mapped to attributes by one declarative table per primitive.

**A root** (`ui.mount`) owns one tree. State updates are queued and batched; a flush
renders the components whose state, props or context changed and commits the difference:
only changed attributes are written, children are inserted, moved and removed in place,
and the layout is refreshed once.

## Primitives

| Primitive | widget | Props (besides the [common ones](#props-every-primitive-takes)) | Events |
|---|---|---|---|
| `VBox` | `vbox` | `gap`, `padding`, `align` (`"start"`/`"center"`/`"end"`, across), `uniform` (equal child sizes) | |
| `HBox` | `hbox` | `gap`, `padding`, `align` (`"start"`/`"center"`/`"end"`, across), `uniform` | |
| `ZBox` | `zbox` | `selected` (1-based child shown), `gap`, `padding`, `align` | |
| `Spacer` | `fill` | (`size` for a fixed one) | |
| `Frame` | `flatframe` | `title`, `padding`, `gap` | |
| `Scroll` | `flatscrollbox` | `padding` | |
| `Tabs` | `flattabs` | `selected` (1-based page); each page gives its own `tabTitle`, `tabImage` | `onChange` (`value`, `previous`) |
| `Split` | `split` | `direction` (`"row"`: side by side, `"column"`: stacked), `ratio` (0..1, the first pane's share), `sashSize` | `onChange` (`value` = ratio) |
| `Text` | `flatlabel` | text children; `wrap`, `ellipsis`, `align` (`"left"`/`"center"`/`"right"`), `valign` (`"top"`/`"center"`/`"bottom"`), `padding`, `image` | |
| `Label` | `label` | text children; `wrap`, `ellipsis`, `align`, `valign`, `padding`, `image` | `onClick` |
| `Image` | `label` | `image` (a handle name), `align`, `valign`, `padding` | `onClick` |
| `Button` | `flatbutton` | text children (`&` is a mnemonic: write `&&`); `variant` (`"primary"`, `"secondary"`, `"ghost"`), `padding`, `align`, `valign`, `image`, `imagePosition` (`"left"`...), `spacing`, `ellipsis` | `onClick` |
| `Toggle` | `flattoggle` | text children; `checked` (controlled), `switch` | `onChange` (`value` = checked) |
| `Input` | `text` | `value` (controlled), `placeholder`, `readonly`, `password`, `border`, `columns` | `onChange` (`value`), `onKey` (`key`), `onFocus`, `onBlur` |
| `Separator` | `flatseparator` | `orientation` (`"horizontal"`: a line across) | |
| `List` | `flatlist` | `items` (list of strings), `selected` (1-based, controlled), `lines`, `columns` | `onChange` (`value` = index, `text`), `onActivate` (double-click) |
| `Dropdown` | `core.ui.FlatDropdown` | `items`, `selected`, `placeholder`, `width`, `grow` (boolean), `font`, `role`, `columns`, `lines` | `onChange` (`value` = index, `text`) |
| `Canvas` | `canvas` | | `onDraw`, `onMouse` (`button` 1-3, `pressed`, `x`, `y`), `onMotion` (`x`, `y`), `onResize` (`width`, `height`) |
| `Dialog` | `dialog` | `title`, one child | `onKey` (`key`), `onClose`, `onShow` (`value`) |

`ui.host("flatseek")` makes a primitive for any other widget class: the common props and
the `iup` namespace. `ui.host(class, { leaf = true, content = "TITLE" })` makes a leaf
whose text children go to an attribute. `ui.definePrimitive{ ... }` registers a full one
(see the header of `core/lui/primitives.lua` for the shape).

Not built yet: data-driven `ui.Rows`/`ui.Grid` over `flatrows`/`flatgrid` (the provider
widgets behind `core.ui.RowList` and `CellGrid`). Until then embed them with `ui.Native`.

## Props every primitive takes

| Prop | Meaning |
|---|---|
| `hidden` | `true`: not displayed **and takes no space** (the box closes the gap). `false` shows it again. |
| `invisible` | `true`: not drawn **but keeps its space**. |
| `enabled` | `false` greys it out and ignores input. |
| `grow` | Whether it takes a share of its box's free space: `true` both ways, `"x"` horizontally, `"y"` vertically, `false` never. Children that grow split the free space evenly after every child got its natural size; growing never shrinks a child below its natural size or `minSize`. Unset means the primitive's own default (boxes and buttons do not grow; entries, lists and tabs grow across, as their widgets do). |
| `size`, `width`, `height` | A fixed size: `size = { w, h }` (either may be nil: natural on that axis), or `width = 220`. A box can fix only its own direction (a `VBox` its height, an `HBox` its width). |
| `minSize`, `maxSize` | `{ w, h }` limits. |
| `tooltip` | Text shown on hover. |
| `font` | A font string, `"Segoe UI, 10"` (see the driver notes). |
| `bg`, `fg` | `"r g b"`, `{ r, g, b }`, `"#rrggbb"`, `"#rgb"`, or a palette token (`"text_secondary"`, `ui.token(name, fallback)`). See [styling ownership](#styling-ownership). |
| `role` | A ThemeManager role: the theme styles the widget. |
| `name` | An identifier for tests and lookups. |
| `focusable` | Whether it takes keyboard focus. |
| `tabTitle`, `tabImage` | On a page inside `Tabs`. |
| `cursor` | The pointer over it. |

Values are typed: numbers for sizes and gaps (`gap = 8`, `padding = { 8, 0 }`), booleans
for flags, words for choices. `core.lib.CarbonLayout`'s spacing scale is `L.px(step)`.

**The `iup` compatibility namespace.** IUP attributes and callbacks that have no typed
prop go in one explicit table: `iup = { SHRINK = "YES", PARENTDIALOG = dlg, k_any = fn }`.
Attribute values may be strings, numbers (written as integers), booleans (`YES`/`NO`) or
handles; a function is a callback called with IUP's own arguments, `self` first. Nothing
outside that table is passed to IUP as is.

**Development mode** (on by default; `ui.setDevMode(false)`, or `LUNAR_LUI_DEV=0` at
start, turns it off) makes these render errors, reported with the primitive's name: an
unknown prop (with "did you mean" for a near miss, and a pointer to the `iup` namespace
for an UPPERCASE or `*_cb` name), a value of the wrong type or outside its choices, a
typed prop and an `iup` attribute that set the same attribute, and a `role` combined with
a palette token colour. A render error keeps the previous output on screen.

## Events

Every handler receives **one event table, the same shape for every primitive**:

```lua
onChange = function(e)
  -- e.type:   "click" "change" "key" "focus" "blur" "activate" "close" "show"
  --           "draw" "mouse" "motion" "resize"
  -- e.target: the widget
  -- and, where they apply: e.value, e.text, e.previous, e.key, e.x, e.y,
  --           e.button, e.pressed, e.width, e.height
end
```

Return `ui.CLOSE` (close a popup), `ui.IGNORE` (swallow a key) or `ui.CONTINUE`, or
nothing for the default handling.

Handlers are installed once per widget as a stable trampoline that calls whatever handler
the latest render gave, so a new closure every render (the normal case) never rewrites
the widget. A handler runs in a batch: state it sets is rendered and committed before the
trampoline returns. An error in a handler is reported and the default is returned. After
the handler, a controlled widget (`Input.value`, `Toggle.checked`, `List.selected`,
`Tabs.selected`, `Split.ratio`) whose value differs from its prop is put back: a change
the handler did not accept does not stick. Controlled values compare against the widget,
not the last value written, so typing into `ui.Input{ value = v, onChange = function(e)
setV(e.value) end }` never resets the caret.

## Hooks

Call hooks only at the top level of a component, in the same order every render. A hook
called conditionally, or a different number of hooks than last time, is an error naming
the component and the hook's position, and the previous output stays on screen.

| Hook | |
|---|---|
| `local v, set = ui.useState(initial)` | `set(x)` or `set(function(prev) return next end)`; `set(nil)` works. `initial` may be a function, called once. Setting the value it already has does nothing; calling `set` after the component unmounted does nothing. |
| `local s, dispatch = ui.useReducer(reducer, initialArg, init)` | `dispatch` is stable across renders. |
| `ui.useEffect(function(scope) ... end, deps)` | After the commit. May return a cleanup, run before the next run and on unmount. `scope.alive()` is true until then; `scope.onCleanup(fn)` adds cleanups. `deps = nil`: after every commit; `{}`: once; otherwise when an entry changes (`~=`). |
| `ui.useLayoutEffect(fn, deps)` | Same, but before any `useEffect` of the commit: the place to touch or measure a widget through a ref. |
| `local ref = ui.useRef(initial)` | `ref.current`, stable across renders; changing it does not render. Pass it as `ref = ref` to get a widget. |
| `local v = ui.useContext(Ctx)` | The nearest `Ctx.Provider{ value = v, ... }` above, or the default from `ui.createContext(default)`. Consumers re-render when the value changes, even under a `ui.memo` component that did not. |
| `local v = ui.useStore(store, selector)` | A slice of a store shared with non-component code; re-renders when the selected value changes. A store change after unmount does nothing. |
| `ui.useMemo(fn, deps)`, `ui.useCallback(fn, deps)` | **Optimisations.** Reach for them only after measuring a render that is too slow; a render of a few dozen elements costs far less than one IUP layout. |

**Dependency lists with nil.** `{ a, b }` with `a == nil` has an unreliable length. Build
lists that may hold nil with `ui.deps(a, b, c)`, which records the count; plain tables are
compared up to their largest index, which is right except that it cannot tell `{ nil }`
from `{}`.

**Async work in effects.** Lunar's async code runs in coroutines that resume later (an
HTTP response, a process exiting). A resumed coroutine must not touch a component that has
moved on, so check the effect's scope after every resume:

```lua
ui.useEffect(function(scope)
  local job = async(function()               -- a coroutine that yields while it waits
    local body = http.get(url)                -- resumes when the response arrives
    if not scope.alive() then return end      -- url changed, or the page went away
    setData(body)
  end)
  scope.onCleanup(function() job:cancel() end) -- if the API can cancel, do that too
end, ui.deps(url))
```

Setters called after unmount are no-ops anyway; `scope.alive()` is for the work in
between (parsing, follow-up requests, writes to shared state).

Order guarantees: within a commit, all layout effects run before all effects; a child's
effects run before its parent's; all cleanups of a phase run before its setups. On
unmount, a component's layout cleanups run before its effect cleanups, children first.

**Stores** (`ui.createStore(initial)`) are for state that plain Lua code owns or shares:
`store:get()`, `store:set(table)` (a shallow merge into a table state; listeners hear only
real changes), `store:set(v, true)` (replace), `store:update(fn)`,
`store:subscribe(fn) -> unsubscribe`. `core.ui.StatusBar` is the example.

**`ui.memo(component, areEqual)`** skips re-rendering while props are shallow-equal. Like
`useMemo`, an optimisation to use after measuring.

**`ui.ErrorBoundary{ fallback = el | function(err, reset) return el end, onError = fn, ...children }`**
catches an error thrown while rendering anything below it, renders the fallback instead,
and drops everything the failed subtree did in that render (its effects never run).
`reset()` tries the children again. Without a boundary, a render error keeps the previous
output on screen and is reported through the root's `onError` (default: `core.lib.log`,
logger `lui`).

**The state model is pluggable.** Everything above lives in `core/lui/hooks.lua`, which
implements a four-call interface (`render`, `commit`, `abort`, `unmount`; see its header).
The reconciler and the driver know nothing of hooks. A component type may name another
model, `ui.component(fn, { model = M })`; `spec/lui_hooks_spec.lua` renders a component
with a toy setup-once/signal model through the unchanged reconciler.

## Roots, scheduling and disposal

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
root:unmount()
root:layoutChanged() -- the containers the last flush changed the layout of
```

**The commit queue.** The first render happens inside `ui.mount`. Later updates join a
queue. Outside a batch, the first one arms a timer (IUP's minimum of 1 ms: it fires on the
next pass of the main loop; it is not a microtask); later updates do not re-arm it, and it
stops itself before it flushes, so it never repeats. Event handlers and `ui.flushSync(fn)`
run in batches that flush synchronously when the outermost batch of the current main-loop
level ends. A modal loop (`iup.Popup`) opened inside a handler runs one level deeper, so
the dialog's own handlers flush their updates while it is up. A flush requested while a
flush runs at the same level (an effect that sets state) is taken by the running flush in
its next round, never by recursion; a flush started from a nested modal loop skips a root
that is mid-flush further out and leaves it queued for that flush, so nothing is lost and
no root renders inside its own commit. An effect that keeps setting state stops after 50
rounds with "maximum update depth exceeded". `root:flush()`, `root:update()` and
`ui.flushSync()` render synchronously; the shell relies on that where it sets state inside a
resize callback and lays out in the same call. `spec/lui_scheduler_spec.lua` covers each
case.

**Layout.** With `layout = "auto"`, a flush that changed a layout attribute (sizes,
margins, visibility, text, images...) or the children of a container calls `iup.Refresh`
once, on the lowest container that holds every change. With `"manual"` it never does; the
owner refreshes, using `root:layoutChanged()` if it likes.

**Disposal contract** (`root:unmount()`):

- every effect cleanup runs (layout before effect, children before parents), every
  effect scope turns dead, every ref is set to nil; setters and store changes that reach the
  tree afterwards do nothing;
- every widget this root created is destroyed;
- a `ui.Native` handle is **borrowed** unless the element says `owned = true`: a borrowed
  handle is never destroyed. It is left where it is when that is a container the root does
  not own (`opts.parent`); inside a widget the root created it is detached first, since
  destroying the container would destroy it. An owned one is destroyed with the tree, and
  when it is removed from it;
- children other code appended into the root's widgets (an extension's status element) are
  detached before those widgets are destroyed: a host element never destroys or removes
  children it did not create. (A class's own internal children, such as a split's sash,
  go with it.)
- `opts.parent` itself is untouched;
- unmounting twice is a no-op; `root:update()` afterwards is an error, `root:flush()` a
  no-op returning false, `root:widget()` nil.

During updates the same rules hold: a removed borrowed Native is detached, a removed owned
one destroyed, and a Native that moves to another parent in the same commit is moved with
`iup.Reparent` (never detached in between, which on the native build would destroy its
windows).

## Styling ownership

One owner per widget's colours:

- **A widget with a `role` belongs to the theme.** The ThemeManager styles it on every
  pass. `bg`/`fg` literals on it are only the look when the active theme has no rule (the
  Classic look the status bar keeps); the theme replaces them. A `role` together with a
  palette *token* colour is a development-mode error: a token means the component wants to
  own the colour, which the theme would fight.
- **Explicit colours on a widget without a role belong to the component.** Literal or
  token, they are claimed through `core.ui.ThemeReactor.claim`, and the ThemeManager
  neither writes those attributes nor records them as the widget's "original" look, so a
  theme switch never restores a colour resolved for an earlier theme. Tokens are resolved
  again on every theme switch, and re-asserted after each pass.
- Everything else (fonts, padding the theme sets per class) stays the theme's.

Before this rule, a token-coloured widget without a role was themed by its class rule,
which overwrote the colour during the pass and captured the token colour as the widget's
original; the final colour was right only because lui re-asserted it after the pass.
`spec/lui_styling_spec.lua` checks the ThemeManager's per-widget step against a lui widget.

## Interop with iup code

- **Components inside iup trees.** `root:widget()` is an iup handle: append it anywhere,
  theme it, pass it to `HostAPI:addTab`. Or mount with `parent = box` to render into a box
  you own.
- **iup handles inside components.** `ui.Native{ handle = h }` (or a bare handle as a
  child) places an existing widget, borrowed (see the disposal contract); `owned = true`
  hands it over. The reconciler never writes a Native's attributes or children.
- **Children added by other code are left alone.** A host element given no component
  children is never touched: extensions append their status elements into the status
  bar's extension box, a `ui.HBox{ ref = ext_box }`, and survive every re-render. When a box
  has both, the reconciler moves only its own children (a new one appended last goes after
  the foreign ones).
- **Refs.** `ref = tbl` sets `tbl.current` to the widget after the commit (and to nil on
  unmount); `ref = function(h) end` is called the same way. Use them for imperative work:
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
`getByName` (`name`), `queryAllByClass`, `queryAll(pred)`; `get*` errors on none or many.
Actions: `click(h)`, `type(h, "text")` (clicks it, then one character event each),
`key(iup.K_CR)`, `flush()`, `rerender(props)`, `unmount()`. Inspect with `attr(h, name)`
and `rect(h)`; `r.errors` collects reported errors. `T.boot()` starts a bare host for specs
that mount by hand. See `spec/lui_*_spec.lua`.

## A worked example

A page with state, a filtered list and a dialog. It uses a store so a service outside the
UI can add entries.

```lua
local ui = require("core.lui")

local bookmarks = ui.createStore({ items = { "Build Queue", "iLO", "Log Parser" } })

-- A dialog component: a controlled entry, Enter and Escape on the dialog.
local function AddDialog(p)
  local name, setName = ui.useState("")
  local function done(value) p.onDone(value); return ui.CLOSE end
  return ui.Dialog{ title = "Add bookmark", size = { 360, 140 },
    onKey = function(e)
      if e.key == iup.K_CR then return done(name) end
      if e.key == iup.K_ESC then return done(nil) end
    end,
    ui.VBox{ padding = 16, gap = 8,
      ui.Label{ "Name:", role = "settingslabel" },
      ui.Frame{ title = "", padding = 4, grow = "x", role = "text",
        ui.Input{ value = name, onChange = function(e) setName(e.value) end,
          border = false, role = "text", grow = "x" } },
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
  local shown = {}
  for _, it in ipairs(items) do
    if it:lower():find(filter:lower(), 1, true) then shown[#shown + 1] = it end
  end
  return ui.VBox{ padding = 16, gap = 8,
    ui.HBox{ gap = 8, align = "center",
      ui.Input{ value = filter, onChange = function(e) setFilter(e.value) end, placeholder = "Filter", grow = "x" },
      ui.Button{ "Add...", variant = "primary", onClick = function()
        local name = showAddDialog()
        if name and name ~= "" then
          bookmarks:update(function(s) local t = { unpack(s.items) }; t[#t + 1] = name; return { items = t } end)
        end
      end } },
    ui.List{ items = shown, selected = selected, grow = true, onChange = function(e) setSelected(e.value) end },
    #items == 0 and ui.Text{ "No bookmarks yet" } or nil,
    ui.Text{ #shown .. " of " .. #items .. " bookmarks", fg = "text_secondary" },
  }
end

-- In an extension today: self:addTab("Bookmarks", ui.mount(BookmarksPage, { iup = iup }):widget())
```

## Design rationale

**Why components and hooks.** The ~16,000 lines in `src/lua/core/ui` are mostly about
keeping widgets in step with data: write `TITLE` here, `FLOATING`+`VISIBLE` there,
remember to `iup.Refresh`, remember which closure holds the current value. A render
function says what the screen is for the current state, and the reconciler works out the
writes. Hooks keep the state next to the code that draws it and compose without classes;
an extension author coming from React reads `useState`/`useEffect` without a manual. Plain
Lua tables as elements need no build step and no new syntax. Whether hooks or a
setup-once/signal model is the long-term state model is the owner's decision; the
reconciler does not depend on it (see "The state model is pluggable").

**Why the iup driver first.** Going through the public `iup` API means:

1. the layer runs on the native IUP build and on the ImGui emulator, today, with no change
   to either, so the shell can migrate one module at a time while both builds ship;
2. every component widget is an ordinary iup handle: the ThemeManager themes it,
   `scripts/ui_probe.lua` walks it, `HostAPI` accepts it, extensions can append into it;
3. the migration is checkable: the status bar produces the same tree, attribute for
   attribute, so a probe diff and a pixel diff prove the rewrite.

**Render is pure, commit is atomic.** Rendering builds new fibers and never touches a
widget or committed state. If a component throws, the new fibers are dropped and every
hook keeps its previous value, which is what makes `ErrorBoundary` and "keep the previous
output" possible.

**Only changed attributes are written** (compared with the last value written, or with the
widget itself for controlled values), and only containers whose child list changed are
touched. IUP pays per attribute write (a native call, often a relayout), so this matters
more here than in a browser.

## The driver contract

The reconciler talks to widgets through one table (`core/lui/driver.lua`). In neutral
terms, a driver provides:

| Operation | What it must do | iup driver |
|---|---|---|
| create(kind, props) | make a widget of a primitive's kind with its initial typed props applied | `iup[class](attrs)` |
| patch(widget, changes) | apply changed typed props; a removed prop returns to the default | `SetAttribute`, `SetAttributeHandle`, nil to reset |
| read(widget, prop) | the widget's current value, for controlled props | `GetAttribute` |
| listen(widget, event, fn) | deliver an event once, through a stable callback | `h[cb] = fn` |
| insert(parent, child, before) | place a new child | `Append`, `Insert`, then `Map` when the parent is mapped |
| move(parent, child, before) | move a placed child, **preserving its identity and native resources** | `Reparent` |
| remove(child) | take a child out without destroying it | `Detach` |
| dispose(widget) | destroy a widget and what it created | `Destroy` |
| children / parent | the tree, and the children other code added (`userChildren`) | `GetChild*`, `GetParent` |
| measure / request layout | lay out the smallest changed subtree once per commit | `Refresh` on the common ancestor; geometry via `RASTERSIZE` |
| schedule(fn) | run a flush on the next pass of the event loop; report the loop's nesting level | `iup.timer`, `MainLoopLevel` |
| result(code) | translate `ui.CLOSE`/`IGNORE`/`CONTINUE` | `iup.CLOSE`... |

What in the current typed prop table is IUP-specific and would not survive a direct driver
unchanged:

- **The attribute strings themselves.** `props.lua` converts typed props to IUP attribute
  strings (`"16x16"`, `"ACENTER:ACENTER"`, `"YES"`), and the reconciler diffs those strings.
  A direct driver should receive the typed values; the diff would move to typed values.
- **`hidden` as `FLOATING`+`VISIBLE`**, `grow` as `EXPAND`, `size` as `RASTERSIZE` (and the
  rule that a box can fix only its own direction), `uniform` as `HOMOGENEOUS`, Split's
  `direction` naming the sash, `ratio` in thousandths.
- **`font`** is an IUP font string (`"Segoe UI, 10"`, face and size, with IUP's style
  words), and **`image`** a handle name registered with `iup.SetHandle`.
- **`role`** reaches the ThemeManager as the `THEMEROLE` attribute, and palette tokens are
  read from `ThemeReactor`; a direct driver needs a theme interface instead.
- **Selections** (`List.selected`, `Tabs.selected`) have to be written after the items or
  pages exist (`late` attributes), an IUP ordering rule.
- **Events** are adapted from IUP callbacks (`flat_action`, `valuechanged_cb`,
  `tabchangepos_cb`, `k_any` key codes with IUP's modifier bits, mouse buttons as `'1'..'3'`
  codes); the event tables are driver-neutral, the key codes in them are not yet.
- **The `iup` namespace** is by definition IUP-only.

## The first two migrations

### `core.ui.StatusBar`

The public API, the constants and the tree are unchanged: same classes, attributes,
THEMEROLEs and child order, so `main.lua`, `HostAPI`, `UpdateCheck` and `ViewLayout` did
not change. Every method writes a store and flushes, so a call still takes effect before it
returns. Six small components read slices of the store (`Settings`, `Activity`,
`StatusLine`, `CommandField`, `Logo`, `Focus`), so a status message renders the status
line and nothing else.

| | before | after |
|---|---|---|
| lines | 327 | 385 |
| non-comment lines | 242 | 273 |

It is **not shorter**, and only partly simpler. The tree reads better (one declaration per
widget, typed props, no `FLOATING`/`VISIBLE` pairs, no hand-written "did it change?"
checks), but the class keeps a large imperative API that existing code calls, and each
method is now "compute the store slice, set, flush" where it used to be "set two
attributes". What stayed imperative, and what the framework would need for it not to:

- **The status fade** animates `FGCOLOR` on the label, which the theme owns (the label has
  a role). A prop cannot express "a colour the theme owns, animated from the background up
  to it". Needed: an animated-value hook over `MotionDirector` and a way to read a
  theme-owned resting value.
- **The Settings gear's pressed colour** is written on every call because the theme pass
  restyles the same attribute (the button has a role); diffing against the last write
  would miss a theme switch.
- **Refreshes**: the bar mounts with `layout = "manual"` and refreshes exactly where it
  did before, because `main.lua` lays the window out after `fit()` and `setReveal()`. Auto
  mode would add a refresh per status message and per reveal frame on the native build.
- **The two spinners** are `core.ui.StatusIcon` widgets embedded with `ui.Native`; they
  keep their own timers.

`spec/status_bar_spec.lua` was rewritten to test the same behaviours through the public
API on the Null backend (16 tests, no private fields); it passes on the old and the new
implementation, as does the rewritten activity-slot block of `spec/activity_spec.lua`.

### `core.ui.NameDialog`

| | before | after |
|---|---|---|
| lines | 147 | 111 |
| non-comment lines | 82 | 56 |

Simpler: the dialog is one declaration, the entry is controlled (no reading `VALUE` back),
Enter and Escape are an `onKey` handler, and the forward-declared locals and method-style
callbacks are gone. Three window settings with no typed prop (`ICON`, `SHRINK`,
`PARENTDIALOG`) and the entry's initial `SELECTION` go through the `iup` namespace.
`spec/name_dialog_spec.lua` drives it with real input (6 tests, passing on both
implementations). One behaviour is deliberately different: once the dialog is closed and
its root unmounted, its handlers are detached, so `spec/dialog_flat_controls_spec.lua` now
presses its keys while the dialog is up.

### Evidence: the running app before and after

The exe was built with the same flow before and after and run on a private desktop at the
default size with the HPE org packs, each time with `scripts/ui_probe.lua` (once with
`LUNAR_PROBE_NOCLICK=1` for rectangles and resolved attributes, once clicking every
control) and `scripts/ui_capture.lua ... shot` (24 page shots). Runs: `before` and
`before2` (the old code: the probe and capture scripts load the Lua of the checkout they are
run from, so `before2` ran from a worktree at the pre-migration commit), `after` and
`after2` (the component StatusBar and NameDialog), and `after3` (the final code, after the
review changes).

- **Status bar rectangles and attributes**: 0 differing probe lines among the status bar's
  392 element and attribute lines, once icon handle serials (`IMAGE=VectorIcon_<n>`, numbered
  in creation order) are normalised.
- **Clicks**: every control in the status bar fires the same callbacks before and after;
  the only differences are how many repaint `ACTION`s follow, which differ the same way
  between two runs of the old code.
- **Pixels, old code (before2) vs final code (after3)**: 0 differing pixels on 21 of the 24
  shots. The other three: the Time Clock page (its clock text), and about 100 px on two
  activity shots, all inside the 14 px spinning activity icon (x 49-62 at the bar's left),
  which is at a different angle in every run. Two runs of the same code differ on the same
  pages by the same amounts (after vs after2: the clock page, and 90-445 px on the activity
  shots).
- **The first old run** showed the status text drawn in the background colour on every page
  (the old fade stuck at its first frame when the shots were taken). The second run of the
  same old code did not, so it is a timing effect of the fade, not a difference between the
  implementations.

## Migrating the main interface

The order goes by dependency (what the shell needs first) and by risk (how much a module
moves widgets between parents, animates, or owns native windows). Every step keeps the
module's public API, comes with a public-API spec that passes before and after, and is
checked with `ui_probe.lua` and `ui_capture.lua` as the status bar was.

**Wave 1: leaves with no reparenting (low risk).**

1. `AddressDialog`, `FeedbackDialog`, `ContextMenu` (a `Menu`/`Item` primitive pair over
   `iup.menu`/`item` is needed), `ProblemsPanel`, `Diagnostics`.
2. `StatusIcon`, `ModeIcon` as primitives with `state`/`spinning` props (they wrap
   `VectorIcon`; the canvas animation stays inside).
3. `FlatField`, `CheckList`, `AppearanceSettings` (forms: controlled inputs, toggles,
   dropdowns).
   Needs: `Menu`, a `StatusIcon` primitive, an `icon` prop replacing `Kit.bindIcon` (it sets
   `IMAGE*` per theme today).

**Wave 2: panels with their own state (medium).**

4. `ActivityPanel` (already has a store: `core.classes.Activity`), `CommandPalette`,
   `Toast`, `WelcomeTour`.
5. `ToolRail`, `TitleBar`, `MenuBar`, `SettingsView` (the settings cards extensions add
   become `addSettings` taking an element).
6. `RowList`, `CellGrid`, `ReorderableList`, `ListEntrance`: needs `ui.Rows`/`ui.Grid` over
   the provider widgets, keyed by row id, and an entrance-motion hook.
   Needs: an animated-value hook over `MotionDirector` (fades, entrances, the status fade),
   theme-owned resting values, overlays for the palette and toasts (a `ui.Popup` primitive).

**Wave 3: the workspace (high risk).**

7. `Terminal`, `ViewLayout`, `ShellBudget`, `WorkspaceFrame`, `Adaptive`: the layout
   arithmetic becomes state and props; `ViewLayout`'s reveal animations need the motion hook.
8. `TabGroups`, `TabOrder`, `PaneGrid`, `TabStripView`, `TabTransition`, `TabDragMotion`.
   Pages are the problem. They are extension handles with native windows inside (the video
   host's HWND, Scintilla), and TabGroups moves them between strips with `iup.Reparent`
   because detaching unmaps a page and destroys those windows. The plan: a **page registry**
   (page id -> handle, owned by the host, never by a component) and the strips as `ui.Tabs`
   whose children are `ui.Native{ handle = registry[id], key = id }` (borrowed). Which strip
   a page is in becomes state (page id -> zone). Moving a page is then a state change, and
   the reconciler moves the borrowed handle with `iup.Reparent` (implemented: a Native placed
   elsewhere in the same commit is never detached; `spec/lui_interop_spec.lua`). Tab titles
   and images must move to a `titles`/`images` prop on `Tabs` (`TABTITLEn` on the strip),
   since the reconciler never writes a Native's attributes. **Tab groups (the group strips
   and their reorder logic), split dragging (`SplitMotion`), the `MotionDirector`, the video
   host and the code editor stay imperative behind component boundaries**: components render
   the strips and hold refs; pointer-driven drags, snapshots and native child windows are
   services they call.
9. `CodeView`, `CodeBinder`, `CodeWorkbench`, `CodePopup`: Scintilla stays a
   `ui.host("scintilla")` with refs for the message API; only the surrounding chrome moves.
10. `VideoHost`, `BackgroundWindow`, `Fullscreen`, `MonitorFit`, `WindowChrome`: native
    windows and OS state; imperative services that components call through refs.

**Stays imperative (services, not views):** `ThemeReactor` (the framework's theme source),
`ThemeTransition`, `ModalMotion`, `Scrim`, `ProgressMotion`, `AnimatedIcon`, `VectorIcon`,
`Kit` (until the `icon` prop), `PosterCache`, `UpdateCheck`.

**`main.lua`** is assembly: it builds the dialog, the content box, the workspace, the
strips and panes, wires callbacks and handles resize. In order: (1) the bottom half (status
bar done, then terminal dock and content box) as one `Shell` component mounted into the
dialog, with `fit`/`setReveal` replaced by a `window` store the resize callback writes
inside `ui.flushSync`; (2) the title bar and rail; (3) the workspace once wave 3 lands. The
dialog itself, the main loop, the tray, `HostAPI` wiring and the shortcut table stay
imperative.

**The proof list, beyond identical pixels.** Each wave is done when, besides the probe and
pixel comparison:

1. **A tab page moved between strips keeps its identity and state**: the same handle
   (checked by identity), its native windows alive (the video host keeps playing into the
   same HWND, a Scintilla document keeps its text, undo history and caret), its extension
   state untouched, and no `Detach` of it in the trace (`LUNAR_PROBE_TRACE`).
2. **Extension reload during async work**: an extension whose page has an effect waiting on
   a coroutine (an HTTP request, a process) is reloaded mid-wait; the old page's effects are
   cleaned up, its resumed coroutine sees `scope.alive() == false` and touches nothing, its
   setters are no-ops, no error is reported, and the new page renders once with fresh state.
3. **A theme change during an animation**: switching theme while the status fade, a modal
   entrance, a tab transition and a toast are running ends with every widget in the new
   theme's resting colours (no animation writes an old theme's colour after the pass, no
   component-owned colour is restored to an earlier theme's), and the animations finish or
   are cancelled cleanly.

## A deprecation timeline for `iup.*`

Stages, each gated on the one before rather than on a date:

1. **Available (now).** `core.lui` ships in the exe; `iup.*` is fully supported everywhere.
2. **New core UI uses components.** Code added under `src/lua/core/ui` and in `main.lua`
   builds UI with `core.lui`; raw `iup.*` constructors there need a comment saying why (a
   native window, a class with no primitive yet). A spec greps new files for raw
   constructors outside an allowlist.
3. **Shell migrated.** Waves 1-3 above. Core code then uses `iup.*` only inside primitives,
   drivers, and the documented imperative services.
4. **Extension API published.** `ctx.ui` (this module) is part of the host API with this
   guide and examples; `addTab`, `addSettings`, `addStatusElement` and the dialogs accept
   elements and components as well as handles; `exampleplugins` are rewritten with it; the
   org packs and Lunar Media start migrating. `iup.*` keeps working unchanged.
5. **Warnings.** Direct `ctx.iup`/global `iup` use from an extension logs a one-time
   deprecation warning per extension and API name, and the extension manager shows it; a
   manifest field (`"ui": "lui"`) declares an extension migrated and turns the warnings into
   errors for it.
6. **Opt-in only.** `iup.*` for extensions needs a manifest capability (`"legacy_iup"`);
   new extensions cannot request it.
7. **Removal.** `ctx.iup` is removed; the iup driver is replaced by a direct driver over the
   emulator's elements (see the driver contract), and `iup` becomes internal to the host.

