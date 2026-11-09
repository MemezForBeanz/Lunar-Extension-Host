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
 backend: Native (lunarimgui C++)  Win32 + OpenGL3 + ImGui, ImDrawList, fonts, textures
          Null (Lua)               the same calls recorded in memory, for the busted suite
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

```
open{ title, x, y, w, h, maximized, borderless } -> ok, err
close()  alive() -> bool  now() -> seconds  wait(timeout_s)
frame_begin() -> input        frame_end()
  input = { w, h, scale, mx, my, inside, down = { b1, b2, b3 },
            pressed = { [1]=n,... }, released = {...}, double = {...},   -- 1 left, 2 middle, 3 right
            wheel_x, wheel_y, keys = { { code, down, shift, ctrl, alt, sys }, ... },
            chars = { "a", ... }, mods = { shift, ctrl, alt, sys },
            focused, resized, close_requested, files = { ... } }
rect(x1,y1,x2,y2,col,rounding,thickness,corner_flags)
rect_filled(x1,y1,x2,y2,col,rounding,corner_flags)
rect_gradient(x1,y1,x2,y2,col_tl,col_tr,col_br,col_bl)
line(x1,y1,x2,y2,col,thickness)  circle(cx,cy,r,col,thickness_or_0,segments)
poly(points,col,filled,thickness)
text(font,size_px,x,y,col,str,wrap_w,cx1,cy1,cx2,cy2)
text_size(font,size_px,str,wrap_w) -> w,h   font_metrics(font,size_px) -> ascent,descent,line_h,avg_w
font_load(path) -> id      font_find(face, bold, italic) -> path|nil
texture(rgba, w, h) -> id  texture_free(id)  image(tex,x1,y1,x2,y2,u1,v1,u2,v2,tint)
clip_push(x1,y1,x2,y2) clip_pop()  layer(n)
cursor(name)  clipboard_get() clipboard_set(s)  cursor_pos() -> sx, sy
window(op, ...)   ops: title, size, pos, client_origin, maximize, minimize, restore,
                  is_maximized, is_minimized, fullscreen, show, hide, focus, hwnd,
                  caption (drag region + no-drag rects), screen, full, dpi, icon
file_dialog{ type, title, filter, filterinfo, directory, file, multiple } -> path|paths|nil
message_box(title, text, kind)
```

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
