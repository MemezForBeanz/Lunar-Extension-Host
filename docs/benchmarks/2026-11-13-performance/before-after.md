# Performance implementation results

All-packs case: same ten extensions and nine pages. CPU and redraw comparisons below use uncapped three-run medians before and after. Startup uses shipping settings (five baseline runs, three after).

| Metric | Before WARP | After WARP | After GPU | Current IUP |
|---|---:|---:|---:|---:|
| Layout + redraw CPU (ms/op) | 14.12 | 3.94 | 0.93 | 0.81 |
| Page activation CPU (ms/op) | 14.76 | 5.90 | 1.91 | 2.43 |
| Uncapped redraw wall (ms/op) | 4.24 | 4.03 | 1.44 | 5.31 |

ImGui startup readiness: 3215.6 ms before, 532.3 ms after.
Private memory (MiB): before_warp=81.7, after_warp=71.3, after_gpu=105.2, current_iup=44.3.

The WARP-only comparison separates the engine improvements from GPU offload. GPU driver initialization and memory are part of the new default; the renderer actually selected is recorded in every after result. CPU counters have finite resolution and exclude GPU and child-process work. See the implementation report for limitations and qualification.
