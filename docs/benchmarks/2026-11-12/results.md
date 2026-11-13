# IUP and ImGui UI benchmark

Medians of five fresh-process runs per configuration. Lower is better. CPU time sums every thread in the app process; it excludes child processes. Idle CPU is a percentage of one logical core, not Task Manager’s whole-machine percentage.

| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |
|---|---:|---:|---:|---:|
| Launch → ready UI (ms) | 277.75 | 214.19 | 3468.60 | 3215.64 |
| Extension load (ms) | 0.02 | 0.02 | 49.74 | 61.33 |
| Idle private memory (MiB) | 30.89 | 55.12 | 44.42 | 81.73 |
| Idle working set (MiB) | 49.57 | 74.69 | 64.70 | 100.69 |
| Early idle CPU (% of one core) | 0.00 | 0.78 | 0.00 | 3.12 |
| Redraw wall time (ms/op) | 7.20 | 16.67 | 5.02 | 16.67 |
| Redraw CPU (ms/op) | 2.34 | 3.52 | 1.13 | 2.95 |
| Layout + redraw wall (ms/op) | 6.57 | 16.67 | 6.74 | 17.98 |
| Layout + redraw CPU (ms/op) | 1.04 | 4.17 | 1.27 | 14.24 |
| Page switch wall (ms/op) | N/A | N/A | 19.04 | 17.69 |
| Page switch CPU (ms/op) | N/A | N/A | 1.39 | 16.15 |

## Uncapped diagnostic

VSync off; the main results above retain shipping VSync. Each value is the median of the uncapped repeat means.

| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |
|---|---:|---:|---:|---:|
| Redraw wall time (ms/op) | 7.10 | 3.52 | 5.03 | 4.24 |
| Redraw CPU (ms/op) | 0.39 | 2.73 | 0.43 | 4.04 |
| Layout + redraw wall (ms/op) | 6.65 | 5.79 | 6.72 | 16.43 |
| Layout + redraw CPU (ms/op) | 1.04 | 27.08 | 0.35 | 14.12 |
| Page switch wall (ms/op) | N/A | N/A | 18.88 | 16.86 |
| Page switch CPU (ms/op) | N/A | N/A | 2.60 | 14.76 |

## Settled idle diagnostic

One 10-second sample per configuration after eight seconds settling. Zero CPU readings are below the Windows process counter resolution.

| Configuration | CPU ms | % of one core | ImGui frames |
|---|---:|---:|---:|
| iup-none | 0.000 | 0.000 | N/A |
| imgui-none | 15.625 | 0.156 | 1 |
| iup-all | 0.000 | 0.000 | N/A |
| imgui-all | 109.375 | 1.093 | 24 |

## Reproduce

```powershell
scripts/benchmark-ui.ps1 -Runs 5 -OutputDir build/ui-benchmark-default
scripts/benchmark-ui.ps1 -Runs 3 -Uncapped -OutputDir build/ui-benchmark-uncapped
scripts/benchmark-ui.ps1 -Runs 1 -Uncapped -Profile -OutputDir build/ui-benchmark-profile
```

All packs: blackduck, buildqueue, hpe-theme, iloredfish, logparser, lsp-c, lsp-lua, microchip-theme, scanchainparser, timeclock.
Project/media extensions are not enabled; they are not org-pack extensions. Core runs disable every extension and org-profile selection.
Raw results retain every timing sample. `runs.csv` contains per-run means; `pages.csv` contains per-page mean, median, p95 and CPU time.
