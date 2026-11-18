# IUP versus ImGui: November 12, 2026

IUP has the lower memory and CPU footprint. ImGui reaches startup readiness sooner
in these runs, and its measured page-switch wall time is slightly lower. The most
obvious ImGui scaling problem is full layout and page activation with all packs
loaded, rather than extension registration or simple repainting.

Both were built from `fbfb980` in the same worktree using MinGW RelWithDebInfo.
The machine has an i9-12900K (24 logical CPUs), 31.8 GiB RAM, and Windows 11 build
22631. ImGui uses the current default WARP software renderer and GDI glyph loader.
The org-pack checkout is `6e17cc4`. Five fresh processes per configuration were
measured with shipping VSync, then three more per configuration without VSync.

| Median, default settings | IUP core | ImGui core | IUP all packs | ImGui all packs |
|---|---:|---:|---:|---:|
| Launch to ready UI | 278 ms | 214 ms | 3,469 ms | 3,216 ms |
| Extension discovery/load/register | N/A | N/A | 49.7 ms | 61.3 ms |
| Idle private commit | 30.9 MiB | 55.1 MiB | 44.4 MiB | 81.7 MiB |
| Idle working set | 49.6 MiB | 74.7 MiB | 64.7 MiB | 100.7 MiB |
| Full redraw, CPU/op | 2.34 ms | 3.52 ms | 1.13 ms | 2.95 ms |
| Full layout + redraw, CPU/op | 1.04 ms | 4.17 ms | 1.27 ms | 14.24 ms |
| Page switch, wall/op | N/A | N/A | 19.04 ms | 17.69 ms |
| Page switch, CPU/op | N/A | N/A | 1.39 ms | 16.15 ms |

"Ready" means main.lua completed its post-show/onReady work and an explicit paint
was flushed. A window can become visible earlier; this is not first-visible-pixel
or scanout latency. Startup is a warm filesystem measurement, not a cold boot.
The all-packs case has eight org extensions plus two built-in LSP extensions and
nine pages. Core means zero extensions, neutral org configuration, and Settings.

## What costs time

1. **A shared network-dependent startup delay.** Both startup profiles spend most
   samples in `copas.connect` under `async.probeTcp`. Black Duck's onReady source
   discovery probes its configured servers. As a diagnostic only, returning
   unreachable immediately from the probe helper brought readiness to **786 ms
   for IUP and 523 ms for ImGui**. These are single profiled diagnostic runs, not
   replacements for the repeated main results. This strongly implicates the
   TCP/DNS connection path; DNS resolution versus TCP waiting was not separately
   timed. Org-profile resolution itself took about 2 ms in the profiled ImGui run.
2. **ImGui layout grows with the loaded tree.** The all-packs full-layout workload
   consistently used 12.2–14.9 ms CPU/op across the five main runs, versus
   0.8–1.6 ms for IUP. In the uncapped Settings-page profile, the layout wrapper
   measured about **12.8 ms per forced layout**, of about 18.4 ms total wall time.
   Sampled work includes recursive natural-size computation, placement, attribute
   lookup, and text measurement. Page switching also uses much more ImGui CPU
   despite similar/slightly better wall time. Incremental layout and avoiding
   redundant invalidations are the clearest next investigations.
3. **WARP rendering is a substantial part of plain redraws.** In the uncapped
   all-packs Settings-page profile, frame-end rendering/presentation took about
   **2.0 ms of a 4.0 ms redraw**, and direct Lua scene painting averaged 1.6 ms
   in a separate paint-only pass. These diagnostic components are not a perfectly
   additive decomposition. The hardware renderer was not benchmarked.
4. **VSync changes the interpretation.** Default ImGui redraws take about 16.7 ms
   wall time because Present waits for the display interval. With VSync disabled,
   ImGui redraws average **3.52 ms core / 4.24 ms all packs**, versus IUP's
   **7.10 / 5.03 ms**. Full layout plus redraw is **5.79 / 16.43 ms** for ImGui,
   versus **6.65 / 6.72 ms** for IUP. These measure the whole API operation, not
   identical native drawing work; lower wall time does not imply lower CPU cost.

## Is either heavy at rest?

A separate settled-idle check waited eight seconds, then measured ten seconds:

| Configuration | CPU time over 10 seconds | One-core utilization | ImGui frames |
|---|---:|---:|---:|
| IUP core | below counter resolution | below about 0.16% | N/A |
| ImGui core | 15.6 ms | 0.156% | 1 |
| IUP all packs | below counter resolution | below about 0.16% | N/A |
| ImGui all packs | 109.4 ms | 1.093% | 24 |

On this 24-logical-CPU machine, 1.093% of one core is about **0.046% of total CPU**.
Both are light at rest. ImGui carries approximately 24 MiB more private commit in
the core case and 37 MiB more with packs. Its org-pack timers trigger occasional
whole-scene work; the Time Clock's one-second tick writes several UI attributes.
The shorter early-idle windows in the main runs are kept in the raw results and
show more startup activity. The settled check is one longer observation per case,
not five repeats.

These workloads build the real UI with fresh settings and no supplied datasets;
they do not measure active scans, populated server data, large editor files,
media playback, foreground compositor latency, or animation smoothness. Core
CPU/op readings vary noticeably at Windows counter granularity; avoid interpreting
small differences or zero readings as exact. Main startup ranges were 252–285 ms
IUP core, 210–231 ms ImGui core, 3,444–3,492 ms IUP all, and 3,177–3,219 ms ImGui all.

The next useful optimization pass is to trace and reduce repeated full-tree
layout on page activation and background attribute updates, then compare WARP
with hardware rendering. Separately investigate the blocking portion of server
discovery before startup readiness. No application performance changes were made
as part of this benchmark.

See [method and reproduction](ui-benchmark-method.md),
[complete metric tables](benchmarks/2026-11-12/results.md),
[per-run CSV](benchmarks/2026-11-12/runs.csv),
[per-page CSV](benchmarks/2026-11-12/pages.csv), and
[validated summary and ranges](benchmarks/2026-11-12/summary.json).
The adjacent suite directories retain individual raw samples and profiler output.
