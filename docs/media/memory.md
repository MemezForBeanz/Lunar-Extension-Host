# Playback memory and native tab moves

Task Manager's default Memory column reflects resident memory (normally the active
private working set). It does not measure all private committed allocations. The
host's `BackgroundWindow.hide()` explicitly trims the Windows working set. Pages
return as the visible interface uses them again, so a drop on hide followed by a
rise on show alone does not establish a leak.

Keep private committed bytes, resident bytes, Lua heap size, GDI and USER handles
separate when diagnosing playback. `Process.WorkingSet64` includes shared pages
and is not identical to Task Manager's default Memory column. Allow playback
caches to warm before evaluating sustained growth. A diagnostic full Lua
collection can distinguish collectable objects from retained objects; the host
does not force collections periodically to make its counters look smaller.

## Changes

- `CellGrid.posters` uses weak subscriptions. A shared cache no longer keeps
  discarded grids, callback closures and their library models alive. A live grid
  or drain callback keeps its own subscription alive.
- Seek bars read the current native value before writing, avoiding unnecessary
  redraws while still accepting a value changed by native dragging.
- Player and spotlight tints are recalculated when their inputs change. Playback
  labels, dock icons and background-service status skip unchanged native writes.
- Media's decoded poster cache has a 64 MiB pixel budget and 64 queued jobs.
  Worker results and metadata have additional overhead. Compressed playback
  read-ahead is configured for 64 MiB forward and 8 MiB backward, independently
  of decoder, GPU, audio and other runtime allocations. These are cache budgets,
  not limits on total process memory. Smaller buffers trade retained data for
  possible refetching; decoding quality is unchanged.

## Split crash regression

The recorded 2026-11-07 Windows crash was an access violation reading address
`0x10` in `iupAttribSet`, at Lunar RVA `0x6e1b90`. The return address at RVA
`0x777b05` follows the call from `iupwinWmSetFocus`, which passes the null result
of `IupGetDialog` as the dialog argument. The shipped executable's export table
and instructions establish these two call sites; candidate stack pointers are
not a fully unwound call stack.

During `IupReparent`, a page temporarily has no parent while its old container's
child-removal callback runs. Native focus messages can arrive synchronously in
that interval. Patch `0030-win-reparent-focus.patch` ignores focus notifications
without a dialog, before touching dialog attributes or invoking application
focus callbacks. It leaves the video window and player alive across the move.

Run these harnesses on a private desktop with the normal build and contained
libmpv. They exercise native IUP code beyond the Lua unit-test doubles:

- `scripts/reparent_focus_check.lua`: the pre-fix binary faults with
  `0xc0000005`; the patched binary ignores transient orphan focus and still
  dispatches attached-control focus callbacks.
- `scripts/video_host_check.lua`: plays a generated clip with two successive
  player instances, moves the playing page right, bottom, corner and back to
  main, and checks its window identity, video dimensions, cache setting,
  hide/show, fullscreen and destruction.

Local investigation records, crash-address inspection, two-minute Family Guy
streaming samples, native test logs and installation backups are under
`build/memory-investigation/`. The full UI streaming checks use an isolated
profile and do not save watch progress. These short samples do not establish
that every possible long-session memory leak has been eliminated.
