# IUP and ImGui UI benchmark

Medians of 3 fresh-process runs per configuration. Lower is better. CPU time sums every thread in the app process; it excludes child processes. Idle CPU is a percentage of one logical core, not Task Manager’s whole-machine percentage.

| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |
|---|---:|---:|---:|---:|
| Launch → ready UI (ms) | 280.61 | 294.72 | 834.95 | 532.29 |
| Extension load (ms) | 0.02 | 0.02 | 49.52 | 57.59 |
| Idle private memory (MiB) | 30.93 | 86.32 | 44.31 | 105.19 |
| Idle working set (MiB) | 49.60 | 78.92 | 64.62 | 98.59 |
| Early idle CPU (% of one core) | 0.00 | 0.00 | 0.00 | 0.00 |
| Redraw wall time (ms/op) | 7.16 | 16.67 | 5.54 | 16.66 |
| Redraw CPU (ms/op) | 0.78 | 0.78 | 1.43 | 0.26 |
| Layout + redraw wall (ms/op) | 6.84 | 16.66 | 7.06 | 16.67 |
| Layout + redraw CPU (ms/op) | 0.00 | 0.00 | 1.39 | 0.23 |
| Page switch wall (ms/op) | N/A | N/A | 22.60 | 16.66 |
| Page switch CPU (ms/op) | N/A | N/A | 3.47 | 1.04 |

## Uncapped diagnostic

VSync off; the main results above retain shipping VSync. Each value is the median of the uncapped repeat means.

| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |
|---|---:|---:|---:|---:|
| Redraw wall time (ms/op) | 7.15 | 1.07 | 5.31 | 1.44 |
| Redraw CPU (ms/op) | 0.39 | 0.39 | 1.00 | 0.48 |
| Layout + redraw wall (ms/op) | 6.77 | 0.63 | 7.36 | 2.36 |
| Layout + redraw CPU (ms/op) | 1.04 | 0.00 | 0.81 | 0.93 |
| Page switch wall (ms/op) | N/A | N/A | 22.25 | 5.25 |
| Page switch CPU (ms/op) | N/A | N/A | 2.43 | 1.91 |

## Settled idle diagnostic

One 10-second sample per configuration after eight seconds settling. Zero CPU readings are below the Windows process counter resolution.

| Configuration | CPU ms | % of one core | ImGui frames |
|---|---:|---:|---:|
| iup-none | 0.000 | 0.000 | N/A |
| imgui-none | 15.625 | 0.156 | 1 |
| iup-all | 0.000 | 0.000 | N/A |
| imgui-all | 0.000 | 0.000 | 21 |

## Reproduce

```powershell
scripts/benchmark-ui.ps1 -Runs 3 -Renderer auto -OutputDir build/ui-benchmark-default
scripts/benchmark-ui.ps1 -Runs 3 -Renderer auto -Uncapped -OutputDir build/ui-benchmark-uncapped
scripts/benchmark-ui.ps1 -Runs 1 -Renderer auto -Uncapped -Profile -OutputDir build/ui-benchmark-profile
```

All packs: blackduck, buildqueue, hpe-theme, iloredfish, logparser, lsp-c, lsp-lua, microchip-theme, scanchainparser, timeclock.
Project/media extensions are not enabled; they are not org-pack extensions. Core runs disable every extension and org-profile selection.
Raw results retain every timing sample. `runs.csv` contains per-run means; `pages.csv` contains per-page mean, median, p95 and CPU time.
