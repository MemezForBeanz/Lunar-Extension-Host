# IUP / ImGui parity audit — 2026-11-13

The current ImGui implementation is not a complete IUP replacement. This audit
checks the current source, including the recent group, pop-out, motion and menu
changes, rather than treating the older parity checklists as a completion claim.
No product code was changed for this audit.

## Confirmed remaining implementation gaps

| Area | Current difference | Practical impact | Evidence |
|---|---|---|---|
| Popups outside secondary windows | Resolved on Windows: bounded interactive overlays and tooltips promote to owned, nonactivating native surfaces when they leave the owner client. The monitor work area constrains placement. | Embedded backends without `overlay_windows`, or `LUNAR_OVERLAY_WINDOWS=0`, retain surface clipping. SDL popup windows are implemented but unverified on Linux. | `OverlayWindows.lua`, `Runtime.lua`, `spec/imgui_overlay_windows_spec.lua`, `scripts/ui_popupwindows.lua`. |
| Native video z-order | Resolved for bounded menus, dropdowns and tooltips: intersection with a visible video rectangle on the same surface promotes the overlay above the native child. | Full-surface compositor effects and modal scrims remain in-surface. | `Runtime.lua` video rectangles; `lunarimgui.cpp` layered popup windows; private-desktop probe checks native z-order. |
| Scintilla compatibility | Reference-counted plain Lua documents share text, indexed lines, undo/save points, styling/lexer state, markers, indicators and annotations. Views retain independent selection, scroll, wrap, margins and zoom. WORD/CHAR/WHITESPACE wrap renders display rows with matching navigation, hit testing and coordinate messages; layout is cached and calculated on demand. | Still a subset: wrap visual flag glyphs are not drawn (start flags reserve indentation); folding and full native lexer/encoding/renderer options are not implemented. Exact totals or distant display mappings can synchronously wrap the intervening document. Unknown messages still return zero. | `native/sci.lua`, `widgets/scintilla.lua`, `scintilla/{document,view,wrap}.lua`; headless document/wrap specs, including 50,000 lines. The runtime probe below records the earlier baseline. |
| Native text Unicode positions | Resolved for `text` and `multiline`: the value stays UTF-8 internally, and COUNT, CARET, CARETPOS, SELECTION, SELECTIONPOS, SCROLLTOPOS, DELETERANGE, NC, `CARET_CB(lin, col, pos)`, `iup.ConvertXYToPos` and `iup.TextConvert{LinColToPos,PosToLinCol}` count UTF-16 code units as the Win32 EDIT does (a line break is one unit). A position between the halves of a surrogate pair reads as the pair's start; invalid UTF-8 counts one unit per bad byte. Movement, Backspace/Delete and hit-testing step whole code points. Scintilla stays byte-based on purpose. Still open: no formatting-tag emulation, so none of its positions; SCROLLTO's column is ignored; NC does not add IUP's extra byte-length check on the ACTION path. | None for ASCII, which is unchanged. | `widgets/text.lua`, `utf16.lua`, `spec/imgui_text_utf16_spec.lua`. The `one_unicode_character_text_count` probe below predates the change and now reads 1. |
| ImGui Linux GUI | The ImGui executable is selected only inside the Windows build branch and uses Win32/D3D11. The Linux GUI branch builds the IUP host. | The ImGui GUI currently cannot replace the Linux IUP build. | `CMakeLists.txt` Windows ImGui target and separate Linux IUP target. |

## Runtime probes

Executed `build/parity-audit.lua` with the vendored LuaJIT and Null backend:

```text
shared_document_b_text=second
shared_document_pointer_equal=false
one_unicode_character_text_count=2
wrap_flag_stored=1
```

The second editor retained its own document after SCI_SETDOCPOINTER. A single
BMP character (`é`) produced ordinary-text COUNT=2. The wrap setting is accepted;
source inspection confirms that the renderer still draws physical lines without
consuming that setting.

Accessibility, IME composition, multi-monitor DPI, long-duration GPU recovery and
large-document editing have not been exhaustively qualified by this audit. They
are verification risks, not additional claimed failures. IUP's custom widgets
also need accessibility qualification; native hosting alone is not proof.

## Benchmark decision and recommendation

The user's request made a fresh all-org-pack benchmark conditional on finding no
remaining implementation gaps. That condition is not met, so no new benchmark was
run. The existing November 13 performance archive predates recent changes and
must not be presented as a measurement of the current tree.

For production compatibility today, retain IUP as the reference/fallback. For
future Windows development, prefer ImGui: its owned rendering supports the live
tab rearrangement, motion and visual customization now implemented without
requiring additional IUP fork patches. Do not retire IUP until the remaining
functional gaps and qualification risks have been addressed.
