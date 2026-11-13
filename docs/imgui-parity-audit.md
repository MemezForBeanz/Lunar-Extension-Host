# IUP / ImGui parity audit — 2026-11-13

The current ImGui implementation is not a complete IUP replacement. This audit
checks the current source, including the recent group, pop-out, motion and menu
changes, rather than treating the older parity checklists as a completion claim.
No product code was changed for this audit.

## Confirmed remaining implementation gaps

| Area | Current difference | Practical impact | Evidence |
|---|---|---|---|
| Popups outside secondary windows | Menus, dropdowns and tooltips are rendered on their owner's window surface. They cannot extend beyond that surface as an independent IUP popup can. | Particularly relevant to small extension pop-out windows and controls near an edge. | `core/imgui/Runtime.lua` overlay surface selection; `widgets/dropbutton.lua` runtime overlays; `docs/imgui-port.md` known differences. |
| Native video z-order | Media playback uses a native child HWND above the ImGui draw list. | A menu, tooltip or dropdown overlapping video can be obscured. | `widgets/videohost.lua`; `docs/imgui-port.md` video-host description. |
| Scintilla compatibility | The Lua editor implements a subset rather than the native engine. Shared document handles do not share text; wrap mode is stored but unused by the line renderer. Unknown messages generally return zero. | Extensions relying on additional native Scintilla capabilities can behave differently even when current CodeView/LSP paths work. | `native/sci.lua`, `widgets/scintilla.lua`; runtime shared-document probe below. |
| Native text Unicode positions | Ordinary text widgets expose UTF-8 byte offsets/counts, rather than Win32 EDIT's UTF-16 units. This is distinct from Scintilla's intentionally byte-based positions. | Non-ASCII extension code using COUNT/CARETPOS/SELECTIONPOS can select or count differently. | `widgets/text.lua`; runtime probe below. |
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
