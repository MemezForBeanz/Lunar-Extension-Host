# ImGui host: layout audit against the IUP build

Running record of the layout-parity pass on branch `t3/imgui-layout-parity-groom`: what
was measured, what differed, the IUP rule behind each difference, and what is still open.
Updated as the work goes.

## How it is measured

`scripts/ui_probe.lua` runs on both exes (the IUP build from `main` and this checkout's
ImGui build), each on a private desktop through `D:\lunar-council\tools\hidden.ps1` with
`LUNAR_CAPTURE_CLIENT=1`, and both load this checkout's Lua. The probe now takes the state
to measure from the environment:

| variable | meaning |
|---|---|
| `LUNAR_PROBE_SIZE` | `WxH` (default 1400x900) or `max` |
| `LUNAR_PROBE_SETUP` | `rail`, `bars`, `terminal`, `split=<zone>`, `divider=<n>`, `focus` (comma list, in order) |
| `LUNAR_PROBE_NOCLICK=1` | rectangles only |
| `LUNAR_PROBE_PAGES` | Lua pattern on page titles |
| `LUNAR_PROBE_ATTRS` | extra attributes for the `A` lines (`NTHEME:FOCUSFEEDBACK` reads through a handle) |
| `LUNAR_PROBE_TRACE` | log every write of one attribute, with a traceback, to `trace.txt` |

`scripts/ui_probe_diff.lua iup.tsv imgui.tsv 2` lists rectangles that differ by more than
2 px. The theme is chosen through the seeded `settings.json`.

States run (1400x900 unless given): 900x600, 1100x700, 1920x1040, 700x500 (the minimum),
maximised, tool rail toggled, terminal open, bars hidden, split right, split bottom, split
right with the divider at 350, a focused pane, focus restored, `lunar_light`, and
`lunar_light` at 1100x700 with the rail and terminal toggled.

Always-present noise, not layout: the dialog's own rectangle (IUP reports the window
size for a dialog's RASTERSIZE, the host the client size; both clients are equal, see the
`D` lines), and the status bar's backend/update labels, which depend on network timing
(`src/lua/core/ui/StatusBar.lua` is out of scope for this pass).

## Found and fixed

| # | state | element | IUP vs ImGui before | IUP rule | fix | spec |
|---|---|---|---|---|---|---|
| 1 | every state | every flat button and dropbutton on the HPE pages; the rows below them | e.g. Browse... 87x36 vs 83x32, dropbutton 320x31 vs 320x27; frames below 4 px higher | `iDialogAfterShow` calls `IupFlush` before `SHOW_CB`, so the theme manager's startup re-theme timer runs inside `IupShow`. The host never flushed, the timer ran after the full theme pass, and the theme manager's shared originals store (see "app issues") captured `FOCUSFEEDBACK=NO` and wrote it on every button, removing `iupFlatDrawGetIconSize`'s 4 px focus room | `Runtime.show`/`hide` flush unless `NOFLUSH`, then `SHOW_CB`, then the start focus only if `SHOW_CB` left it alone | `imgui_parity_spec` "IupShow" |
| 2 | Time Clock | "Weekdays only" flattoggle | 114x23 vs 105x17 | `iFlatToggleComputeNaturalSizeMethod`: focus room +4, border on both sides, `CHECKSPACING` default 5, `CHECKSIZE` default 16 | `widgets/flattoggle.lua` ported from `iup_flattoggle.c` (size, draw, events, VALUE, radio, SWITCH); FLAT_ACTION now gets 1/0/-1 as IUP passes (the Black Duck review toggle compares `state == 1`) | `imgui_parity_spec` "flattoggle natural size", `imgui_flattoggle_spec` 3-state cycle |
| 3 | split right, divider 350 | left pane; iLO toolbar fields and Connect | pane 466 vs 465; Connect x 394 vs 391 | `iSplitGetWidth1`: `iupRoundUp(total*val/1000.0)`; children sized by `iupBaseSetCurrentSize`; VALUE starts at -1 | `widgets/split.lua` ported from `iup_split.c` (natural size, VALUE=-1, content crop of patch 0008, current size and MINMAX fixes, bar position, drag, setters) | `imgui_parity_spec` "split", `imgui_split_spec` |
| 4 | split states | Build Queue output sash | 64,837 1304x7 visible vs hidden | `iAttribNotifyChildren`: an inheritable attribute set on a page calls each descendant's class setter; the fork's `iSplitSetVisibleAttrib` clears the bar's own VISIBLE | `Element.setAttribute` notifies descendants without their own value through their class setters (only for names some class has a setter for) | `imgui_parity_spec` "inheritable attributes" |
| 5 | Settings and pages with a flat scroll box | internal scroll bars | class `canvas` vs `flatscrollbar` | `iupFlatScrollBarCreate` makes them with `IupCanvas` | `iupname = "canvas"` | `imgui_parity_spec` "flat scroll bars" |
| 6 | terminal open | terminal header, code view below | header 28 vs 32 tall; code view 51,628 1320x183 vs 51,632 1320x179 | `iHboxSetRasterSizeAttrib` "can NOT set height", `iVboxSetRasterSizeAttrib` "can NOT set width" | hbox/vbox own SIZE/RASTERSIZE setters; a class setter replaces the base one | `imgui_parity_spec` "box user size" |
| 7 | all | 397 elements' FORECOLOR, and other defaults | `50 150 255` vs nil | `iupClassNew(iupRegisterFindClass("canvas"))` copies the parent's registrations; `IUP_FLAT_*` defaults behind `IUPAF_SAMEASSYSTEM` | `scripts/gen_imgui_attrs.py` follows parent classes and reads the macros from `iup_draw.h`; `attrs.lua` regenerated | covered by the suite |

## App issues found (reported, not changed)

- `core.classes.ThemeManager:_widgetKey` stamps `THEMEMGR_ID`, an unregistered attribute,
  and reads it back with `IupGetAttribute`, which inherits it. Every widget below a stamped
  one shares its originals store, so a restore writes another widget's captured values
  (`FOCUSFEEDBACK`, `FONT`, colours) onto it. It affects both builds; what each ends up with
  depends on the order the theme passes run in, which is how fix 1 surfaced. A fix belongs in
  the theme manager (an `_IUP`-prefixed name never inherits, or `iupAttribGet`-style own
  reads), and changes the IUP build's look too, so it is left for its owner.

## Open

- maximised (43 rectangles), 700x500 (31), and `lunar_light` at 1100x700 with rail and
  terminal (39): not yet analysed after fixes 1-7.
- Secondary panels (activity panel, command palette, menus, message boxes, name and folder
  dialogs) through `scripts/ui_tour.lua`: not yet compared.
- Settings sub-pages beyond the first: the probe walks tab strips only.
