# ImGui performance implementation plan

## Delivered implementation, 2026-11-13

The first native migration stage is implemented. See
[implementation results](imgui-performance-results.md) for measurements, exact
coverage and remaining qualification. The sequence below records the original
plan; it is not a claim that every proposed follow-up has shipped.

- Completed: incremental natural-size/placement caching, conservative command
  setter handling, reparent/font/DPI invalidation, bounded O(1) text-metric LRU,
  counters and randomized native-versus-Lua box-layout tests.
- Completed: allocation-free C++ hbox/vbox arithmetic through a versioned FFI ABI.
  Lua owns reusable typed buffers; native code borrows them only for the call.
  There are no persistent native element handles or duplicate string tree. This
  simpler ownership scheme replaces the arena/NodeId sketch below.
- Measured adjustment: automatic mode uses native arithmetic for boxes with at
  least 16 children, retaining LuaJIT for smaller loops. The all-native option is
  available for differential QA. Tabs, splitters and scroll hosts keep their
  compatible Lua implementations; they benefit from the shared caches.
- Completed: hardware-first D3D11, WARP fallback, actual-adapter diagnostics,
  recovery of textures and popup swap chains, failed-popup panel fallback, and
  device/pipeline failure injection tests. Real RDP reconnects and physical
  adapter removal remain qualification work.
- Completed: shared native DNS workers (four maximum), cooperative result polling,
  monotonic end-to-end caller deadlines and teardown. OS getaddrinfo cannot be
  cancelled by this implementation: cancellation discards its result, and worker
  capacity is retained until the OS call finishes. Saturation queues until a
  distinct capacity deadline rather than reporting an offline server.
- Deferred after measurement: native packed painting, whole-tree native ownership,
  transaction APIs and a universal resolved-style cache. The measured GPU path
  already meets the initial CPU targets; the synthetic kernel test does not show
  a material standalone FFI speedup. More native migration needs new profiles.
- Validation completed: full host and org-pack suites, nine-page geometry probes,
  theme/bar mechanics, actual worker/headless checks, and hardware/WARP recovery.
  Exhaustive populated interactive workloads, actual RDP sessions, native video
  recovery and POSIX builds are not claimed by this delivery.

## Decisions

Confirmed by the user:

- Build a native C++ layout kernel behind the existing Lua/IUP-compatible API.
- Prefer hardware rendering automatically after parity and remote-session testing,
  with WARP fallback and an explicit renderer override.
- Include both ImGui engine performance and the shared startup/network delay.

Preserve extension source compatibility, IUP layout and callback semantics, the
patched theme appearance, headless behavior, and resource teardown. Do not require
extension authors to use a new immediate-mode API. Memory optimization is a
guardrail throughout, not a separate rewrite in this pass.

## Why this architecture

The native drawing backend already uses LuaJIT FFI for primitives and measurement.
Adding more individual FFI wrappers will not remove repeated natural-size passes,
attribute inheritance lookups, or dialog-wide invalidation. The implementation
must reduce unnecessary work and move substantial remaining work across the
boundary in batches.

Keep the extension API, callback ownership and general widget behavior in Lua.
Use native typed state and C++ algorithms for layout. Add packed native drawing
submission only after measuring the remaining Lua-to-native overhead. Avoid a
second full string-based attribute tree in C++.

## Sequence and deliverables

### 1. Make performance and correctness observable

- Extend the existing four-case benchmark with nodes measured/placed, invalidation
  reasons, text-measure calls, cache hit rates, FFI submissions, Lua allocation/GC,
  and frame CPU components. Gate comparisons on completed equivalent work.
- Add deterministic populated-page, splitter-drag, scrolling, DPI/theme-change,
  and background-timer workloads alongside the current unloaded pages.
- Separate forced full Refresh, normal page activation, placement-only resize,
  and paint-only changes. Keep VSync wall waits separate from CPU work.
- Preserve the existing Lua layout path as the correctness oracle. Compare
  rectangles, sizes, clipping, attributes and callback traces against the native
  path and the actual IUP build. Add p95 measurements with longer CPU sampling.

Deliverable: repeatable baseline, counters, and a differential layout harness.

### 2. Correct and narrow invalidation before offloading it

- Classify changes as paint, natural-size, placement, inherited style, or structure.
  Replace the single dialog-wide layout-dirty response with dependency-aware dirty
  roots, while keeping a conservative full-dialog fallback.
- Suppress redundant invalidation for proven unchanged stored attributes, outside
  painting as well as inside it. Do not globally skip setters: APPEND, INSERT,
  REDRAW, non-storing setters and other commands can have effects on repeated input.
- Coalesce internal theme, status, tab-scope and timer updates into transactions.
  Existing extension code continues to work without explicit transactions.
- Cache natural sizes and propagate changes upward only as far as dependencies
  require. Reuse placement when the allocated rectangle and relevant state match.
- Keep explicit IupRefresh behavior synchronous. Geometry getters must flush
  pending relevant work before returning.
- Do not equate hidden with irrelevant: tab/zbox natural sizes can depend on
  inactive pages. Cache their contribution and invalidate it correctly.

Deliverable: fewer redundant passes and background frames, with unchanged API
semantics. This dependency model is shared with the subsequent native engine.

### 3. Cache resolved style and text metrics

- Resolve hot layout/style attributes into typed cached fields instead of repeatedly
  parsing sizes, flags, colors and inherited string attributes in every traversal.
- Add a bounded text-metric cache keyed by text, face/style, pixel size, DPI,
  wrapping constraint, font-registration generation and relevant measurement mode.
- Invalidate inherited dependencies on theme/font/DPI/reparent changes. Preserve
  GDI metrics and glyph appearance; do not change the font renderer for speed.
- Bound caches by bytes and release per-element/native resources on destruction.

Deliverable: reduced attribute and text-measure work, without unbounded retained
memory or stale measurements.

### 4. Introduce the native layout kernel through a narrow FFI ABI

- Represent hot layout fields, child relationships, cached natural sizes, allocated
  geometry and dirty generations in typed native arrays/arenas. Use generation-
  checked IDs so destroyed/reused elements cannot be addressed by stale handles.
- Transfer construction and attribute/structure mutations incrementally. Do not
  serialize the entire tree into native structs every frame. Keep general Lua
  attributes/callbacks in the compatibility layer and avoid duplicate string stores.
- Port the existing patched IUP sizing rules: bottom-up natural sizes, top-down
  allocation/positioning, EXPAND/SHRINK, min/max, min-content shrink distribution,
  floating elements, tabs, scroll hosts and split panes. Keep platform dependencies
  out of this kernel and retain appropriate source attribution.
- Start with the common box/leaf layout path, then tabs/splits/scroll hosts. Use
  the Lua reference engine for unsupported cases until their native path passes
  differential tests. Never accept silently different geometry for speed.
- Compute and return batches without calling Lua from inside FFI. Lua-dependent
  work must occur in explicit preparation/fallback phases. Dispatch resize and
  other callbacks after native calls return, in the original order.
- Keep message-pumping/frame-boundary functions on the Lua C API: Win32 window
  callbacks can re-enter Lua, so these functions must not be moved blindly to FFI.
- Evaluate a cdata/typed-Lua prototype only as a comparison; the chosen production
  direction remains the native kernel if it passes the benefit/parity gates.

Illustrative ABI, to be finalized by the prototype:

```c
int lunar_layout_apply(Context*, const Mutation*, size_t count);
int lunar_layout_compute(Context*, NodeId root, Rect bounds, unsigned flags);
const Geometry* lunar_layout_geometry(Context*, size_t* count);
int lunar_layout_events(Context*, Event* output, size_t capacity);
```

Deliverable: native engine selected for covered layouts, Lua reference selectable
for diagnostics, and differential tests covering real org-pack pages.

### 5. Reduce remaining painting/submission overhead

- Measure draw-call crossings and replay allocation after layout improvements.
  Current replay builds temporary Lua argument tables and polygon arrays.
- If material, encode cached commands in reusable typed buffers and submit/replay
  them in native batches. Preserve draw order, clipping, layers, surfaces, text,
  alpha and texture lifetime. Pin or copy command data for its actual lifetime.
- Reuse clean subtree recordings where correct. Distinguish cached CPU geometry
  from dirty-region rasterization: changing one widget can still require submitting
  the full scene. Partial framebuffer rendering is a separate, measured decision.
- Keep interactive state and Lua drawing callbacks compatible. Do not initially
  rewrite all widgets in C++ or replace them with stock ImGui widgets.

Deliverable: less replay garbage and boundary overhead, justified by profiling.

### 6. Prefer hardware rendering with a complete fallback lifecycle

- Benchmark existing hardware rendering against WARP with identical scenes and
  fonts before changing the default. Preserve VSync and event-driven idle behavior.
- Add automatic hardware-first selection, WARP fallback, an override, and a visible
  diagnostic reporting the actual selected adapter/backend and fallback reason.
- Handle device loss/recreation without losing the UI tree, extension state or
  texture/font resources. Verify secondary windows and native video surfaces too.
- Test local sessions, Remote Desktop, reconnects, adapter changes, DPI changes,
  and unsupported-device paths. Promote the default only after the matrix passes.
- Report app CPU, GPU activity/memory and total private memory separately. Moving
  work to the GPU is not the same as eliminating it.

Deliverable: automatic renderer selection with reproducible hardware/WARP results.

### 7. Remove blocking network discovery from startup readiness

- Trace DNS resolution, TCP connection and any filesystem probes separately.
  Nonblocking socket mode does not by itself make name resolution asynchronous.
- Ensure onReady discovery schedules work and returns promptly. Run blocking
  resolution/OS share probing through a bounded worker/broker; never access Lua
  state or UI handles from a worker.
- Return results through the main-loop queue. Keep the existing cooperative socket
  scheduler for the work it can already perform without blocking.
- Apply end-to-end deadlines, cancellation, teardown ownership, deduplication and
  bounded reachability caching. Preserve checking/error/authentication states;
  do not report a server unreachable merely because work was deferred.
- Test unavailable DNS, dead hosts, denied shares, successful discovery, cancellation
  and extension unload while requests are pending. Verify UI input/timers continue
  throughout the deliberately stalled resolver test.

This work can proceed alongside native layout because it addresses the shared
startup delay and is not dependent on renderer changes.

Deliverable: startup readiness independent of network timeouts in both hosts.

## Performance targets and acceptance gates

These are initial engineering targets for the existing i9-12900K benchmark machine,
not promised results or universal hardware thresholds:

| Workload | Current ImGui | Initial target |
|---|---:|---:|
| All-packs full layout + redraw CPU/op | 14.24 ms | <= 5 ms |
| All-packs page activation CPU/op | 16.15 ms | <= 4 ms |
| All-packs simple redraw CPU/op | 2.95 ms | <= 2.5 ms |
| Settled all-packs idle, one-core CPU | about 1.09% | <= 0.5% over longer repeated windows |
| Startup under deliberately stalled discovery | network-dependent | no timeout added to UI readiness |

Use uncapped median and p95 timings plus process CPU, and compare hardware and
WARP independently. Keep IUP in the matrix. Do not confuse the normal 16.7 ms
VSync wait with a failed CPU target. Target a path toward IUP's CPU cost; do not
claim equality until the measured operations and populated workloads support it.

For every stage: run relevant regression tests, extension and org-pack tests,
geometry/callback differential tests, visual checks in both themes and multiple
DPI settings, and the benchmark matrix. Include repeated create/unload cycles,
cache pressure, failure paths and device recreation. Reject unexplained memory
growth or behavior changes even when aggregate speed improves. Keep a fast rollback
switch during native-engine rollout, and remove temporary dual-state overhead
once validation is complete.

## Work division

Use Auto subagents for independent reviews and bounded implementation tasks:

- Invalidation/cache correctness and dependency tests.
- Native layout implementation and differential testing.
- Hardware/WARP lifecycle and session tests.
- Async DNS/discovery and cancellation tests.

Give each agent explicit file ownership or an isolated checkout. Integrate and
benchmark one change group at a time; never run competing performance tests at
once. Record before/after results and explain regressions before advancing stages.

The first implementation milestone is instrumentation plus correct narrow
invalidation and metric caching. The native-kernel prototype follows immediately
on that foundation; this plan does not defer native work indefinitely in favor
of a Lua-only optimization pass.
