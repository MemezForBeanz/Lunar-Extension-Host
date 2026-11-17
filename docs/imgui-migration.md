# Migrating Lunar from IUP to Dear ImGui: architecture, adapter and verification

This document answers the R&D specification for moving the Lunar Extension Host off
retained-mode IUP onto an immediate-mode Dear ImGui renderer, section by section, and
records what the `t3/imgui-immediate-mode-migration` branch changed. The runtime itself
is described in [imgui-port.md](imgui-port.md); the per-patch mapping of Lunar's IUP fork
is in [imgui-patch-audit.md](imgui-patch-audit.md); the layout parity record is in
[imgui-layout-audit.md](imgui-layout-audit.md).

**Outcome in one paragraph.** Every line of Lua that builds Lunar's UI, the host's, the
bundled extensions' (LSP, Lunar Media, Media server) and the org packs' (HPE, Microchip),
runs unchanged. The `iup` table is an emulator (`src/lua/core/imgui`, about 16,000 lines)
that keeps IUP's retained tree, attribute rules and layout, and paints it every frame
with Dear ImGui draw lists. IUP's own C is the specification: each flat control is a
function-by-function port of its `iup_flat*.c` source with the fork's patches applied,
so the "Lunar Dark" and "Lunar Light" look comes from the same theme attributes driving
the same drawing rules, not from an ImGui style approximation.

## Constraints and how they are met

| Constraint | How |
|---|---|
| Pixel fidelity | The theme engine (`core.classes.ThemeManager`, `Themes/*_rules.lua`) is unchanged and still writes IUP attributes (`BGCOLOR`, `CORNERRADIUS`, `ITEMRADIUS`, `TABSACTIVELINE`, `BORDERSHEENCOLOR`...). The emulator paints them with ports of `iupFlatDraw*` (`widgets/flatdraw.lua`). Text is measured by GDI exactly as IUP's Windows driver does, and glyphs are rasterized by GDI (`lunarimgui_gdifont.cpp`). |
| Extension architecture | `ctx:addRoute`, `ctx:openDatabase`, services, processes, secrets and HTTP live in `core.classes.HostAPI` / `core.classes.host.*`, which never touched IUP. The widgets extensions pass to the host are `iup` handles, and the emulator's handles behave like iuplua's (attribute access, callbacks as fields, `iup.SetAttribute`, `iup.GetChild`...). Zero changes were needed in `extensions/` or in the org packs. |
| Logic retention | Split panes (`widgets/split.lua`, a port of `iup_split.c` with patch 0008), the tool rail and bar toggles (unchanged host Lua), the code view (Scintilla message emulation, below), the headless service (`Lunar --service`, `LunarCLI --headless`) which loads no UI code at all. |

## Phase 1: retained to immediate

### 1.1 The bridge: a virtual retained tree

Constructors build a tree in Lua; no native window is created per widget.

```
iup.hbox{...}   iup.flatbutton{...}   iup.canvas{...}   iup.zbox{...}
        |                 |                  |               |
        v                 v                  v               v
Element.new(class, init)  -- core/imgui/Element.lua
  STATE[el] = { class, attrs = {}, cbs = {}, children = {}, parent, data = {} }
  for k, v in pairs(init): function -> cbs[NAME], handle -> child, else setAttribute
```

Attribute writes follow IUP's rules: a class setter may consume the value (IUP's
"return 0, do not store"), inheritable names reach descendants (`iAttribNotifyChildren`),
and reads walk getter, own value, ancestors, class default, driver default, the order
`iupAttribGetInherit` uses. Registrations (defaults and inheritance per class) are
generated from IUP's C (`scripts/gen_imgui_attrs.py` -> `attrs.lua`).

Every frame walks the tree. Pseudo-code of the adapter, as `Runtime.frame` runs it:

```lua
function Runtime.frame()
  local input = backend.frame_begin()          -- Win32 messages -> ordered event list
  for each event in input.events do route(event) end   -- 1.2 below
  run_due_timers()                             -- iup.timer, Activity, ProcessJob chunks
  for each shown dialog (bottom to top) do
    if dialog.layout_dirty then
      Layout.run(dialog, client_w, client_h)   -- IUP's two passes:
      --   natural sizes bottom-up  (class.natural = ComputeNaturalSizeMethod)
      --   current sizes top-down   (class.place   = SetChildrenCurrentSize/Position)
    end
    paint(dialog, dc)
  end
  paint overlays (menus, dropdowns, tooltips, compositor layers)
  backend.frame_end()                          -- ImGui draw lists -> Direct3D 11
end

local function paint(el, dc)
  if not visible(el) then return end
  class.draw(el, st, dc, rt)                   -- the C control's redraw callback, ported
  if class.clip then dc:clip_push(rect(el)) end
  for _, child in ipairs(class.visibleChildren and class.visibleChildren(el, st)
                         or st.children) do      -- a zbox yields only its VALUE child
    paint(child, dc)
  end
  if class.clip then dc:clip_pop() end
  if class.drawAfter then class.drawAfter(el, st, dc, rt) end   -- frames, native bars
end
```

The mapping onto ImGui is deliberately at the draw-list level (`ImDrawList::AddRectFilled`,
`AddText`, `AddImage`, clip rects), not at the widget level (`ImGui::Button`,
`ImGui::BeginGroup`, `ImGui::Columns`). IUP's layout rules (EXPAND weights, `NORMALIZESIZE`,
`CHILDSIZEALL`, `SIZE` in character units, the fork's patch 0005/0008 layout fixes) do not
exist in ImGui's layout, and Lunar's look depends on them to the pixel, so the layout is
IUP's (`Layout.lua`, `widgets/boxes.lua`, per-class `natural`/`place`) and ImGui supplies
the window, input, font atlas, textures and draw lists. Frames are demand driven: with no
input, timer or animation the loop blocks in `backend.wait`, so an idle Lunar uses no CPU.

### 1.2 Events: inline results back to Lua callbacks

ImGui reports input per frame; IUP fired callbacks per message. The runtime replays the
frame's events in order and turns each into the callbacks IUP would have fired:

```lua
local function route(ev)
  local target = captured or hit_test(ev.x, ev.y)   -- overlays first, then dialogs
  if target ~= hovered then                         -- ENTERWINDOW_CB / LEAVEWINDOW_CB
    deliver(hovered, "leave"); deliver(target, "enter"); hovered = target
  end
  if ev.type == "press" then
    if focusable(target) then set_focus(target) end -- GETFOCUS_CB / KILLFOCUS_CB / FOCUS_CB
    captured = target
  end
  if ev.type == "key" then
    -- IupKeyCallKeyCb: the named callback (K_UP, K_cS...) or K_ANY, from the focus
    -- up to the dialog, until one returns something other than IUP_CONTINUE
    if key_callbacks(focused, code) == iup.IGNORE then return end
    if not deliver(focused, ev) then dialog_defaults(code) end  -- TAB, DEFAULTENTER, ESC
    return
  end
  deliver(target, ev)                    -- class.event: the C control's BUTTON_CB/MOTION_CB
  if ev.type == "release" then captured = nil end
end

local function deliver(el, ev)           -- one xpcall per widget event
  local ok, consumed = xpcall(class.event, traceback, el, st, ev, rt)
  if not ok then log(consumed) end       -- a failing callback never stops the frame
  if ev.result == iup.CLOSE then exit_loop() end
end
```

A class's `event` is the ported C handler; it calls the application's callbacks with
the arguments IUP passes (`Element.call(el, "FLAT_ACTION", text, pos, state)`), and a
callback returning `iup.CLOSE` ends the current loop level, as in IUP. Modal loops nest:
`iup.Popup` runs frames inside the call until the dialog hides.

Internal callbacks are installed the way the C installs them. The flat list, for
example, puts `iFlatListKUp_CB`, `iFlatListKAny_CB`... into the element's own callback
table at creation, so the propagation above reaches them, and an extension that sets
`list.k_any` replaces the type-ahead exactly as `IupSetCallback` does on IUP.

## Phase 2: the Lunar design system

### 2.1 Style: theme attributes, not an ImGuiStyle

Lunar's palettes are rule tables (`src/lua/core/classes/Themes/lunar_rules.lua`): roles
such as `list_bordered`, `palette_frame`, `primary_btn` map to IUP attributes. The theme
manager applies them to every widget with a `THEMEROLE`, unchanged on both builds. The
emulator then draws those attributes with IUP's drawing rules:

| Lunar look | Attributes | Drawn by |
|---|---|---|
| Rounded cards, rounded list bodies | `CORNERRADIUS`, `BORDERWIDTH`, `BORDERCOLOR`, `BORDERSHEENCOLOR` | `flatdraw.boxAttrib`, `roundBorder`, `cornerSheen` (patches 0001, 0005) |
| Selected list row as a pill with a leading marker | `ITEMRADIUS`, `PSCOLOR`, `ITEMMARKERCOLOR`, `HLCOLORALPHA` | `widgets/flatlist.lua` (patches 0003, 0006) |
| Card-style selected tab with an accent line | `TABSACTIVELINE`, `TABSSELCOLOR`, `TABSPADDING`, `SHOWTABS`, side strips | `widgets/flattabs.lua` (patches 0004, 0021) |
| Switch toggles | `SWITCH`, `CHECKSIZE`, colours | `widgets/flattoggle.lua` (patch 0007) |
| Compact buttons | `PADDING`, focus room, `FOCUSFEEDBACK` | `widgets/flatbutton.lua` |
| Gradients | `GRADIENTCOLOR`, `GRADIENTDIRECTION` | `flatdraw.gradientBox` |
| Light/dark transition | theme switch through `core.lib.Compositor` | recorded draw lists replayed with alpha |

Mapping the palettes to `ImGuiCol_*`/`ImGuiStyleVar_*` would only matter if Lunar drew
stock ImGui widgets; it does not, so `ImGuiStyle` is left at defaults and only extensions
that use the raw ImGui API (`core.imgui.cimgui`) see it.

The compositor: Lunar's motion layer (tab transitions, modal dimming, toasts, tab drags)
captured native window snapshots into layered windows. Here a snapshot is a recorded
list of draw calls (`dc:record()`), replayed on the overlay layer with an offset and an
alpha; the modal scrim is a filled rectangle on that layer. `core.lib.Compositor` keeps
its API and motion tokens, so the same curves drive the same transitions.

### 2.2 Widget reconstruction

- **Dropdowns.** Lunar's own picker is `core.ui.FlatDropdown` (a flat button and a
  keyboard-navigable flat list in a popup), which runs unchanged on the emulated flat
  controls. A native `iup.list` with `DROPDOWN=YES` is drawn as the Win32 combo box it is
  on IUP (`widgets/list.lua`).
- **Tabs.** `iup.flattabs` keeps IUP's model: the strip is drawn by the tabs class and
  the pages are its children, only the `VALUE` child painted (the zbox behaviour), so
  extensions that read `VALUEPOS`, `TABTITLEn`, `TABCHANGEPOS_CB` see what they saw.
- **Scroll bars.** `FLATSCROLLBAR=YES` gives IUP's flat bars as internal children
  (`widgets/flatscrollbar.lua`, overlay or `SHOWFLOATING`); a canvas or list without it
  gets the Win32 bar, drawn and driven as Windows does it (`widgets/winscrollbar.lua`:
  arrows, page repeat, thumb tracking, the drag snap-back zone).

## Phase 3: components and host stability

### 3.1 The code view (Scintilla)

Options weighed:

| | Native Scintilla in an offscreen surface, shown as `ImGui::Image` | `ImGuiColorTextEdit` behind Lunar's API | Scintilla's message set emulated over an ImGui-drawn editor (chosen) |
|---|---|---|---|
| Input, IME, caret, selection | must be forwarded to a hidden HWND; IME composition windows and DPI changes need their own plumbing | native to ImGui | native to the emulator's input routing |
| Latency | one frame behind (render, copy, draw) | none | none |
| Fidelity to the IUP build | exact glyphs, but a second compositor path | different editor model: folding, indicators, margins, annotations and call tips would all need mapping | the messages CodeView sends are answered from one model; geometry follows Scintilla's |
| Cost | a texture per editor, a GPU copy per change | a second third-party model to keep in sync | Lua, ~1,500 lines with the keymap |

The code view keeps its Lua API (`core.ui.CodeView`, `core.lsp`, `CodeBinder`), so LSP
hover, go-to-definition, diagnostics (indicators and margin markers), completions
(autocompletion lists) and call tips do not change: they only speak Scintilla messages
to the view. The inventory of the messages used and their status is in
[imgui-scintilla.md](imgui-scintilla.md); the default Scintilla 3.x keymap is ported
(`spec/imgui_scintilla_editing_spec.lua`).

### 3.2 Extension host compatibility and background work

- **Module isolation and teardown.** Extension loading, sandboxes, capability checks and
  teardown are in `core.classes.ExtensionManager` and `HostAPI`, unchanged; the emulator
  contains callback errors per call (`xpcall` in `Element.call` and `deliver`), so a
  failing extension callback is logged and the frame continues
  (`spec/imgui_background_spec.lua`: a failing timer, callback or Activity listener is
  contained; extension teardown errors are contained).
- **Threads.** Lua runs on one thread, as under IUP. Background work is cooperative:
  `ProcessJob` reads child-process pipes in chunks from `iup.timer` ticks, copas drives
  sockets from a timer, and the HTTP server does the same. The frame loop fires due timers
  between frames, never during paint, so a job step delays at most one frame by its own
  length and never blocks input mid-frame. Native helper threads (the media runtime, the
  process reader) hand results back through the same timers.
- **Activity panel.** `host:activity()` and `startJob` update `core.classes.ActivityStore`;
  the status bar and the Activity window subscribe to it and redraw through `iup.Update`,
  which only requests a frame. Progress changes therefore cost a repaint, not a relayout.
- **Headless.** `Lunar --service` and `LunarCLI --headless` load `core.lib.EventLoop`, not
  the UI (`spec/imgui_background_spec.lua` checks that no `core.imgui` module is loaded).

## Worked example: an extension on the new runtime

The sample `exampleplugins/hello.manifest.json` and `hello.lua` run unchanged; nothing in
a manifest is UI specific:

```json
{ "schema_version": 1, "id": "hello", "name": "Hello Extension", "version": "1.0",
  "capabilities": ["tabs", "menus", "settings"],
  "provides": { "tabs": ["Hello"], "settings": ["Hello Extension"] } }
```

A Lunar Media page uses the fork's raw media widgets, a route and the database; this is
the shape of `extensions/media/init.lua` and `ui/library.lua`:

```lua
function Media:register(ctx)
  local iup = ctx.iup                                -- core.imgui.iup on this build
  self.db = ctx:openDatabase("library")             -- HostAPI: sqlite, no UI involved
  ctx:addRoute("open", function(params) return self:openTitle(params.id) end)
  local grid = Grid.new(iup, { count = 0, role = "flatgrid_plain",   -- iupraw.flatgrid
    value = function(i) return self.items[i] end })                -- provider callback
  local list = iup.flatlist{ FLATSCROLLBAR = "YES", THEMEROLE = "list_plain" }
  list.flat_action = function(_, text, pos, state) if state == 1 then self:filter(pos) end end
  ctx:addTab("Media", iup.hbox{ list, grid }, self, { icon = "grid" })
end
```

What happens on the ImGui host:

1. `ctx:openDatabase` and `ctx:addRoute` are HostAPI calls; identical on both builds.
2. `iupraw.flatgrid` (`native/iupraw.lua`, a port of `iupraw_wrap.c`) creates the
   `flatgrid` class (`widgets/flatgrid.lua`, a port of `iup_flatgrid.c`); provider pixels
   upload through `lunar_ui_texture_bits` and draw rounded.
3. `iup.flatlist` creates the ported list; the theme manager applies `list_plain`
   (`PADDING`, `ITEMRADIUS`, `ITEMMARKERCOLOR`...).
4. `ctx:addTab` appends the hbox to the host's flattabs strip.
5. Each frame: `Layout.run` sizes the list from its items (char height, padding, focus
   room: the same numbers IUP computes, checked by a probe of `LINEY` and `NATURALSIZE`),
   `paint` draws the list's rows and pill, then the grid's posters.
6. A click: the hit test finds the list, its `event` (`iFlatListButton_CB`) selects the
   row and calls `flat_action(self, text, pos, 1)` after `flat_action(..., old, 0)`, then
   `valuechanged_cb`, as IUP does.

## What this branch changed

- **`flatlist` is now a line-by-line port of `iup_flatlist.c`** (with patches 0003, 0005,
  0006). The previous module stored items as element attributes, so `REMOVEITEM=ALL` did
  nothing (the Build Queue showed stale rows after a refill), `IMAGEn`, `ITEMFONTn` and
  `ITEMTIPn` were ignored (no status icons in the queue), rows were 4 px short (no focus
  room) and there was no `WS_BORDER` frame or native scroll bar. Items now live in an
  item array behind the id attributes; `iFlatListUpdateScrollBar`, the redraw, selection
  (single, multiple, shift interval, ctrl toggle), drag and drop and the internal key
  callbacks follow the C. `iup.list` keeps the earlier model (`widgets/listbase.lua`).
  Specs: `imgui_flatlist_port_spec.lua`, `imgui_checklist_spec.lua`.
- **Native text positions in UTF-16 units** (`core.lib.utf16`, `widgets/text.lua`):
  `CARETPOS`, `SELECTIONPOS`, `COUNT`, the column of `CARET`/`SELECTION` and `CARET_CB`
  count as the Win32 EDIT does (surrogate pairs are two), so non-ASCII text agrees with
  IUP (`spec/imgui_text_utf16_spec.lua`). The command palette and the plain code view
  now pass UTF-16 lengths too, which was also wrong on IUP for non-ASCII text.
- **Interaction sweep for every bundled extension and org pack**
  (`spec/support/imgui_extension_harness.lua`): each page is selected and its controls are
  clicked where the runtime's hit test says they are, each click must fire the control's
  callback, text fields are typed into, and the extension's settings must lay out; each
  case asserts a floor of pages, clicks, callbacks and typed fields
  (`imgui_extensions_spec.lua`, `imgui_orgpacks_spec.lua`, with `LUNAR_ORGPACKS_DIR`).
  `Runtime.hitTest(x, y)` answers in dialog coordinates for specs and tools.
- **Bundled fonts.** `main_imgui.c` registers the fonts under `assets/Themes` (IBM Plex)
  with GDI before any UI exists, as `main.c` does for IUP. Without it GDI substituted
  another face, so every IBM Plex label (Lunar Media's sidebar and headings) measured
  3 px short; the Media page probe went from about 60 differing rectangles to 3.
- **Capture of dialog windows.** `scripts/ui_capture.lua` and `ui_tour.lua` read a dialog
  that has its own window from that window's back buffer (`screenshot(..., popup)`); they
  were cropping the main window, so the Activity and palette shots compared the wrong
  pixels.

## Verification

| Check | Result |
|---|---|
| Lunar specs (`scripts/test.ps1`, headless backend, `LUNAR_ORGPACKS_DIR` and `LUNAR_MEDIA_DEMO=1` set) | 2136 passing, 0 failures (3 pending: TLS tooling, native layout DLL) |
| HPE org pack specs (`hpe/scripts/test.ps1`) | 115 passing, including the new `imgui_queuepanel_spec.lua` (the real Build Queue panel on the emulator) |
| Microchip org pack specs | 87 passing |
| Org-pack branch | `imgui-immediate-mode-migration` in `lunar-orgpacks`; no pack code changes needed |
| Page captures, IUP vs ImGui (`scripts/ui_capture.lua` on both exes, same Lua and packs, private desktop) | per-page pixel differences in the table below |
| List metrics probe (`LINEY`, `NATURALSIZE` for four fonts) | identical on both builds |
| Layout probe (`ui_probe.lua`, same Lua on both exes) | Build Queue: 0 differing rectangles; Media: 3 (1-4 px, the inner tab strip's page offset) |
| Click probe on the five Media pages | 0 warnings on either build; the only differences are clicks the IUP probe cannot see (the raw media grid's C callbacks) |

Pixel differences per page (channel difference above 24, 1400x900 for the org packs,
1600x940 for Media, both exes running this branch's Lua and org packs):

| Page | before this branch | now |
|---|---|---|
| Build Queue with data | 4.7 % (stale rows, no status icons) | 1.8 % |
| Other HPE / Microchip tool pages, empty | 0.4-1.6 % | 0.3-1.1 % |
| Same pages with data | 2.2-3.7 % | 2.1-3.3 % (iLO: the IUP capture paints its Scintilla pane blank) |
| Lunar Media library views | 7.0-9.6 % | 3.0-5.1 % |
| Lunar Media now playing | 3.0 % | 1.4 % |
| Media server, Metadata, Sources | 3.3-7.1 % | 2.4-4.5 % |

What remains is mostly glyph rasterization (stroke weight), which the parity goal leaves
as cosmetic.

**How to compare builds fairly.** Give the IUP exe the worktree script by absolute path:
with a relative path it loaded the main checkout's Lua, whose ThemeManager still has the
shared-originals bug (it wrote `FOCUSFEEDBACK=NO` and `PADDING=0x0` onto unrelated
widgets), and the differences looked like emulator faults.

Remaining known differences are listed at the end of [imgui-port.md](imgui-port.md),
plus: the Activity window is 8 px shorter than on IUP, with its content 8 px higher (cause
not yet found; the frame title and the panel's own height correction were ruled out).
