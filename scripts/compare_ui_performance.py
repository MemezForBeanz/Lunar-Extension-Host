"""Before/after performance report, using archived runs and no extra dependencies."""
import json
from pathlib import Path
from summarize_ui_benchmark import summarize

base = Path('docs/benchmarks/2026-11-12')
out = Path('docs/benchmarks/2026-11-13-performance')
old = json.loads((base/'summary.json').read_text())
shipping = json.loads((out/'summary.json').read_text())
warp, _ = summarize(out/'warp-uncapped')
gpu = shipping['uncapped']

def metric(group, key, field):
    return group[key]['metrics'][field]['median']

groups = [old['uncapped'], warp, gpu, gpu]
keys = ['imgui-all', 'imgui-all', 'imgui-all', 'iup-all']
names = ['Before · WARP', 'After · WARP', 'After · GPU', 'Current IUP']
metrics = [('Layout + redraw CPU (ms/op)', 'relayout_cpu_ms'),
           ('Page activation CPU (ms/op)', 'switch_cpu_ms'),
           ('Uncapped redraw wall (ms/op)', 'repaint_wall_ms')]
comparison = {}
panels = []
for title, field in metrics:
    values = [metric(g,k,field) for g,k in zip(groups,keys)]
    comparison[field] = dict(zip(names,values))
    maximum=max(values)
    rows=[]
    for i,(name,value) in enumerate(zip(names,values)):
        rows.append(f'<div class="row"><span>{name}</span><div class="track"><div class="bar c{i}" style="width:{value/maximum*100:.3f}%"></div></div><b>{value:.2f}</b></div>')
    panels.append('<section><h3>'+title+'</h3>'+''.join(rows)+'</section>')
startups=[metric(old['primary'],'imgui-all','ready_ms'),metric(shipping['primary'],'imgui-all','ready_ms')]
comparison['startup_ready_ms']={'before':startups[0],'after':startups[1]}
comparison['private_memory_mb']={
 'before_warp':metric(old['primary'],'imgui-all','idle_private_mb'),
 'after_warp':metric(warp,'imgui-all','idle_private_mb'),
 'after_gpu':metric(shipping['primary'],'imgui-all','idle_private_mb'),
 'current_iup':metric(shipping['primary'],'iup-all','idle_private_mb')}
(out/'before-after.json').write_text(json.dumps(comparison,indent=2),encoding='utf-8')
md=['# Performance implementation results','',
 'All-packs case: same ten extensions and nine pages. CPU and redraw comparisons below use uncapped three-run medians before and after. Startup uses shipping settings (five baseline runs, three after).', '',
 '| Metric | Before WARP | After WARP | After GPU | Current IUP |','|---|---:|---:|---:|---:|']
for title,field in metrics:
    md.append('| '+title+' | '+' | '.join(f'{v:.2f}' for v in comparison[field].values())+' |')
md+=['',f'ImGui startup readiness: {startups[0]:.1f} ms before, {startups[1]:.1f} ms after.',
     'Private memory (MiB): '+', '.join(f'{k}={v:.1f}' for k,v in comparison['private_memory_mb'].items())+'.',
     '', 'The WARP-only comparison separates the engine improvements from GPU offload. GPU driver initialization and memory are part of the new default; the renderer actually selected is recorded in every after result. CPU counters have finite resolution and exclude GPU and child-process work. See the implementation report for limitations and qualification.', '']
(out/'before-after.md').write_text('\n'.join(md),encoding='utf-8')
chart='''<style>
#perf-change{font-family:var(--font-sans);color:var(--foreground)}
#perf-change .plots{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:24px}
#perf-change h3{font-size:14px;font-weight:500;margin:0 0 12px}
#perf-change .row{display:grid;grid-template-columns:112px 1fr 48px;gap:8px;align-items:center;margin:9px 0;font-size:12px}
#perf-change .track{height:16px;background:var(--secondary)}
#perf-change .bar{height:16px;min-width:1px}
#perf-change .c0{background:var(--chart-1)}#perf-change .c1{background:var(--chart-2)}
#perf-change .c2{background:var(--chart-3)}#perf-change .c3{background:var(--chart-4)}
#perf-change b{font-weight:400;text-align:right;font-variant-numeric:tabular-nums}
#perf-change .note{font-size:12px;color:var(--muted-foreground);margin-top:16px}
</style><div id="perf-change" role="figure" aria-label="All-packs before and after performance, lower is better"><div class="plots">'''+''.join(panels)+'''</div><p class="note">All org packs · three uncapped runs per case · lower is better · process CPU excludes GPU work</p></div>'''
(out/'before-after.html').write_text(chart,encoding='utf-8')
print(json.dumps(comparison,indent=2))
