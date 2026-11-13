# ImGui performance implementation

Implemented on `t3/imgui-immediate-mode-port-1`. The extension-facing Lua/IUP API
is unchanged. Source implementation: `9a025d9`; the result archive records the
measured builds and org-pack revision. No org-pack source changes were needed
for this performance pass.

## What changed

Layout now caches intrinsic natural sizes and placement, invalidating affected
ancestors and inherited descendants rather than recomputing every clean subtree.
The cache preserves the parent's NORMALIZESIZE behavior without poisoning a
child's intrinsic size. Reparenting, fonts, backend replacement and DPI changes
invalidate the relevant dependencies. Repeated plain stored values can suppress
work; command/custom setters still execute because repeated input can have side
effects. Explicit refresh and first-show two-pass layout remain compatible.

Text measurement uses a bounded O(1) LRU: 256 entries and a 256 KiB text-byte
budget, plus bounded entry overhead. Keys include measurement constraints, fonts,
backend and DPI generations. The implementation retains the existing GDI metrics
and glyph rendering.

`lunar_layout.cpp` supplies allocation-free hbox/vbox natural-size and placement
arithmetic through a versioned C ABI. Lua owns reusable typed child buffers and
all callbacks; C++ borrows pointers only during the call. There is no duplicate
native string tree or persistent element handle. The adapter synchronizes changed
fields, checks ABI/struct sizes, and falls back to Lua if exports are unavailable.
Custom containers remain in Lua.

The isolated 1,000-label synthetic workload did **not** demonstrate a material
standalone FFI win. Marshalling tiny boxes costs more than their LuaJIT loops.
Automatic mode therefore uses native batches for boxes with 16 or more children,
with smaller boxes staying in LuaJIT. See `layout-kernel-bench.json` in the archive.
The full application gains come primarily from avoiding repeated layout/metric
work and hardware rendering. A complete native widget rewrite is not justified
by these results.

The D3D11 backend now tries hardware first and falls back to WARP. Diagnostics
report the requested backend, actual adapter, fallback reason and reset counts.
Recovery rebuilds both Win32 and DX11 ImGui backend state, font resources, CPU-backed
textures and popup swap chains. Failed popup swap chains are demoted to logical
panels. Old-device draw lists are discarded and a fresh frame is scheduled.
Development-only fault injection covers device creation and pipeline setup failures.

The shared networking path resolves host names in at most four native workers.
Workers never access Lua state. Cooperative polling keeps UI timers moving, and
one monotonic caller deadline covers DNS, capacity queueing and connection attempts.
Alternative addresses share the remaining budget rather than allowing the first
dead address to consume it all. CLI and both GUI hosts preload the resolver.

Cancellation releases Lua ownership and discards results; it does **not** cancel
an OS `getaddrinfo` already in progress. Such workers may outlive the caller's
deadline and occupy the bounded pool until the OS finishes. A saturated pool
queues cooperatively and reports a distinct capacity timeout. This is not an
unbounded-thread workaround or a claim of hard OS DNS cancellation.

## Measurements

All-packs medians, milliseconds per operation (lower is better):

| Metric | Previous ImGui/WARP | Improved WARP, staged | Final ImGui/GPU | Matched final IUP |
|---|---:|---:|---:|---:|
| Layout + redraw CPU | 14.12 | 3.94 | 0.93 | 0.81 |
| Page activation CPU | 14.76 | 5.90 | 1.91 | 2.43 |
| Uncapped redraw wall time | 4.24 | 4.03 | 1.44 | 5.31 |

Final normal-settings launch-to-ready medians are 295 ms for ImGui core and
281 ms for IUP core; with all packs they are 532 ms and 835 ms respectively.
Previous ImGui all-packs readiness was 3,216 ms. Shared DNS changes also benefit
IUP, so this startup improvement is not solely an ImGui engine result.

Final all-packs private memory is 105.2 MiB for GPU ImGui and 44.3 MiB for IUP.
The staged WARP path uses 71.3 MiB versus the previous WARP baseline's 81.7 MiB.
These results bring measured layout CPU close to IUP while page activation is
faster in this matrix; they do not establish a universal ordering across workloads.

See [before/after results](benchmarks/2026-11-13-performance/before-after.md),
[four-case matrix](benchmarks/2026-11-13-performance/results.md), and
[raw archive](benchmarks/2026-11-13-performance/summary.json).

The matrix runs IUP and ImGui both extensionless and with all org packs, using
three fresh processes per configuration with alternating order. All-packs means
the same ten extensions and nine pages in both hosts. Project/media development
extensions are outside this org-pack workload. Core runs disable every extension
and org-profile selection. Pack revision is `6e17cc4`.

Startup and memory use normal VSync settings. CPU comparisons use separate
uncapped runs to separate useful work from the 16.7 ms display wait. The baseline
is archived under `2026-11-12`; the WARP-only after suite isolates engine changes
from GPU offload. Raw per-page samples, p95 wall timings and process CPU are
retained. Windows process counters have finite resolution, so zero readings mean
below resolution. CPU totals exclude GPU execution and child processes.

The WARP suite is a staged measurement from before the final adaptive native
threshold; the final GPU/default suites use the committed implementation. The
settled-idle suite is one 10-second sample per case after eight seconds settling,
not a distribution of repeated long idle samples. Source/binary provenance and
stage notes are in the archive's `provenance.json`.

GPU rendering increases private memory. Compare both the WARP and GPU memory
figures against IUP before treating lower application CPU as a universal resource
win. Driver allocations are part of the process footprint; GPU memory/energy were
not separately measured.

## Validation and remaining qualification

- Full host suite: **2,102 successes, zero failures/errors, two environment skips**
  (OpenSSL executable missing from PATH and unavailable symlink privileges).
- HPE pack: **113 passing**; Microchip pack: **87 passing**.
- Native differential tests cover 160 randomized constrained layout trees, forced
  native/reference paths, cache reuse, normalization, reparenting, repeated command
  setters, font/DPI changes and inherited dependencies.
- Nine org/settings page probes show **zero rectangle differences** against the
  previous ImGui build and no added/removed elements. Nine dynamic status color
  differences remain. IUP has existing root-dialog accounting/inherited-attribute
  differences; this is not a claim of pixel identity with IUP.
- Actual renderer integration checks pass hardware, WARP, hardware-to-WARP reset,
  texture preservation, popup restoration and injected device/pipeline failures.
  The inspected hardware-to-WARP capture differs by only 40 color channels, at
  most one level each, across a 624×361 image.
- Actual native worker and CLI checks cover successful localhost DNS/TCP,
  cancellation/closed-handle safety, bounded capacity release, scheduler progress,
  deadline cleanup and absence of UI loading in headless mode.
- Posted-message mechanics pass bar/terminal toggles and theme round trips on
  both backends. The drag script does not reorder tabs on either backend, so it
  does **not** validate tab dragging.
- Both Windows builds pass. Focused changed-module lint passes; Runtime retains
  four pre-existing warnings. Real RDP reconnects, physical GPU removal, native
  video recovery and POSIX builds remain untested in this pass. The tested local
  adapter is an NVIDIA GeForce RTX 3070 Ti. Fault injection is not a replacement
  for those session/device tests.

## Controls and reproduction

- `LUNAR_RENDERER=auto` (default): hardware first, WARP fallback.
- `LUNAR_RENDERER=warp`: explicit software renderer for diagnostics/session issues.
- `LUNAR_RENDERER=hardware`: explicit hardware selection; diagnostics still report
  any failure rather than silently claiming hardware readiness.
- `LUNAR_LAYOUT=auto` (default): adaptive common-box batches.
- `LUNAR_LAYOUT=lua`: layout rollback/reference path.
- `LUNAR_LAYOUT=native`: force all covered boxes through FFI for QA.

```powershell
scripts/benchmark-ui.ps1 -Runs 3 -Renderer auto -OutputDir build/bench-default
scripts/benchmark-ui.ps1 -Runs 3 -Renderer auto -Uncapped -OutputDir build/bench-gpu
scripts/benchmark-ui.ps1 -Runs 3 -Renderer warp -Uncapped -OutputDir build/bench-warp
scripts/benchmark-ui.ps1 -Runs 1 -Renderer auto -IdleOnly -IdleMs 10000 -WarmupMs 8000 -OutputDir build/bench-idle
```

Do not run concurrent benchmarks or tests while collecting performance results.
The harness isolates settings and runs on a private desktop. Select a fresh
output directory for every suite. Test scripts `imgui_renderer_check.lua`,
`imgui_renderer_failure_check.lua` and `resolver_check.lua` are intended for the
built host VM, including its native preloads.

## Auto-agent routing research

The requested Auto delegates were used for bounded implementation and independent
review; their output was checked and corrected before integration. No reliable
prompt technique was found that guarantees Auto chooses its smartest model.
The [community announcement](https://www.reddit.com/r/GithubCopilot/comments/1wp1ygm/tiers_of_auto_now_available/)
describes an Intelligence tier, while
[GitHub's documentation](https://docs.github.com/en/copilot/concepts/models/auto-model-selection)
describes automatic selection. The available delegate connector exposes `auto`
without that tier control. Task scoping, evidence requirements and independent
review were used to improve output quality rather than assuming a routing trick.
