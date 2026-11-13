"""Validate and summarize the comparative UI benchmark (Python standard library)."""
import argparse
import csv
import html
import json
import math
import statistics as st
from collections import defaultdict
from pathlib import Path


def summarize(root):
    groups = defaultdict(list)
    inventory = None
    for path in sorted(root.glob('*/result.json')):
        r = json.loads(path.read_text(encoding='utf-8-sig'))
        assert r.get('complete') and not r['errors'], str(path)
        assert r['client'] == {'width': 1400, 'height': 900}, str(path)
        expected = 10 if r['mode'] == 'all' else 0
        assert r['extension_count'] == expected, str(path)
        ids = sorted(e['id'] for e in r['extensions']) if expected else []
        if expected:
            if inventory is None:
                inventory = ids
            assert inventory == ids
            assert len(r['pages']) == 9
        else:
            assert len(r['pages']) == 1 and 'switch' not in r
        def op_mean(op, metric):
            return st.mean(p[op][metric] / len(p[op]['samples_ms']) for p in r['pages'])
        rec = {
            'run': int(path.parent.name.rsplit('-', 1)[1]),
            'ready_ms': r['ready_ms'], 'shown_ms': r['mark_shown_ms'],
            'load_ms': r['load_ms'], 'load_cpu_ms': r['load_cpu_ms'],
            'idle_cpu_ms': r['idle']['cpu_ms'],
            'idle_core_percent': r['idle']['cpu_ms'] / (r['idle']['duration_s'] * 10),
            'idle_private_mb': r['idle']['memory']['private_mb'],
            'idle_working_mb': r['idle']['memory']['working_mb'],
            'ready_cpu_ms': r['ready_cpu_ms'],
            'repaint_wall_ms': op_mean('repaint', 'wall_ms'),
            'repaint_cpu_ms': op_mean('repaint', 'cpu_ms'),
            'relayout_wall_ms': op_mean('relayout', 'wall_ms'),
            'relayout_cpu_ms': op_mean('relayout', 'cpu_ms'),
            'switch_wall_ms': r['switch']['wall_ms'] / len(r['switch']['samples_ms']) if expected else None,
            'switch_cpu_ms': r['switch']['cpu_ms'] / len(r['switch']['samples_ms']) if expected else None,
            'path': str(path),
        }
        groups[f"{r['backend']}-{r['mode']}"].append(rec)
    result = {}
    for name, records in groups.items():
        metrics = {}
        for key in records[0]:
            if key in ('run', 'path'):
                continue
            values = [r[key] for r in records if r[key] is not None]
            metrics[key] = {'median': st.median(values), 'min': min(values), 'max': max(values)} if values else None
        result[name] = {'runs': records, 'metrics': metrics}
    assert len(result) == 4, root
    return result, inventory


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('primary', type=Path)
    ap.add_argument('--uncapped', type=Path)
    ap.add_argument('--idle', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    primary, inventory = summarize(args.primary)
    data = {'primary': primary, 'extensions': inventory}
    if args.uncapped:
        data['uncapped'] = summarize(args.uncapped)[0]
    if args.idle:
        data['settled_idle'] = {}
        for path in args.idle.glob('*/result.json'):
            r=json.loads(path.read_text())
            assert r['complete'] and r['idle_only'] and not r['errors']
            assert 9.9 < r['idle']['duration_s'] < 11
            data['settled_idle'][f"{r['backend']}-{r['mode']}"] = r['idle']
    (args.out / 'summary.json').write_text(json.dumps(data, indent=2), encoding='utf-8')
    with (args.out / 'runs.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['suite', 'configuration'] + list(next(iter(primary.values()))['runs'][0]))
        writer.writeheader()
        for suite in ('primary', 'uncapped'):
            for config, group in data.get(suite, {}).items():
                for r in group['runs']:
                    writer.writerow(dict(suite=suite, configuration=config, **r))
    with (args.out / 'pages.csv').open('w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['suite','configuration','run','page','operation','mean_ms','median_ms','p95_ms','cpu_ms_per_op'])
        for suite in ('primary','uncapped'):
            for config, group in data.get(suite, {}).items():
                for run in group['runs']:
                    raw=json.loads(Path(run['path']).read_text())
                    for p in raw['pages']:
                        for op in ('repaint','relayout'):
                            samples=sorted(p[op]['samples_ms'])
                            w.writerow([suite,config,run['run'],p['title'],op,st.mean(samples),st.median(samples),samples[math.ceil(.95*len(samples))-1],p[op]['cpu_ms']/len(samples)])
    def val(config, key, suite='primary'):
        metric=data[suite][config]['metrics'][key]
        return metric['median'] if metric else None
    labels = ['iup-none','imgui-none','iup-all','imgui-all']
    md = ['# IUP and ImGui UI benchmark', '',
          'Medians of five fresh-process runs per configuration. Lower is better. '
          'CPU time sums every thread in the app process; it excludes child processes. '
          'Idle CPU is a percentage of one logical core, not Task Manager’s whole-machine percentage.', '',
          '| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |',
          '|---|---:|---:|---:|---:|']
    metrics=[('Launch → ready UI (ms)','ready_ms'),('Extension load (ms)','load_ms'),
             ('Idle private memory (MiB)','idle_private_mb'),('Idle working set (MiB)','idle_working_mb'),
             ('Early idle CPU (% of one core)','idle_core_percent'),('Redraw wall time (ms/op)','repaint_wall_ms'),
             ('Redraw CPU (ms/op)','repaint_cpu_ms'),('Layout + redraw wall (ms/op)','relayout_wall_ms'),
             ('Layout + redraw CPU (ms/op)','relayout_cpu_ms'),('Page switch wall (ms/op)','switch_wall_ms'),
             ('Page switch CPU (ms/op)','switch_cpu_ms')]
    for title,key in metrics:
        values=[val(c,key) for c in labels]
        md.append('| '+title+' | '+' | '.join('N/A' if v is None else f'{v:.2f}' for v in values)+' |')
    if 'uncapped' in data:
        md += ['', '## Uncapped diagnostic', '',
               'VSync off; the main results above retain shipping VSync. Each value is the median of the uncapped repeat means.', '',
               '| Metric | IUP core | ImGui core | IUP all packs | ImGui all packs |',
               '|---|---:|---:|---:|---:|']
        for title,key in metrics[5:]:
            values=[val(c,key,'uncapped') for c in labels]
            md.append('| '+title+' | '+' | '.join('N/A' if v is None else f'{v:.2f}' for v in values)+' |')
    if 'settled_idle' in data:
        md += ['', '## Settled idle diagnostic', '',
               'One 10-second sample per configuration after eight seconds settling. '
               'Zero CPU readings are below the Windows process counter resolution.', '',
               '| Configuration | CPU ms | % of one core | ImGui frames |', '|---|---:|---:|---:|']
        for config in labels:
            idle=data['settled_idle'][config]
            md.append(f"| {config} | {idle['cpu_ms']:.3f} | {idle['cpu_ms']/idle['duration_s']/10:.3f} | {idle.get('frames','N/A')} |")
    md += ['', '## Reproduce', '', '```powershell',
           'scripts/benchmark-ui.ps1 -Runs 5 -OutputDir build/ui-benchmark-default',
           'scripts/benchmark-ui.ps1 -Runs 3 -Uncapped -OutputDir build/ui-benchmark-uncapped',
           'scripts/benchmark-ui.ps1 -Runs 1 -Uncapped -Profile -OutputDir build/ui-benchmark-profile',
           '```', '', 'All packs: '+', '.join(inventory)+'.',
           'Project/media extensions are not enabled; they are not org-pack extensions. Core runs disable every extension and org-profile selection.',
           'Raw results retain every timing sample. `runs.csv` contains per-run means; `pages.csv` contains per-page mean, median, p95 and CPU time.', '']
    (args.out/'results.md').write_text('\n'.join(md),encoding='utf-8')
    # A compact, self-contained comparison chart; numeric labels also expose the
    # exact values to screen readers without relying on color or hover.
    panels=[]
    for title,key in [metrics[0],metrics[2],metrics[6],metrics[8]]:
        maximum=max(val(c,key) for c in labels) or 1
        rows=[]
        for c,label in zip(labels,['IUP · core','ImGui · core','IUP · all packs','ImGui · all packs']):
            value=val(c,key)
            series='iup' if c.startswith('iup') else 'imgui'
            rows.append(f'<div class="row"><span>{label}</span><div class="track"><div class="bar {series}" style="width:{value/maximum*100:.3f}%"></div></div><b>{value:.2f}</b></div>')
        panels.append('<section><h3>'+html.escape(title)+'</h3>'+''.join(rows)+'</section>')
    fragment='''<style>
#lunar-benchmark {font-family:var(--font-sans);color:var(--foreground)}
#lunar-benchmark .plots {display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:24px}
#lunar-benchmark h3 {font-size:14px;font-weight:500;margin:0 0 12px}
#lunar-benchmark .row {display:grid;grid-template-columns:105px 1fr 52px;align-items:center;gap:8px;margin:9px 0;font-size:12px}
#lunar-benchmark .track {height:16px;background:var(--secondary)}
#lunar-benchmark .bar {height:16px;min-width:1px}
#lunar-benchmark .iup {background:var(--chart-1)}
#lunar-benchmark .imgui {background:var(--chart-2)}
#lunar-benchmark b {font-variant-numeric:tabular-nums;text-align:right;font-weight:400}
#lunar-benchmark .note {color:var(--muted-foreground);font-size:12px;margin:16px 0}
</style><div id="lunar-benchmark" role="figure" aria-label="IUP and ImGui benchmark comparison: five runs per configuration, lower is better"><div class="plots">'''+''.join(panels)+'''</div><div class="note">Medians of five runs · 1400×900 · ImGui uses WARP · CPU sums all app threads · lower is better</div></div>'''
    (args.out/'comparison.html').write_text(fragment,encoding='utf-8')
    print('\n'.join(md[:18]).encode('ascii', 'replace').decode('ascii'))


if __name__ == '__main__':
    main()
