# Tab groups and tab scrolling

The host's tab strip organises extension tabs into **groups**. A group is a tab
whose page is another tab strip, so activating it reveals a second tab bar
directly beneath the first holding that group's members. Because a group's page
is just another strip, groups nest to any depth — a group inside a group is a
strip inside a strip, with no special cases.

```text
[ ◀ ] [ Builds ] [ Diagnostics ] [ Settings ] [ + ] [ ▶ ]
                       └─ [ Logs ] [ Traces ] [ Parsers ] [ + ]
                                                         └─ [ ... ]
```

Implementation lives in `core.classes.TabGroups` (the tree, persistence, and
routing support) and `core.classes.TabOrder` (the pointer gestures).

## For users

| Action | Gesture |
|---|---|
| Switch tab | Click it. A click never rearranges anything — a press only becomes a drag after the pointer travels ~6px |
| Reorder a tab | Drag it onto the **left or right quarter** of another tab |
| Combine two tabs into a new group | Drag one onto the **middle** of the other |
| Add a tab to an existing group | Drag it onto the **middle** of the group's tab |
| Place a tab at a specific spot in a group | Drag onto the group's tab and hold; the group springs open after half a second, then drop into its sub-bar |
| Take a tab back out | Drag it from the sub-bar onto the bar above |
| Create an empty group | The `+` button at the end of any tab bar |
| Rename / ungroup | Right-click the group's tab |

Right-click on any tab also lists every group by full path (`Tools / Parsers`),
which is the keyboard-and-menu route to the same operations.

Because the same drag can either reorder a tab or combine two into a group,
dragging shows which one is about to happen: a thin **caret** slides between tabs
for a reorder, and a **highlight** grows over a tab for a combine. Holding over a
group tab draws the spring-open countdown, so the half-second wait is visible
rather than looking like a stall. See **Motion** for the vocabulary these follow,
and for the setting that turns them off.

The arrangement — order, group membership, group names, and which member of each
group was last open — is saved to `tab_groups` in `settings.json` and restored on
the next launch. An arrangement made before groups existed (the old `tab_order`
setting) is migrated once, by tab title.

## Tab scrolling

`IupFlatTabs` scrolls its own strip: once the tabs no longer fit it draws arrow
buttons at each end of the bar and pages through them. This is native behaviour
and needs no host configuration — it applies to group sub-bars too, since they
are the same control.

One trap: `IupFlatTabs` is a canvas that registers **its own** `BUTTON_CB` in
`iFlatTabsCreateMethod`, and that internal handler is what implements tab
switching, the scroll arrows, `SHOWCLOSE` and `EXTRABUTTONS`. Setting
`button_cb` from Lua replaces it wholesale, and the arrows disappear. `TabOrder`
hooks `FLAT_BUTTON_CB` instead, the callback the control provides for this
purpose: the internal handler invokes it first and continues with its own work
unless the callback returns `IUP_IGNORE`.

**If you add a callback to a flat control, check whether the control already uses
that callback internally, and prefer its `FLAT_*` counterpart.** The same applies
to `FLAT_MOTION_CB`, `FLAT_LEAVEWINDOW_CB`, `FLAT_GETFOCUS_CB` and
`FLAT_KILLFOCUS_CB`.

## Theming

Everything the feature draws is a flat control, so it follows the active theme.
Two parts of that are easy to get wrong:

**The "+ new tab group" button is owner-drawn, not native.** It uses
`IupFlatTabs`' `EXTRABUTTONS`, so it lives inside the themed strip and stays
correctly positioned when tabs overflow. But if its per-button colours are unset,
`iFlatTabsRedraw` falls back to `IUP_FLAT_HIGHCOLOR` / `IUP_FLAT_PRESSCOLOR` —
IUP's own blue defaults — and it looks exactly like an unthemed native control.
`ThemeManager` supplies `EXTRAFORECOLOR<n>`, `EXTRAHIGHCOLOR<n>`,
`EXTRAPRESSCOLOR<n>` and `EXTRABORDERCOLOR<n>` from the `flattabs` rule's `fg`,
`hover`, `selbg` and `border`, for all three slots the control supports. The
misleading part is the symptom: it looks like the wrong *widget*, when it is only
missing *colours*.

**The name/rename prompt is `core.ui.NameDialog`,** built from flat controls
only — `iup.flatbutton` (native buttons paint from the system theme and ignore
`BGCOLOR`), and an `iup.text` with `BORDER="NO"` wrapped in an `iup.flatframe`
that draws the border instead. IUP has no flat text-entry control, so that
wrapping is how the codebase gets a themed input; `core.ui.FolderDialog` does the
same. Note `flat_action` rather than `action`, and `DEFAULTESC` rather than
`DEFAULTENTER` (which targets a native button's `action`).

`spec/theme_flattabs_spec.lua` pins both: that every shipped theme supplies the
strip's hover/pressed colours, and that every role the prompt uses is defined.

## Two rules for tab-strip callbacks

**A press is not a drag.** Distinguish them by *travel*, never by comparing what
sits under the pointer at press and at release. The control's own press handler
switches the active tab first, and switching can move `_IUPFTABS_SCROLLPOS`
(`iFlatTabsScrollToTab`), which shifts every tab along the strip — so the release
hit-tests to a different tab than the press at the very same pixel. Read as a
drop, that silently combined two tabs into a group on an ordinary click.

**Never restructure the widget tree inside a strip callback.** Detaching,
destroying and creating pages tears down and rebuilds native windows while the
strip is still dispatching the mouse event, and IUP's own `iFlatTabsButton_CB`
runs *after* the callback returns, against the children that just moved. That
crashed the process roughly half the time a group was formed. `TabOrder` resolves
the drop in the callback but applies it from a one-shot timer, on the main loop,
once the event has unwound.

## Four IUP traps

**Never compare two IUP handles with `==`.** `iuplua_pushihandle_raw`
(`srclua5/iuplua.c`) calls `lua_newuserdata` on every push, so the binding hands
back a **brand new Lua object each time** a widget crosses the C boundary:
`iup.GetChild(t, 0) == iup.GetChild(t, 0)` is false for one and the same widget.
Attributes and callbacks still resolve to the single underlying widget, so the
breakage is invisible until code asks "is this the same widget?" — at which point
every such test silently answers "no", and guards written to *prevent* something
instead *permit* it. Here that meant a plain click resolved as dropping a tab onto
itself and wrapped it in a new group, and "don't move a group inside itself" never
fired. Use `core.lib.handle`: `handle.same(iup, a, b)` and `handle.id(iup, w)`
(the latter also for table keys).



**Custom attributes are inherited — prefix host attributes with `_IUP`.** For any
attribute a control's class does not register, `iupClassObjectGetAttribute`
reports `inherit = 1` ("default is inheritable") and `IupGetAttribute` walks up
the parent chain until it finds a value. An attribute set on a container is
therefore readable on every widget inside it, at any depth. This shipped twice:
the marker meaning "this page is a group" was read back as true for the extension
pages inside a group and for the widgets inside those, so grouping an extension
turned the extension into a group, and ungrouping walked into the extension's own
layout and lifted its panels out as top-level tabs. Names beginning with `_IUP`
are *internal* (`iupATTRIB_ISINTERNAL`, `iup_attrib.h`): `IupGetAttribute`
short-circuits for them and returns the local value only. That is why IUP's own
private state is named `_IUPFTABS_SCROLLPOS`, and why every attribute this host
invents is named `_IUPLUNAR_*`.

Note that `HOSTTABOWNERID` (pre-dating tab groups) deliberately does not rely on
this: `HostAPI:_tagTreeOwner` stamps it explicitly on every node of a tab's
subtree, and the focus-based fallback in `_activeOwner` depends on descendants
carrying it.



Both of these shipped as bugs. They are recorded here because anything else that
manipulates a flat tab strip will hit them.

**`TABTITLE` belongs to the strip, not the page.** It is stored as a
position-indexed attribute on the strip (`TABTITLE0`, `TABTITLE1`, …).
`iFlatTabsChildAddedMethod` copies it off the child exactly once, when the child
is attached, *and only if that slot has no title yet*; `ChildRemovedMethod`
shuffles the rest down. So setting `TABTITLE` on an already-attached page does
nothing — which is why renaming a group left the old label on screen — and a page
moved into a slot can inherit the previous occupant's title. `TabGroups` never
relies on the one-shot copy: `_syncTitles` rewrites every `TABTITLE<pos>` from the
strip's children after any structural change. The same applies to `TABIMAGE`,
`TABVISIBLE` and `TABACTIVE`.

**Ask IUP what a widget *is*; use attributes only for what it *carries*.**
"Is this page a group?" is answered structurally — `IupGetClassName(w) ==
"flattabs"` — not by a marker attribute. A group page is by construction a
`flattabs`; an extension page never is. Class cannot be inherited from a parent,
lost on a re-attach, or forgotten on a code path, which are three failure modes
that each produced a release-blocking bug here. The attributes now carry only a
group's data (name, origin, last-active member).

**Group state lives on the group's own widget.** Name, origin and last-active
member are attributes on the strip, so there is no registry to key, reseed, or
leak — and nothing that can be shared between two widgets by accident.

Layouts written by the buggy builds are tagged `version = 1` or `2` and are
**discarded** on load rather than migrated, since they may already describe a
corrupt tree. Tabs fall back to load order plus manifest hints.

## For extension authors

Nothing is required. Tabs added with `ctx:addTab` participate automatically.

To ship a default grouping, declare it in the manifest:

```json
{
  "id": "logviewer",
  "name": "Log Viewer",
  "version": "2.1.0",
  "group": "Diagnostics"
}
```

or per tab, which overrides the manifest:

```lua
ctx:addTab("Results", panel, M, { group = "Diagnostics/Logs" })
```

Both are **defaults applied on first sight only**. Once the host has recorded
where a tab lives, the user's arrangement wins and the hint is ignored. A group
created from a hint is removed when it empties (an uninstalled extension leaves
no clutter); a group the user created by hand is kept even when empty.

### Routing still works at any depth

`lunar://plugin/<id>` and `lunar://host/settings` activate a tab wherever it is,
activating each group above it in turn. `HostAPI:currentRoute` likewise resolves
the *innermost* active tab, so menu scoping, status-bar scoping, keyboard
shortcut scoping and address serialization all behave the same inside a group as
outside one. Extensions do not need to know whether they are grouped.

### Tab identity

Group membership is stored against a stable key rather than a tab title, so an
extension that renames its tab keeps its place. The key is
`<manifest id>/<n>`, where `n` is the tab's ordinal within its extension
(`host/<id>` for host-owned tabs such as Settings). Consequently, **the order in
which an extension calls `addTab` is part of its persisted identity** — inserting
a new tab ahead of an existing one shifts the keys and the user's arrangement for
that extension resets. Append new tabs at the end.
