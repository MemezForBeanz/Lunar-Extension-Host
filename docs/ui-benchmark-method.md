# Comparing the IUP and ImGui hosts

`scripts/benchmark-ui.ps1` runs four fresh-process configurations: IUP and ImGui,
each with all HPE/Microchip packs or with zero extensions. Both binaries must be
built from the same checkout, with the same compiler and build type:

```powershell
$env:PATH = 'C:\msys64\mingw64\bin;' + $env:PATH
cmake -S . -B build/iup-bench -G 'MinGW Makefiles' -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLUNAR_UI=IUP -DLUNAR_DEV_BUILD=ON
cmake --build build/iup-bench -j 8
# The existing build/win is the equivalent RelWithDebInfo ImGui configuration.
cmake --build build/win -j 8
scripts/benchmark-ui.ps1 -Runs 5 -OutputDir build/ui-benchmark-default
scripts/benchmark-ui.ps1 -Runs 3 -Uncapped -OutputDir build/ui-benchmark-uncapped
scripts/benchmark-ui.ps1 -Runs 1 -Uncapped -Profile -OutputDir build/ui-benchmark-profile
scripts/benchmark-ui.ps1 -Runs 1 -IdleOnly -WarmupMs 8000 -IdleMs 10000 -OutputDir build/ui-benchmark-idle
scripts/benchmark-ui.ps1 -Runs 1 -Uncapped -Profile -SkipNetworkProbes -OutputDir build/ui-benchmark-no-probes
python scripts/summarize_ui_benchmark.py build/ui-benchmark-default --uncapped build/ui-benchmark-uncapped --out build/ui-benchmark-summary
```

The harness runs sequentially on a private Windows desktop, with a fresh APPDATA
directory for every process, Lunar Dark, a verified 1400x900 client, and dismissed
welcome screens. It alternates backend and configuration order between repeats.
Processes exit after collecting their measurements. It does not empty the OS file
cache: startup results represent warm filesystem launches, not cold boot launches.
Other programs on the machine are not suspended.

The all-packs case selects both profiles and loads eight org extensions plus the
two built-in LSP extensions. The project/media extensions are not org packs and
are not enabled. The core-only case overrides extension discovery to return no
entries and org-profile resolution to return neutral. It still builds the real
host Settings tab and its ordinary no-extension placeholder.

Metrics:

- **Startup:** QueryPerformanceCounter timestamp immediately before CreateProcess
  through the harness's first explicit full paint after main.lua has called
  `_markShown`, completed setup, and reached MainLoop. This includes native host
  startup, Lua/module loading, extension registration, show, and normalization of
  client size. It is instrumented launch-to-readiness, not first-visible-pixel or
  scanout latency: Show may paint before onReady work completes. `_markShown` time
  is recorded separately.
- **Extension load:** wall and app-process CPU time around the real
  `ExtensionManager:loadAll`; individual `register` callbacks are also timed.
- **Idle:** elapsed time and process CPU delta after a settling period in the real
  event loop. Always normalize by the recorded duration, not the requested timer
  interval. CPU sums kernel and user time across all app threads. It excludes
  child processes and GPU time. Windows process CPU counters are quantized, so
  short zero readings mean below the counter's resolution, not literally no work.
  The repeated main runs have approximately two-second windows after two seconds
  settling. The independent settled-idle diagnostic uses ten seconds after eight
  seconds settling. Both store the actual measured elapsed time.
- **Memory:** working set and private commit from GetProcessMemoryInfo, plus Lua
  heap and peak working set. Values are MiB. Private commit excludes GPU memory.
- **Redraw:** 40 samples per page of `iup.Redraw(dialog, 1); iup.Flush()`.
  The call invalidates the whole subtree. The backends perform their natural
  native-GDI or ImGui rendering work; this is not an identical draw-call benchmark.
- **Layout + redraw:** 15 samples per page of `iup.Refresh(dialog)` followed by
  the same redraw. Page means are equally weighted when producing a run mean.
- **Page switch:** ten cycles through every extension tab and Settings using the
  real host activation path plus Flush. No synthetic tabs are added to the
  extensionless case; its page-switch measurement is N/A.

Startup and idle preserve the normal motion setting. Repaint/layout/page-switch
microbenchmarks disable motion identically on both backends so they measure the
completed state change rather than an arbitrary animation frame.

ImGui uses its current WARP software renderer and GDI glyph loader. The primary
run preserves its default VSync. A separate uncapped pass sets LUNAR_VSYNC=0;
wall time in the primary pass therefore includes presentation waits. CPU time is
shown separately and must not be inferred from the VSync-limited wall time.

The measurements do not cover populated remote datasets, real server jobs,
editing large files, video playback, animation smoothness, or GPU rendering.
Hidden-desktop rendering is useful for reproducibility but does not reproduce
foreground compositor latency. Treat small differences between runs as noise.

`-SkipNetworkProbes` is a diagnostic-only harness override of `async.probeTcp`;
it returns unreachable immediately. Those results must never be pooled with the
normal startup samples. No product code or org-pack code is patched by this test.
`-OrgPacksDir` selects a different checkout of the same packs when reproducing.
