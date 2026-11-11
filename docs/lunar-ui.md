# Lunar UI (`core.lui`)

Components and hooks over the `iup` API. The full guide is being written; see the
status section below.

## Status

- Done: elements (`ui.h`, table constructors, Fragment), reconciler (keyed diffing,
  fragments, components returning nil, type change, unmount), hooks, store, scheduler,
  iup driver, typed props, primitives, test helper (`core.lui.test`), `spec/lui_reconciler_spec.lua`.
- In progress: specs for hooks, props, events, interop, error boundaries.
- Not started: StatusBar migration, NameDialog migration, captures, the guide and migration plan.
