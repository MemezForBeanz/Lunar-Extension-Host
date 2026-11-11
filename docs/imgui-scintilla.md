# ImGui Scintilla compatibility inventory

The ImGui host implements the Scintilla surface used by Lunar in Lua. Positions are
UTF-8 byte offsets, matching `SCI_SETCodePage(SC_CP_UTF8)` in the IUP build.

| Surface | Items used by Lunar | Status |
|---|---|---|
| Document/position messages | `GETLENGTH`, `GETLINECOUNT`, `POSITIONFROMLINE`, `LINEFROMPOSITION`, `GETLINEENDPOSITION`, `GETCURRENTPOS`, `GETANCHOR`, `GOTOPOS`, `SETSEL`, `GETSELECTIONSTART`, `GETSELECTIONEND`, `GETCHARAT`, `SETTEXT`, `APPENDTEXT`, `SETTARGETSTART`, `SETTARGETEND`, `REPLACETARGET` | Implemented; edits notify `VALUECHANGED_CB` and preserve byte offsets |
| Geometry/scrolling | `POINTXFROMPOSITION`, `POINTYFROMPOSITION`, `POSITIONFROMPOINTCLOSE`, `TEXTHEIGHT`, `TEXTWIDTH`, `LINESONSCREEN`, `GETFIRSTVISIBLELINE`, `SETFIRSTVISIBLELINE`, `VISIBLEFROMDOCLINE`, `ENSUREVISIBLE`, `GETXOFFSET`, `SETXOFFSET`, `GETSCROLLWIDTH`, `SETSCROLLWIDTH` | Implemented with fixed-font metrics, tab stops, margins, clamped viewport |
| Editing/history | `SETREADONLY`, `GETMODIFY`, `SETSAVEPOINT`, `EMPTYUNDOBUFFER`, `CANUNDO`, `UNDO`, `CANREDO`, `REDO`, `WORDSTARTPOSITION`, `WORDENDPOSITION` | Implemented |
| Styling/lexing | `SETLEXER`, `SETLEXERLANGUAGE`, `SETKEYWORDS`, `SETPROPERTY`, `COLOURISE`, `STARTSTYLING`, `SETSTYLING`, `GETSTYLEAT`, `STYLECLEARALL`, `STYLESETFORE/BACK/BOLD/ITALIC/SIZE/FONT` | Implemented for the lexers and manual ranges Lunar uses |
| View configuration | `SETCODEPAGE`, `SETTABWIDTH`, `SETCARETWIDTH`, `SETCARETFORE`, `SETCARETLINEVISIBLE`, `SETCARETLINEBACK`, `SETSELFORE`, `SETSELBACK`, `SETWRAPMODE`, `SETEXTRAASCENT/DESCENT`, `SETHSCROLLBAR`, `SETVSCROLLBAR`, `USEPOPUP`, technology/font-quality messages | Implemented or accepted as no-op configuration |
| Margins/markers | `SETMARGINTYPEN`, `SETMARGINWIDTHN`, `SETMARGINMASKN`, `SETMARGINLEFT/RIGHT`, `MARKERDEFINE`, `MARKERADD`, `MARKERDELETEALL`, marker colours | Implemented for line-number and diagnostic margins |
| Diagnostics indicators | `INDICSETSTYLE`, `INDICSETFORE`, `INDICSETUNDER`, `SETINDICATORCURRENT`, `INDICATORFILLRANGE`, `INDICATORCLEARRANGE` | Implemented; ranges are drawn as underlines |
| Document handles | `GETDOCPOINTER`, `SETDOCPOINTER`, `CREATEDOCUMENT`, `ADDREFDOCUMENT`, `RELEASEDOCUMENT` | Accepted; the current Lua document remains the backing store |
| IUP attributes | `VALUE`, `COUNT`, `CARETPOS`, `CARET`, `SELECTIONSTART`, `SELECTIONEND`, `VISIBLELINES`, `VISIBLECOLUMNS`, `MARGINWIDTH0..4`, `MARGINTYPE0..4`, `MARGINMASK0..4`, `LEXERLANGUAGE`, `KEYWORDS`, `STYLE*`, `INDICATOR*`, `ANNOTATION*`, `AUTOC*`, `CALLTIP*` | Core getters/state are present; message-based paths are authoritative. Dynamic IUP attribute aliases are accepted by the element store and rendered state |
| Callbacks | `ACTION`, `VALUECHANGED_CB`, `UPDATECONTENT_CB`, `CARET_CB`, `DWELL_CB`, `UPDATEVSCROLL_CB`, `UPDATEHSCROLL_CB`, `AUTOCSELECTION_CB`, `HOTSPOTCLICK_CB`, `MARGINCLICK_CB`, `BUTTON_CB`, `MOTION_CB`, `K_ANY` | CodeView callbacks and mouse/key routing implemented. `DWELL_CB` is fired by the host event path; autocomplete/call-tip protocol callbacks remain reserved for extensions |
| Editing keys and mouse | Default Scintilla movement/editing keymap, UTF-8-safe selection, clipboard, undo/redo, mouse selection, wheel scrolling and caret visibility | Implemented in the ImGui widget; callbacks and scroll updates are emitted when state changes |

The IUP build remains the reference for native details (`vendor/iup-src/iup/srcscintilla`);
the Lua implementation intentionally keeps the same message numbers used in
`core.ui.CodeView`.
