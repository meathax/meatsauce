"""Extract a bounded, honest milestone report from archived Quartus reports.

This extracts measured resources and the default STA corner. It does not turn
unreviewed external I/O or unmeasured timing corners into a release pass.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
from timing_corner_gate import read_corner_gate

parser=argparse.ArgumentParser()
parser.add_argument('snapshot',type=Path)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--scope',default='Early CPU/video framework fit; not final Sheriff release acceptance')
args=parser.parse_args()
reports=args.snapshot/'source/output_files'
fit=(reports/'Nintendo8080.fit.rpt').read_text(errors='replace')
sta=(reports/'Nintendo8080.sta.rpt').read_text(errors='replace')
summary=(reports/'Nintendo8080.sta.summary').read_text(errors='replace')
rows=[]
for line in fit.splitlines():
    if line.startswith(';'):
        fields=[v.strip() for v in line.split(';')[1:-1]]
        if fields: rows.append(fields)
resources={}
labels={
    'alms':r'^ALMs: partially or completely used$|^Logic utilization \(in ALMs\)$',
    'labs':r'^(?:Total )?LABs:\s+partially or completely used$',
    'm10k':r'^M10K blocks$', 'memory_bits':r'^Total block memory bits$',
    'dsps':r'^DSP blocks$|^Total DSP Blocks$',
}
for name,pattern in labels.items():
    for fields in rows:
        if re.search(pattern,fields[0],re.I) and len(fields)>1:
            match=re.search(r'([\d,]+)\s*/\s*([\d,]+)',fields[1])
            if match:
                used,total=(int(v.replace(',','')) for v in match.groups())
                resources[name]={'used':used,'available':total,'percent':used/total*100}
                break
for fields in rows:
    if fields[0].startswith(('Average interconnect usage','Peak interconnect usage')):
        values=re.findall(r'([\d.]+)%',fields[1])
        if len(values)==3:
            resources['average_interconnect' if fields[0].startswith('Average') else 'peak_interconnect']=dict(zip(('total','horizontal','vertical'),map(float,values)))
limits=json.loads((Path(__file__).resolve().parents[1]/'config/resource_limits.json').read_text())
slacks={}
for name,slack in re.findall(r'Type\s*:\s*(.*?)\nSlack\s*:\s*(-?[\d.]+)',summary):
    kind=name.split(" '")[0]; slacks[kind]=min(slacks.get(kind,float('inf')),float(slack))
model=re.search(r';\s*Delay Model\s*;\s*([^;]+)',sta)
result={
    'scope':args.scope,
    'snapshot':str(args.snapshot),
    'source_revision':args.snapshot.name.split('-')[0],
    'resources':resources,
    'missing_resource_metrics':sorted((set(labels)|{'peak_interconnect','average_interconnect'})-set(resources)),
    'resource_limit_configuration':limits,
    'default_sta_model':model.group(1).strip() if model else None,
    'default_corner_min_slack_ns':slacks,
    'all_applicable_corners_qualified':False,
    'platform_io_exception_audit_complete':False,
    'release_gate_pass':False,
    'report_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in reports.glob('Nintendo8080.*') if p.suffix in ('.rpt','.summary')},
}
corner_root=args.snapshot/'all-corners'
if (corner_root/'corners.csv').exists():
    result.update(read_corner_gate(corner_root, args.snapshot/'all-corners.stdout.log'))
    result['corner_report_sha256']={str(p.relative_to(corner_root)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in corner_root.rglob('*') if p.is_file() and p.suffix in ('.csv','.txt')}
required={'alms':'logic_alms','labs':'labs_partially_or_completely_used',
          'm10k':'m10k_blocks','memory_bits':'block_memory_bits','dsps':'dsp_blocks'}
resource_checks={key:(resources[key]['percent']<limits['maximum_percent'][setting])
    if key in resources else False for key,setting in required.items()}
for key,setting in [('peak_interconnect','peak_interconnect_max_h_v'),('average_interconnect','average_interconnect')]:
    resource_checks[key]=key in resources and max(resources[key]['horizontal'],resources[key]['vertical'])<limits['maximum_percent'][setting]
result['resource_checks']=resource_checks
result['resource_gate_pass']=all(resource_checks.values())
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('report_sha256','corner_report_sha256','resource_limit_configuration')},indent=2))
