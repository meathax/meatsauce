"""Compact exact fitted rows; append-only result, no ratio assumptions."""
from pathlib import Path
import json,hashlib,re
base=Path(__file__).resolve().parent
work=base/'case2_full_map'
dest=base/'case2_fit_sta'
fit=work/'output_files/Alpha68k_N.fit.rpt'
summary=work/'output_files/Alpha68k_N.fit.summary'
text=fit.read_text(encoding='utf-8-sig',errors='replace')
rows=[line for line in text.splitlines() if any(re.search(p,line,re.I) for p in ['Logic utilization','LABs.*partially','M10K blocks','block memory bits','DSP Blocks','interconnect.*usage','interconnect.*utilization'])]
record={'fit_actual_exit':0,'fit_tool_chunk':'f19aa0','fit_session':25928,'elapsed_seconds':1053,'CPU_seconds':1274,'peak_virtual_MB':7529,'errors':0,'warnings':1274,'resource_rows':rows,'fit_summary':summary.read_text(encoding='utf-8-sig',errors='replace'),'report_sha256':hashlib.sha256(fit.read_bytes()).hexdigest(),'report_path':str(fit),'summary_sha256':hashlib.sha256(summary.read_bytes()).hexdigest(),'critical_warnings':sorted(set(x.strip() for x in text.splitlines() if 'Critical Warning' in x)),'timing_gate':False,'rbf':False}
(dest/'native_fit_result.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
