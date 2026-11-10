# The Dear ImGui host

Lunar's UI used to run on IUP 3.32 with Lunar's patch series (`iup-fork/patches`):
native windows, a retained widget tree in C, and flat controls IUP paints with GDI+.
This branch keeps every line of Lua that builds the UI, the host's and each
extension's, and swaps what is under `iup` for a Dear ImGui renderer.

The plan in one sentence: **the `iup` table stays, and its widgets become a virtual
tree that ImGui draws every frame.**

```
 extension / core UI Lua           unchanged: iup.hbox{...}, function btn:flat_action()
           |
 core.imgui.iup                    the iup API: constructors, functions, K_* codes
           |
 core.imgui.Element                retained tree: attributes, inheritance, callbacks
           |
 core.imgui.Layout                 IUP's layout (natural size, EXPAND, SIZE, patch 0005/0008)
           |
 core.imgui.Runtime   frame loop:  input -> hit test -> callbacks -> layout -> draw
           |                         timers, focus, capture, popups, tooltips, dialogs
 core.imgui.widgets.*              per class: natural size, draw (IUP's flat drawing), events
           |
 core.imgui.Draw (dc)              a draw context: rects, gradients, text, images, clip
           |
 backend: Native                   Lua over lunarimgui (C++): Win32 window, Direct3D 11 (WARP),
                                   ImGui draw lists through LuaJIT FFI, GDI text metrics, textures
          Null (Lua)               the same calls recorded in memory, for the busted suite
 core.imgui.cimgui                 the whole Dear ImGui C API (cimgui) through FFI, for extensions
```

## Why a virtual tree and not ImGui widgets

IUP's flat controls are already custom drawn: `iupFlatButton`, `iupFlatTabs` and the
rest paint rectangles, text and images with `iupdrvDraw*`, and Lunar's look lives in
the attributes the theme rules set on them (`BGCOLOR`, `HLCOLOR`, `PSCOLOR`,
`CORNERRADIUS`, `BORDERSHEENCOLOR`, `ITEMRADIUS`, `TABSACTIVELINE`...). Repainting those
same controls from those same attributes with `ImDrawList` is how the look stays
identical. A port to stock `ImGui::Button`s would have to rebuild the look from
scratch and rewrite every extension.

So ImGui supplies the platform window, input, the font atlas (1.92 dynamic sizes, which
fits IUP's arbitrary `FONT` sizes), texture upload and the draw lists. Lunar supplies
the tree, the layout and the painting rules.

## Retained to immediate: the bridge

### 1. Construction builds a tree, not windows

```lua
-- iup.flatbutton{ TITLE = "Run", THEMEROLE = "primary_btn", flat_action = fn }
function Element.new(class, init)
  el = setmetatable({}, Meta)                -- iuplua-style handle
  STATE[el] = { class, attrs = {}, cbs = {}, children = {}, parent }
  for k, v in pairs(init) do Element.set(el, k, v) end   -- functions -> callbacks
  for i = 1, #init do Element.append(el, init[i]) end    -- handles -> children
  return el
end
```

`el.TITLE = x`, `el.title`, `iup.SetAttribute(el, "TITLE", x)` and the constructor
table all write the same store. A function value is a callback (`ACTION`, `FLAT_ACTION`,
`BUTTON_CB`...), exactly as iuplua binds them.

`iup.GetAttribute` follows IUP: a class getter, the element's own value, the parent
chain for inheritable names, the class default, then the driver default
(`DLGBGCOLOR`, `DLGFGCOLOR`, `DEFAULTFONT`). Names starting `_IUP` never inherit, and
`GAP`/`MARGIN` do not either (patch 0005). Unlike iuplua, `_IUP` names *can* be read
back from Lua, so `core.lib.attr` works through the plain path.

### 2. Every frame walks the tree

```lua
function Runtime.frame()
  local input = backend.frame_begin()
  route_input(input)            -- see "Events" below
  run_due_timers()
  for each shown dialog, bottom to top:
    if dialog.layout_dirty then Layout.run(dialog, w, h) end
    paint(dialog, dc)
  paint overlays (dropdowns, menus, tooltips, transitions)
  backend.frame_end()
end

local function paint(el, dc)
  if not visible(el) then return end
  class.draw(el, st, dc, rt)                 -- background, label, image...
  if class.clip then dc:clip_push(rect(el)) end
  for _, child in ipairs(class.visibleChildren and class.visibleChildren(el, st) or st.children) do
    paint(child, dc)
  end
  if class.clip then dc:clip_pop() end
  if class.drawAfter then class.drawAfter(el, st, dc, rt) end   -- borders, scrollbars
end
```

The frame loop is demand driven: with no input, no due timer and nothing animating,
`backend.wait(t)` blocks until the next OS event or timer, so an idle Lunar uses no CPU.
`iup.Update`/`iup.Redraw` request a frame; `iup.Refresh` and any change to a
size-affecting attribute (`Element.LAYOUT_ATTRS`) mark the dialog's layout dirty.

### 3. Events: inline results back to Lua callbacks

ImGui reports input per frame. The runtime turns that into the callbacks IUP fired:

```lua
function route_input(input)
  local target = capture or hit_test(input.mx, input.my)    -- topmost overlay, then dialogs
  if target ~= hovered then
    fire(hovered, "leave"); call(hovered, "LEAVEWINDOW_CB")
    fire(target, "enter");  call(target, "ENTERWINDOW_CB")
  end
  for each button press:
    if focusable(target) then set_focus(target) end         -- GETFOCUS_CB / KILLFOCUS_CB
    capture = target
    deliver(target, { type = "press", button = b, x, y, lx, ly, status = iup._status(mods) })
  for each release: deliver(capture, { type = "release", ... }); capture = nil
  if moved: deliver(target, { type = "move", ... })
  if wheel: bubble(target, { type = "wheel", dy })          -- up the parent chain until consumed
  for each key: k = iup code with modifier bits
    if call(focus, "K_ANY", k) ~= iup.IGNORE and not deliver(focus, { type = "key", key = k })
      then dialog_defaults(k) end                           -- K_ANY on dialog, TAB, ESC, ENTER
  for each typed char: deliver(focus, { type = "char", char = utf8 })
end
```

A widget's `event` decides what IUP would have done. A flat button, on release inside
after a press inside, calls `Element.call(el, "FLAT_ACTION")`; a callback returning
`iup.CLOSE` ends the current loop level, as in IUP. Callback errors are logged with a
traceback and the frame goes on.

### 4. Loops nest the way IUP's do

`iup.Popup(dlg)` and `iup.Popup(menu, x, y)` block until the dialog hides or the menu
closes, by running frames inside the call. `iup.Message`, `iup.Alarm`, `iup.GetText`
and `iup.GetParam` are themed dialogs built from flat controls and shown with Popup.
`iup.MainLoop` runs until `iup.ExitLoop`, `iup.CLOSE` from a callback, or the last
visible dialog closes.

Dialogs other than the first are drawn inside the main window as floating panels over
a dimmed page (modal ones dim, as Lunar's scrim did). Their `SCREENPOSITION`,
`CENTERPARENT` and `MOUSEPOS` are converted to and from screen coordinates through the
main window's position.

## Contracts

### Class (core.imgui.Classes)

See the header of `src/lua/core/imgui/Classes.lua`. A widget module calls
`Classes.define{ name = ..., natural, place, draw, drawAfter, event, ... }`. The module
named in `Classes.MODULES` loads the first time its class is constructed.

### Layout (core.imgui.Layout)

```
Layout.run(dialog, w, h)      natural sizes bottom-up, then placement top-down
Layout.natural(el) -> w, h    natural size including SIZE/RASTERSIZE/MINSIZE/MAXSIZE
```

The helper `L` passed to `class.natural(el, st, L)` and `class.place(el, st, L)`:

```
L.natural(child) -> w, h        child's full natural size
L.place(child, x, y, w, h)      give a child its rect (dialog client coordinates)
L.expand(child) -> eh, ev       does the child expand horizontally / vertically
L.visible(child) -> bool        VISIBLE ~= NO and not FLOATING=YES
L.font(el) -> Font              core.imgui.Fonts object for the element's FONT
L.charsize(el) -> cw, ch        IUP SIZE units: width = cw/4 per unit, height = ch/8
L.size(str) -> w, h | nil       parse "WxH" (either part may be empty)
```

`st.x, st.y, st.w, st.h` hold the placed rect; `st.nat_w, st.nat_h` the natural size.

### Draw context (core.imgui.Draw)

All coordinates are dialog client pixels, colours are IUP colour strings or packed
`0xAABBGGRR` numbers (`Color.parse`). One `dc` per frame:

```
dc:rect(x, y, w, h, color, { radius, corners, thickness })        outline
dc:fill(x, y, w, h, color, { radius, corners })                   filled
dc:gradient(x, y, w, h, c1, c2, "VERTICAL"|"HORIZONTAL", { radius })
dc:line(x1, y1, x2, y2, color, thickness)
dc:circle(cx, cy, r, color, { filled, thickness })
dc:poly(points, color, { filled, thickness })                      {x1,y1,x2,y2,...}
dc:text(str, x, y, w, h, color, font, { align, valign, ellipsis, wrap, clip })
dc:measure(str, font, wrap_width) -> w, h
dc:image(img, x, y, w, h, { alpha, tint, inactive })               img: an image element
dc:clip_push(x, y, w, h) / dc:clip_pop()
dc:alpha_push(a) / dc:alpha_pop()                                  fades for transitions
dc:layer(name)                                                     "main" | "overlay"
dc:record() / dc:stop() -> list / dc:replay(list, dx, dy, alpha)   snapshots for motion
```

`corners` is a set like `{ tl = true, tr = true }` (nil means all four).

### Events (class.event)

```
ev.type    "press" | "release" | "move" | "wheel" | "key" | "char" | "enter" | "leave"
           | "focus" | "blur" | "dblclick"
ev.x, ev.y     dialog client coordinates      ev.lx, ev.ly   relative to the element
ev.button      1 left | 2 middle | 3 right    ev.status      iup status string
ev.iupbutton   iup.BUTTON1..3 (49..51), what BUTTON_CB receives
ev.double      true on a double-click press (the status string carries 'D' too)
ev.dx, ev.dy   wheel steps                    ev.key         IUP key code (+ modifier bits)
ev.char        a UTF-8 character              ev.mods        { shift, ctrl, alt, sys }
```

Return `true` when consumed. Runtime services a widget may use (`rt`):

```
rt.redraw(el) rt.relayout(el) rt.capture(el) rt.release() rt.setFocus(el) rt.focused()
rt.now() rt.animate()                         -- keep frames coming this frame
rt.overlay{ owner, x, y, w, h, draw = fn(dc), event = fn(ev), closed = fn(), modal }
   -> handle with :close() and :move(x, y, w, h); drawn above dialogs, gets events first,
      and closes on a click outside unless `sticky`
rt.cursor(name)                               -- "ARROW" "HAND" "IBEAM" "SIZEWE" ...
rt.clipboard_get() rt.clipboard_set(s)
```

### Backend (core.imgui.backend.Native over the `lunarimgui` C module)

Two layers. Calls that pump Win32 messages (`open`, `frame_begin`, `window`, dialogs)
stay on the Lua C API, because the window procedure calls back into Lua while the
window is being sized and a function called through LuaJIT's FFI must never re-enter
Lua. Everything a frame does per primitive is an FFI call to an exported C function with
scalar arguments (`lunar_ui_rect_filled`, `lunar_ui_text`, ...), which LuaJIT compiles
into its traces; the frame's input is read straight from a C struct (`LunarUiFrame`).
`lunar_ui_sizeof` lets the Lua side refuse declarations that do not match the exe.

Input is an ordered list of events, each with the pointer position, buttons and
modifiers it happened with. `Runtime` routes them one at a time, so a press and release
in the same frame (a touchpad tap, a quick click), a click followed by the pointer
leaving, or keys typed between clicks reach the widgets in order and at the right place.

Rendering is Direct3D 11 on WARP, the software rasterizer that ships with Windows: the
flat UI costs about 4 ms of CPU per full-window frame and no GPU driver is loaded (the
OpenGL driver alone was ~40 MB of private memory). `LUNAR_RENDERER=hardware` uses the
GPU instead, and `LUNAR_VSYNC=0` presents without waiting (frame timing).

Text is measured the way IUP's Windows driver measures it: a GDI font made with
`CreateFont(-MulDiv(pt, dpi, 72), ..., bold ? FW_BOLD : FW_NORMAL, ...)` from the face
`iupGetFontInfo` parses (so "HPE Graphik Medium, 10" asks GDI for "HPE Graphik", as IUP
did), `GetTextExtentPoint32` per line and `tmHeight` per line. Glyphs come from ImGui's
atlas but are placed at GDI's character positions (`GetTextExtentExPoint`), so drawn text
lands where the measurements put it.

```
open{ title, x, y, w, h, maximized, borderless } -> ok, err
close()  alive() -> bool  now() -> seconds  wait(timeout_s) -> woke
frame_begin() -> input        frame_end()
  input = { w, h, scale, mx, my, inside, down = { b1, b2, b3 },
            pressed = { [1]=n,... }, released = {...}, double = {...},   -- 1 left, 2 middle, 3 right
            wheel_x, wheel_y, keys = { { code, down, shift, ctrl, alt, sys }, ... },
            chars = { "a", ... }, mods = { shift, ctrl, alt, sys },
            focused, resized, close_requested, files = { ... },
            events = { { type = "move"|"press"|"release"|"wheel"|"leave"|"keydown"|"keyup"|"char"|"file"|"tray",
                         x, y, button, double, dx, dy, code, char, file,
                         mods = { shift, ctrl, alt, sys, b1, b2, b3 } }, ... } }
gdi_font(face, bold, italic) -> gid   gdi_metrics(gid, px) -> ascent, descent, height, avg_w
gdi_text_size(gid, px, str, wrap_w) -> w, h   font_private(path)
rect(x1,y1,x2,y2,col,rounding,thickness,corner_flags)
rect_filled(x1,y1,x2,y2,col,rounding,corner_flags)
rect_gradient(x1,y1,x2,y2,col_tl,col_tr,col_br,col_bl)
line(x1,y1,x2,y2,col,thickness)  circle(cx,cy,r,col,thickness_or_0,segments)
poly(points,col,filled,thickness)
text(font,size_px,x,y,col,str,wrap_w,cx1,cy1,cx2,cy2,gid)
text_size(font,size_px,str,wrap_w) -> w,h   font_metrics(font,size_px) -> ascent,descent,line_h,avg_w
font_load(path) -> id      font_find(face, bold, italic) -> path|nil
texture(rgba, w, h) -> id  texture_free(id)  image(tex,x1,y1,x2,y2,u1,v1,u2,v2,tint)
clip_push(x1,y1,x2,y2) clip_pop()  layer(n)
cursor(name)  clipboard_get() clipboard_set(s)  cursor_pos() -> sx, sy
window(op, ...)   ops: title, size, pos, client_origin, maximize, minimize, restore,
                  is_maximized, is_minimized, fullscreen, show, hide, focus, hwnd,
                  caption (drag region + no-drag rects), screen, full, dpi, icon,
                  tray and videohost child-surface lifecycle operations
file_dialog{ type, title, filter, filterinfo, directory, file, multiple } -> path|paths|nil
message_box(title, text, kind)
```

`videohost` is a disabled Win32 child window, repositioned in dialog-client pixels
each frame and hidden when its element or any ancestor is not visible. Because it is
an HWND, native child z-order is above the ImGui draw list: dropdowns, tooltips, and
other ImGui overlays drawn over a video host can be hidden behind the video child.
The host reports that child through `WINDOWID`, `WID`, and `HWND`.

Corner flags follow ImGui's `ImDrawFlags_RoundCorners*` bits (TL=16, TR=32, BL=64,
BR=128; 0 = all).

## Scintilla

The code view keeps its Lua API. `iup.scintilla` is a Lua editor class: a gap-free line
buffer, the styling `CodeView` drives (lexer keywords, styles, indicators for
diagnostics, margins, annotations, call tips, autocompletion lists) and the `sci`
module's `send`/`sends` messages answered from that model. Rendering through ImGui
directly beats an offscreen native Scintilla surface: an `ImGui::Image` of a native
window would need its own input forwarding, IME and DPI handling, and would lag a frame
behind. A dedicated `ImGuiColorTextEdit` would mean mapping a second editor's model onto
Scintilla's message set anyway. LSP hover, definition and completions keep working
because they live in `core.lsp` and `CodeBinder`, which only speak to the view.

## Compositor and motion

Lunar's motion (tab transitions, modal dimming, toasts, tab drags) captured native
window snapshots into layered windows. Here a snapshot is a recorded list of draw
calls (`dc:record`), and the compositor replays it with an offset and alpha on the
overlay layer, so the same `core.lib.Compositor` API and motion tokens drive the same
curves without any native capture.

## Background services and threads

The activity panel, `ProcessJob`, copas and the HTTP server run off the same timers as
before (`iup.timer`), now fired by the frame loop between frames. They never run
inside paint, so a slow job step delays the next frame by its own length and never
blocks input handling mid-frame. `Lunar --service` and the CLI do not load the UI at all.

## An extension on the ImGui host, step by step

`exampleplugins/hello.manifest.json` and `hello.lua` run unchanged. The manifest is
read by `core.lib.ExtensionManifest` exactly as before (nothing in it is UI-specific):

```json
{ "schema_version": 1, "id": "hello", "name": "Hello Extension", "version": "1.0",
  "capabilities": ["tabs", "menus", "settings"],
  "provides": { "tabs": ["Hello"], "settings": ["Hello Extension"] } }
```

What its `register(ctx)` does, and what each line becomes:

```lua
local iup = ctx.iup                      -- core.imgui.iup (the same table as the global iup)
local panel = iup.vbox{                  -- Element.new("vbox"): a table, no window
  iup.fill{},                            -- IupFill: weak vertical expand inside a vbox (W0/H0 bits)
  iup.hbox{ iup.fill{}, iup.label{ TITLE = "Hello from the sample extension!",
            FONT = "Segoe UI, 14", FGCOLOR = "0 120 200" }, iup.fill{} },
  BGCOLOR = "255 255 255",               -- stored on the vbox; inherited by the labels
}
self:addTab("Hello", panel)              -- HostAPI appends it to a flattabs strip; TABTITLE set
self:addMenuItem("Hello Extension...", function()
  iup.Message("Hello Extension", "...")  -- a themed dialog built from flat controls, shown
end)                                     -- with iup.Popup: a nested frame loop until OK
local greeting = iup.text{ BORDER = "NO", VALUE = "Hello", SIZE = "120x" }
local show_tab = iup.flattoggle{ TITLE = "", VALUE = "ON", CHECKSIZE = "14" }
self:addSettings("Hello Extension", { entries = { ... } })   -- host-built settings card
```

Each frame, for the Hello tab:

1. `Layout.run` measures the label with `Fonts.get("Segoe UI, 14")`: 14pt at 96 DPI is an
   18.67px em, so the backend lays the text out at the same width GDI did, and the line
   is tmAscent + tmDescent tall, read from the face's OS/2 table.
2. The fills take the free space (`IUP_EXPAND_W0`/`H0`), centring the label.
3. `paint` draws the `label` class at its rect: the inherited `BGCOLOR` fill, then the
   title with `DrawText` semantics (top-left, no wrap), in `FGCOLOR`.
4. Clicking the toggle: the runtime hit-tests the tree, the `flattoggle` class flips
   `VALUE`, and calls the extension's `flat_action`/`valuechanged_cb` if it set one, with
   the same arguments IUP passes.

The same applies to everything else an extension touches: `ctx:addRoute`,
`ctx:openDatabase`, services, processes, HTTP and secrets live in `core.classes.HostAPI`
and `core.classes.host.*`, which have no UI dependency at all and are untouched by the
port; only the widgets they hand to the shell go through the emulator.

## Building, running and testing

```
cmake --preset dev && cmake --build --preset dev     # build/win/bin/Lunar.exe on ImGui
cmake --preset dev -DLUNAR_UI=IUP                    # the IUP build, still available
powershell -File scripts/test.ps1                    # busted, including spec/imgui_*.lua
Lunar scripts/imgui_smoke.lua out.bmp                # the native backend on its own
Lunar scripts/imgui_shot.lua out.bmp 6000 1400 900   # the whole shell, one shot + tree dump
Lunar scripts/ui_capture.lua <dir> img               # every page, as for the IUP build
```

The headless `Null` backend runs the entire host in the test suite: a spec builds
widgets, queues mouse and keyboard input, runs frames and asserts on the draw calls.

## Where the code is

| Path | What |
|---|---|
| `src/cpp/lunarimgui.cpp` | Win32 window, custom frame, Direct3D 11, input events, FFI exports, GDI text metrics, textures, dialogs, screenshots |
| `src/lua/core/imgui/backend/Native.lua` | the FFI declarations and the per-frame input table |
| `src/lua/core/imgui/cimgui.lua`, `cimgui_cdef.lua` | Dear ImGui's C API for LuaJIT (cdef generated by `scripts/gen_cimgui_cdef.py`) |
| `vendor/imgui`, `vendor/cimgui` | Dear ImGui 1.92.9 (docking) and the cimgui generated for it |
| `src/c/core/main_imgui.c` | the entry point: service mode, preloads, boot of the emulator |
| `src/lua/core/imgui/Element.lua` | the retained tree and IUP's attribute rules |
| `src/lua/core/imgui/attrs.lua` | IUP's attribute registrations (generated by `scripts/gen_imgui_attrs.py`) |
| `src/lua/core/imgui/iup.lua`, `keys.lua` | the `iup` API and key codes |
| `src/lua/core/imgui/Layout.lua`, `widgets/boxes.lua` | IUP's layout with patches 0005 and 0008 |
| `src/lua/core/imgui/Runtime.lua` | frame loop, input routing, focus, timers, popups, tooltips, dialogs |
| `src/lua/core/imgui/Draw.lua`, `Color.lua`, `Fonts.lua` | the draw context and `iup.Draw*` |
| `src/lua/core/imgui/widgets/flatdraw.lua` | IUP's flat drawing (iup_draw.c + the fork's GDI+ paths) |
| `src/lua/core/imgui/widgets/*.lua` | one module per control family |
| `src/lua/core/imgui/native/*.lua` | Lua stand-ins for the IUP-bound C modules (sci, iupraw, compositor, winframe, svgicon...) |
| `src/lua/core/imgui/backend/Null.lua` | the headless backend for tests |

## Fidelity: how it was checked, and what still differs

`scripts/ui_capture.lua` walks every page on both builds (IUP from `main`, ImGui from this
branch) on a private desktop at 1400x900 with the HPE org packs. Layout, colours, rounded
cards, toggles, dropbuttons, tab strips, lists, row markers, split panes, the build log and
the status bar line up page for page; text widths match IUP to the pixel because both
measure with GDI.

`scripts/ui_probe.lua` goes further, on both builds: on every page it records each
element's rectangle and clicks every control that has a click callback through real
window messages, recording which callbacks fire (`scripts/ui_probe_diff.lua` compares the
two runs). With `LUNAR_PROBE_LIVE=1` it runs the real callbacks and reports Lua errors
and the dialogs and popups each click opens.

## Performance

| | IUP | ImGui host |
|---|---|---|
| working set after start | 60 MB | 85 MB |
| private memory | 41 MB | 57 MB |
| CPU while idle (10 s) | 0 ms | ~80 ms |
| full-window frame (WARP / GPU) | n/a | ~4 ms / ~0.6 ms |
| paint of 1,200 elements (Lua) | n/a | ~0.7 ms |

`scripts/imgui_perf.lua` (frame, paint and layout times per page, and a LuaJIT profile),
`scripts/ui_memory.lua` (memory, idle CPU and the largest modules, on either build) and
`scripts/imgui_idle.lua` (what drives frames while nobody touches the window) measure it.
The host draws a frame only when input arrives, a timer or callback changes something,
or an animation runs.

Known differences, in order of visibility:

- **Glyph rasterization.** ImGui's stb_truetype rasterizer draws softer, slightly thinner
  strokes than GDI's hinted ClearType. Metrics and positions are the same; weight is
  not. The fix is a custom `ImFontLoader` that rasterizes glyphs with GDI
  (`GetGlyphOutline`, hinted, grayscale) into the atlas; ImGui 1.92's loader interface
  supports it.
- **The code editor** is an emulation of the Scintilla messages CodeView sends, not
  Scintilla itself: editing, styles and style fonts work, but its geometry messages
  (`POINTXFROMPOSITION` and friends) are approximations.
- **Secondary dialogs** (the activity panel, the command palette, message boxes) are
  drawn inside the main window as panels rather than as separate OS windows. They
  cannot leave the main window's bounds.
- **Video host**: `core.imgui.widgets.raw` reserves the rect and exposes the window's
  HWND; the media player's native child window has to be positioned over it by
  `media_native` (no backend support for child HWNDs yet).
- **Tray icon** (`TRAY*` on the dialog) is not implemented in the backend yet.
- **Compositor scaling**: snapshots replay with offset and alpha; a sprite's scale is
  approximated by its recorded size.
