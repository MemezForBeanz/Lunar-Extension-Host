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
| 8 | maximised (1920x1080) | Build Queue group strip and every page's empty-state card | strip 1872x988 vs 1872x950; cards 19 px higher | `iFlatTabsSetChildrenCurrentSizeMethod` sets a page's current size directly, without `iupBaseSetCurrentSize`'s MAXSIZE crop (Lunar caps pages with MAXSIZE = work height - 130) | flattabs pages get the client rect through `L.set`; IupTabs keeps `iupBaseSetCurrentSize` | `imgui_parity_spec` "flattabs pages" |
| 9 | 700x500; split right with divider 350; light theme 1100x700 | Settings panel; Settings' horizontal bar | panel 588 vs 603 wide (and 603 vs 618); horizontal bar 49,837 465x15 shown vs hidden | `iFlatScrollBoxSetChildrenCurrentSizeMethod` (child keeps natural size where larger, loses the other bar's width where it expands; `UpdateVisibleScrollArea`); `iupFlatScrollBarGet` reads FLATSCROLLBAR (default YES), SCROLLBAR is read-only NO | `widgets/scrollbox.lua` current-size pass ported; `flatscrollbar.sync` follows FLATSCROLLBAR only | `imgui_parity_spec` "flat scroll box" |
| 10 | 700x500 | Build Queue work pane and output sash; Log Parser results card | pane 410 vs 368 (sash 64,559 vs 64,517); card 250 vs 113 | `iZboxComputeNaturalSizeMethod` with CHILDSIZEALL, registered "Yes" | read through getAttribute with IUP's boolean rule | `imgui_parity_spec` "zbox" |
| 11 | command palette (tour) | placeholder label | 18,14 vs 23,19 | `iBaseSetPositionAttrib`: POSITION is in the native parent's coordinates; boxes are IUP_TYPEVOID | `Layout.placeFloating` measures from the nearest non-void ancestor | `imgui_parity_spec` "floating POSITION" |
| 12 | tour: every sized secondary dialog | dialog content (Feedback, Run Delta Explorer, New Tab Group, Open Lunar Address, token and password dialogs) | e.g. Feedback draft 600x346 vs 616x384 | the dialog's RASTERSIZE/SIZE is the window; `iDialogSetChildrenCurrentSizeMethod` subtracts `iupDialogGetDecorSize` (`iupdrvDialogGetDecoration`: caption 23, sizing border 8, fixed 3) | `dialog.decorSize`; panels lay out the client, centre the window (`iDialogAdjustPos`), and draw the caption band by the same rule | `imgui_parity_spec` "secondary dialog frame" |
| 13 | all (getters) | IupGetClassType; native parent lookups | boxes "container" vs "void"; split missing from flatdraw's void list | nativetype (`IupGetClassType`, `iupChildTreeGetNativeParent`) | `type` set from each C class; flatdraw and winframe ask `class.type == "void"` | `imgui_parity_spec` "class types" |
| 14 | all | boolean attributes | ON/1 ignored by nine widgets, TRUE accepted by flatdraw | `iupStrBoolean` | `Element.isTrue` used everywhere | `imgui_parity_spec` "booleans" |

## App issue found and fixed

- `core.classes.ThemeManager:_widgetKey` stamped `THEMEMGR_ID`, an unregistered attribute,
  and read it back with `IupGetAttribute`, which inherits it. Every widget below a stamped
  one shared its originals store, so a restore wrote another widget's captured values
  (`FOCUSFEEDBACK`, `ARROWCOLOR`, `FONT`, colours) onto it. It affected both builds, and what
  each ended up with depended on the order the theme passes ran in: fix 1 surfaced it, and
  after fix 1 the host's Time Clock dropdown arrows took a dark `ARROWCOLOR` from another
  widget. The id is now `_IUPLUNAR_THEMEMGR_ID`; an `_IUP` name never inherits, on IUP or on
  the host. With it, captures of both builds running this checkout's Lua differ by 0.3-0.5%
  of pixels on the empty tool pages (0.5-1.0% before).

## Result of the state matrix

After the fixes, every state in the list above shows no element rectangle differing by more
than 2 px between the builds on all nine pages (`ui_probe_diff` tolerance 2), apart from the
noise noted under "How it is measured". The default state with the click pass shows no click
difference either (the host also clicks the void splits and one segmented control, which IUP
gives no rectangle; nothing fires on them).

## Secondary panels (`scripts/ui_tour.lua`)

The tour now dumps the IUP build's dialogs too (it records the dialogs the app shows; IUP's
`IupGetAllDialogs` lists only named ones). After fixes 11 and 12, what remains:

- **Command palette** (every page's menu, and the command palette's commands): IUP's search
  row is 8 px taller (separator at 51 vs 43, rows 264 vs 272 tall) and its EDIT sits at y 21
  against 13. Not resolved: the IUP capture of the first opening shows the field at 17 px
  (the 10 pt font before the palette's 11 pt theme rule reached that window), so the
  separate window is themed and laid out at a different time than the in-window panel;
  without the resolved attributes of that window (the tour records rectangles only) I could
  not establish the rule.
- **Org pack token and password dialogs**: IUP's buttons are 44x23 / 33x23 (no PADDING, no
  theme) where the host's are themed (58x27, 61x36); the rows below follow. Same cause as
  above (the IUP capture is of an unthemed separate window); not a layout rule.
- **Welcome tour**: title 471x17 vs 477x28, body 102 vs 119 tall: the same theme timing (the
  IUP title is at body size).
- **Feedback, Run Delta Explorer**: content now matches; Feedback's buttons differ by theme
  (118x35 vs 130x36).
- **New Tab Group, Open Lunar Address, folder dialog**: field rows 26/34 vs 23 px and EDITs
  20 vs 17 px tall, i.e. a larger font in IUP's separate windows (IUP has no DLGFONT, so it is
  not that global); the folder dialog's toolbar buttons are 38x32 vs 48x32 and its split
  starts at 283 vs 232. Not established.
- The 8 px frame band and lighter glyph weight of IUP's popup windows remain the accepted
  difference.

## Open

- The command palette, the folder dialog, and the theming and fonts of IUP's separate
  windows above (a probe of those windows' resolved attributes, like ui_probe's A lines,
  would settle it).
- Settings sub-pages beyond the first: the probe walks tab strips only.
- A dialog's RASTERSIZE getter: IUP answers the window size (1400x900), the host the client
  (1384x892); both report the same CLIENTSIZE. Left as is (no app code reads it).

## Functional parity sweep (branch `t3/imgui-functional-parity-sweep`)

Functional gaps of the main interface against the IUP build, closed in this order: scroll
bars, secondary dialogs, Settings sub-pages, then the shell's behaviour under real input.
Each entry gives the state, what IUP does, what the host did, the C rule, the fix and the
spec. New probe: `scripts/ui_scroll.lua <out dir>` (no shell: a dialog with three scroll
boxes, a multiline and a list) records each build's scroll attributes and, on IUP, the
native bar geometry Windows reports (`GetScrollBarInfo`), after wheel, arrow, track, thumb
and content-drag input sent as window messages.

### Scroll bars

| # | element | IUP vs host before | rule | fix | spec |
|---|---|---|---|---|---|
| S1 | every IupFlatScrollBox (Settings, page scroll hosts) | bars above the content vs painted under it, and clicks on them went to the content | `iupFlatScrollBarCreate`: the bars are canvases with `ZORDER=TOP`. Commit fefe0ca folded `visibleChildren` (and `defaults`) into a comment, so the internal bars, inserted first, painted and hit-tested below the child | restored `visibleChildren = FlatScrollbar.visible_children` and the defaults | `imgui_scrollbars_spec` "paints and hits the bars above the content" |
| S2 | IupScrollBox (the media server page; `scripts/ui_scroll.lua` boxes A-E) | 17 px Windows bars with wheel, arrows, track, thumb and content drag vs no bars and 24 px wheel steps | `iup_scrollbox.c` over `iupwin_canvas.c`: SCROLLBAR (default YES) decides the bars, XAUTOHIDE/YAUTOHIDE show one while DX/DY < XMAX/YMAX, the bars are non-client (the child is clipped to and hit in the client rect), a line is a tenth of the page (LINEX/LINEY from the hash table), the wheel sends one SB_LINEUP/DOWN per whole notch and is consumed whenever there is a vertical bar, `SCROLL_CB` is `iScrollBoxScroll_CB` (LAYOUTDRAG) unless the application sets one, POSX/POSY setters move only the thumb, button 1 on the box drags the content | `widgets/winscrollbar.lua` (geometry as GetScrollBarInfo reports it: arrows 17 or half the bar, thumb MulDiv(track, page, range) at least 8, MulDiv position; tracking with auto-repeat) and a native `scrollbox` class; `class.clipRect` in Runtime | `imgui_scrollbars_spec` "IupScrollBox" (8 cases) |
| S3 | every dialog's first frame | a scroll box at its own size vs at its child's natural size until the next layout | `iupDialogShowXY`, then the new window's WM_SIZE -> `winDialogResize` -> `IupRefresh`: the first layout is computed twice, and `iScrollBoxComputeNaturalSizeMethod` uses the child's size only while the box has none | `layout_dialog` runs `Layout.run` twice the first time | `imgui_scrollbars_spec` "lays a new dialog out twice" |
| S4 | native bars | look | captured: track #F0F0F0, white line on the content side, 2 px #858585 thumb on columns 8-9 with #989898 ends, an 8 px thumb painted 17 px long, no arrows at rest | `winscrollbar.draw` | `imgui_scrollbars_spec` "Windows 11 look" |
| S5 | IupCanvas without WHEEL_CB (inside a scroll box) | wheel scrolls the box vs swallowed by the canvas | `winCanvasMsgProc` WM_MOUSEWHEEL: WHEEL_CB, else a vertical bar scrolls, else DefWindowProc forwards to the parent | canvas `event` returns false then | `imgui_scrollbars_spec` "the wheel over a canvas" |
| S6 | multiline APPEND/INSERT (Build Queue output log: READONLY, APPEND per line) | text appended on a new line vs nothing appended to a READONLY control, no line break, ACTION/VALUECHANGED_CB fired | `winTextSetAppendAttrib`/`SetInsertAttrib`: EM_REPLACESEL ignores ES_READONLY, "
" first when the multiline has text and APPENDNEWLINE (default YES), callbacks disabled, caret after the text | APPEND/INSERT write the text directly | `imgui_multiline_spec` "APPEND and INSERT" |

Result (`ui_scroll.lua`, both builds at the same 884x481 client): every DX/DY/XMAX/YMAX, box,
child and bar rectangle and thumb position matches after wheel, arrow, track, SCROLLTO,
POSY, content drag and resize; the bars' pixels match exactly (0 of 16,000 px differ above
24, box D's painted thumb included after S4). Left: POSX/POSY differ in the 8th decimal
(IUP quantises to INT_MAX scroll units), and box E (30 px tall: no track) where Windows
reports an 8 px thumb it does not paint and the host reports none. Not measurable through
posted messages: the system bar's hover look (it widens under the real pointer; the host's
hover look is an approximation), its auto-repeat timing (Wine's 200/50 ms used), and thumb
dragging (the system's tracking loop ignores posted moves; the host's follows Windows'
MulDiv rule, covered by the spec). The bars are the system's light ones in the dark theme
too, as on the IUP build.
