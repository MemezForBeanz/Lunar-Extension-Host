# ImGui port audit against Lunar's IUP fork

Status is for the Lua emulator in this checkout. "Not applicable" means the hunk is
platform-specific or belongs to a file the ImGui port deliberately does not emulate.

| Patch hunk(s) | Lua location | Status | Spec |
|---|---|---|---|
| 0001 `iup_dlglist.c` | No Lua equivalent; dialog lifetime is owned by `Runtime.lua` | not applicable | `imgui_runtime_spec.lua` |
| 0001 `iup_draw.c` declarations and drawing helpers; `iup_draw.h` | `widgets/flatdraw.lua`, `Draw.lua`, `Color.lua` | matched | `imgui_flatbutton_spec.lua`, `imgui_flatframe_spec.lua`, `imgui_flatlabel_spec.lua`, `imgui_flattoggle_spec.lua`, `imgui_dropbutton_spec.lua` |
| 0001 flatbutton/flatlabel/flatframe/dropbutton hunks | `widgets/flatbutton.lua`, `flatlabel.lua`, `flatframe.lua`, `dropbutton.lua` | matched | `imgui_flatbutton_spec.lua`, `imgui_flatlabel_spec.lua`, `imgui_flatframe_spec.lua`, `imgui_dropbutton_spec.lua` |
| 0001 flatscrollbar/flattext/flat scrollbox hunks | `widgets/flatscrollbar.lua`, `scrollbox.lua`, `text.lua` | fixed | `imgui_flatscrollbar_spec.lua`, `imgui_scrollbox_spec.lua`, `imgui_text_spec.lua` |
| 0001 flattoggle/gauge hunks | `widgets/flattoggle.lua`; gauge is not an owned Lua class | matched; gauge not applicable | `imgui_flattoggle_spec.lua` |
| 0001 `win/iupwin_draw_gdi.c`, WDL GDI+ backend | `Draw.lua`, `widgets/flatdraw.lua` | not applicable (backend-specific; Lua uses Null/ImGui draw lists) | `imgui_fidelity_spec.lua` |
| 0001 native text line-count/scrollbar hunks | `widgets/text.lua` | not applicable (native Win32 implementation) | `imgui_text_spec.lua` |
| 0002 GTK menubar | No Lua equivalent | not applicable (GTK-only) | `imgui_menu_spec.lua` |
| 0003 list rounded body/border hunks | `widgets/flatlist.lua`, `widgets/flatdraw.lua` | matched | `imgui_flatlist_spec.lua` |
| 0003 list clear-value focus clamp | `widgets/flatlist.lua` `set_value` | matched | `imgui_flatlist_spec.lua` |
| 0003 list programmatic VALUE focus/scroll | `widgets/flatlist.lua` `set_value`, `scroll_to_focus` | matched | `imgui_flatlist_spec.lua` |
| 0003 list CORNERRADIUS registration | `attrs.lua`, `widgets/flatlist.lua` | matched | `theme_gradient_spec.lua`, `imgui_flatlist_spec.lua` |
| 0004 title measurement/layout | `widgets/flattabs.lua` `metrics`, `natural` | matched | `imgui_flattabs_spec.lua` |
| 0004 SHOWTABS draw/hit-test/resize paths | `widgets/flattabs.lua` `metrics`, `draw`, `hitTab`, `place` | matched | `imgui_flattabs_spec.lua` |
| 0004 SHOWTABS setters and expand-button behavior | `widgets/flattabs.lua` attribute setters/events | matched | `imgui_flattabs_spec.lua` |
| 0005 box GAP/MARGIN inheritance | `widgets/boxes.lua`, `Element.lua` | matched | `imgui_layout_iup_spec.lua` |
| 0005 rounded helpers/inactive blend/corner sheen | `widgets/flatdraw.lua`, `Color.lua` | matched | `imgui_flatbutton_spec.lua`, `imgui_flatframe_spec.lua`, `imgui_flatlabel_spec.lua` |
| 0005 list ITEMRADIUS/marker/alpha overlay/focus | `widgets/flatlist.lua` | fixed | `imgui_flatlist_spec.lua` |
| 0005 scrollbar SB_INSET and rounded/gradient thumb | `widgets/flatscrollbar.lua` | fixed | `imgui_flatscrollbar_spec.lua` |
| 0005 separator STYLE=SASH/HLCOLOR | `widgets/flatseparator.lua` | matched | `imgui_flatseparator_spec.lua`, `imgui_split_spec.lua` |
| 0005 tabs rounded selected card | `widgets/flattabs.lua` | matched | `imgui_flattabs_spec.lua` |
| 0005 toggle CHECKRADIUS and pixel-aligned drawing | `widgets/flattoggle.lua`, `Draw.lua` | matched | `imgui_flattoggle_spec.lua` |
| 0005 split zero-size guard, sash and HLCOLOR | `widgets/split.lua`, `flatseparator.lua` | matched | `imgui_split_spec.lua` |
| 0005 GDI+ rounded primitives and cue-banner text | Native backend / `Runtime.lua` | not applicable; cue-banner behavior remains a native-file issue | `imgui_text_spec.lua` |
| 0006 ITEMMARKERCOLOR | `widgets/flatlist.lua` | fixed | `imgui_flatlist_spec.lua` |
| 0007 SWITCH/SWITCHPOS track and knob | `widgets/flattoggle.lua` | matched | `imgui_flattoggle_spec.lua` |
| 0008 scrollbox FITCONTENT | `widgets/scrollbox.lua` | fixed | `imgui_scrollbox_spec.lua` |
| 0008 separator repaint/hot state | `widgets/flatseparator.lua` | matched | `imgui_flatseparator_spec.lua` |
| 0008 tabs current-child parking/removal | `widgets/flattabs.lua` | matched | `imgui_flattabs_spec.lua` |
| 0008 hbox/vbox proportional shrink | `widgets/boxes.lua`, `Layout.lua` | matched | `imgui_layout_iup_spec.lua` |
| 0008 `iup_layout.c` min-content/layout update | `Layout.lua` | matched | `imgui_layout_iup_spec.lua`, `imgui_layout_spec.lua` |
| 0008 split content minima/orientation | `widgets/split.lua`, `Layout.lua` | matched | `imgui_split_spec.lua` |
| 0008 Win32 reparent/redraw/DIB/font hunks | `Runtime.lua`, `Dialog`/backend-owned code | not applicable; focus guard is a reported remaining difference | `imgui_runtime_spec.lua` |
| 0021 side-strip breadth/title/image/layout hunks | `widgets/flattabs.lua` `metrics`, `tabRect`, `draw` | matched | `imgui_flattabs_spec.lua` |
| 0021 side-strip selected color and active line | `widgets/flattabs.lua` | matched | `imgui_flattabs_spec.lua` |
| 0021 side-strip hit testing/scroll arrows/extras | `widgets/flattabs.lua` | matched | `imgui_flattabs_spec.lua` |
| 0030 `iupwin_focus.c` null-dialog guard | `iup.Reparent` calls `Runtime.reparented`; native focus has no Lua equivalent | not applicable; report only | `imgui_runtime_spec.lua` |

## Remaining differences outside this package

The Win32-only 0001/0005/0008 backend hunks and 0030's `iupwin_focus.c` guard cannot be
implemented in the owned Lua widgets. `Runtime.lua` currently calls `reparented` but does
not preserve an in-flight native focus notification; a native backend would need to ignore
focus delivery while a page has no dialog parent. Native text cue-banner and line-count
behavior likewise remains backend-owned. `dialog.lua` and `raw.lua` contain the corresponding
host/native behavior and were intentionally not edited for this package.
