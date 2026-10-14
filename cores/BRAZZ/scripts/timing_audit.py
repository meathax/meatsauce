#!/usr/bin/env python3
"""Audit an existing Quartus fit; preserve constraints and generate no bitstream."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

def _sq_refuse_quartus(recipe):
    raise RuntimeError('Standalone Quartus operations are disabled. Use canonical quartus_flow.ps1 -Action Start -RecipeId '
                       + recipe + ' after the complete recipe is registered. Assembly authority remains separate.')


ROOT = Path(__file__).resolve().parents[1]
TCL = '''package require ::quartus::sta
project_open board
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir timing_paths
set corner 0
foreach_in_collection op [get_available_operating_conditions] {
    set_operating_conditions $op
    update_timing_netlist
    report_timing -setup -npaths 4 -detail full_path -file timing_paths/corner${corner}_setup.rpt
    report_timing -hold -npaths 4 -detail full_path -file timing_paths/corner${corner}_hold.rpt
    report_timing -setup -from [all_registers] -to [all_registers] -npaths 4 -detail full_path -file timing_paths/corner${corner}_internal_setup.rpt
    report_timing -hold -from [all_registers] -to [all_registers] -npaths 4 -detail full_path -file timing_paths/corner${corner}_internal_hold.rpt
    incr corner
}
report_ucp -file timing_paths/unconstrained.rpt
project_close -dont_export_assignments
'''


def audit(stage, quartus_bin, project='board'):
    """Return exact bounded results from all device operating corners."""
    stage = Path(stage)
    script = stage / 'timing_audit.tcl'
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', project):
        raise ValueError('invalid Quartus project name')
    script_text = TCL.replace('project_open board', 'project_open ' + project)
    script.write_text(script_text, encoding='utf-8')
    started = time.monotonic()
    log = stage / 'timing_audit.log'
    with log.open('w', encoding='utf-8') as out:
        proc = _sq_refuse_quartus('brazz-complete-timing-audit')
        print('QUARTUS_PID timing_audit ' + str(proc.pid), flush=True)
        code = proc.wait()
    errors = [x for x in log.read_text(errors='replace').splitlines()
              if re.match(r'\s*(?:Error|Fatal Error)\b', x)]
    result = dict(returncode=code, errors=errors[:12], seconds=round(time.monotonic() - started, 3),
                  log=str(log), project=project,
                  audit_script_sha256=hashlib.sha256(script_text.encode()).hexdigest(), corners=[])
    if code or errors:
        result['status'] = 'AUDIT_ERROR'
        (stage / 'timing_audit.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        return result
    for file in sorted((stage / 'timing_paths').glob('corner*_setup.rpt')):
        if '_internal_' in file.name:
            continue
        prefix = file.name.removesuffix('_setup.rpt')
        entry = {}
        for kind in ('setup', 'hold', 'internal_setup', 'internal_hold'):
            path = file.with_name(prefix + '_' + kind + '.rpt')
            text = path.read_text(errors='replace')
            match = re.search(r'Path #1: (?:Setup|Hold) slack is (-?\d+(?:\.\d+)?)', text)
            model = re.search(r'Delay Model:\s*\n\s*([^\r\n]+)', text)
            first_path = text.split('Path #1:', 1)[-1]
            facts = {name: re.search(r'; ' + name + r'\s*; ([^;\r\n]+)', first_path)
                     for name in ('From Node', 'To Node', 'Data Delay')}
            if not match or not model or any(not value for value in facts.values()):
                raise RuntimeError('cannot recover exact timing path: ' + str(path))
            entry['model'] = model.group(1).strip()
            entry[kind] = dict(slack_ns=float(match.group(1)), report=str(path),
                               **{name.lower().replace(' ', '_'): value.group(1).strip()
                                  for name, value in facts.items()})
        result['corners'].append(entry)
    ucp = (stage / 'timing_paths/unconstrained.rpt').read_text(errors='replace')
    expected = {'Illegal Clocks', 'Unconstrained Clocks', 'Unconstrained Input Ports',
                'Unconstrained Input Port Paths', 'Unconstrained Output Ports',
                'Unconstrained Output Port Paths'}
    counts = {name.strip(): [int(setup), int(hold)] for name, setup, hold in
              re.findall(r';\s*([^;\r\n]+)\s*;\s*(\d+)\s*;\s*(\d+)\s*;', ucp)}
    result['unconstrained'] = {name: counts[name] for name in sorted(expected) if name in counts}
    covered = len(result['corners']) == 4 and expected.issubset(counts) and not any(
        sum(counts[name]) for name in expected if name in counts)
    result['fully_constrained'] = covered
    result['internal_status'] = ('INTERNAL_PASS' if covered and all(
        c[k]['slack_ns'] >= 0 for c in result['corners']
        for k in ('internal_setup', 'internal_hold')) else 'INTERNAL_FAIL')
    result['status'] = ('AUDIT_PASS' if covered and all(c[k]['slack_ns'] >= 0
        for c in result['corners'] for k in ('setup', 'hold')) else 'AUDIT_FAIL')
    (stage / 'timing_audit.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot')
    parser.add_argument('--quartus-bin', default='D:/q17/quartus/bin64')
    args = parser.parse_args()
    stage = Path(args.snapshot).resolve()
    if (ROOT / 'sim/obj_dir/timing').resolve() not in stage.parents:
        raise RuntimeError('snapshot must be inside this project timing directory')
    saved = json.loads((stage / 'check_report.json').read_text(encoding='utf-8'))
    if not any(s['tool'] == 'quartus_fit' and s['returncode'] == 0 and not s['errors']
               for s in saved['steps']):
        raise RuntimeError('audit requires a successful fit')
    # The CLI can inspect historical fits; snapshot content/configuration must remain exact.
    for name, digest in {**saved['source_sha256'], **saved['configuration_sha256']}.items():
        if hashlib.sha256((stage / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('fitted snapshot changed: ' + name)
    subprocess.run([sys.executable, str(ROOT / 'scripts/hwlock.py'), '--require-no-jtag',
                    'audit existing board fit'], cwd=ROOT, check=True)
    result = audit(stage, args.quartus_bin)
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'AUDIT_PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
