# SPDX-License-Identifier: GPL-2.0-or-later
"""Run the small lock-driver probe with Preflight's native toolchain.

Imports its build helpers without editing the installed tool or its generated
cache. This probe is diagnostic and never waives a full-wrapper finding.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

parser=argparse.ArgumentParser()
parser.add_argument('--preflight-root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
output=args.output.resolve()
assert output.is_relative_to(root), 'Probe output must remain in this project'
output.mkdir(parents=True,exist_ok=False)
sys.path.insert(0,str(args.preflight_root.resolve()/'src'))
from preflight import build,util
util.setup_env()
# Keep runtime and compiler caches inside the explicitly selected workspace.
build.shared_cache=lambda _: output/'shared'
obj=output/'obj';obj.mkdir()
source=root/'sim/pll_lock_model_probe.sv'
cmd=[*util.verilator_argv(),'--cc','--exe','--main','--timing',
    '--timescale-override','1ps/1ps','--top-module','pll_lock_model_probe',
    '--Mdir',str(obj),'-O3','--x-assign','unique','--x-initial','unique',
    '--no-assert','-Wno-fatal','-Wno-MULTIDRIVEN',str(source)]
r=subprocess.run(cmd,capture_output=True,text=True)
log=output/'build.log';log.write_text(r.stdout+'\n'+r.stderr)
assert r.returncode==0, 'Native Verilator failed; inspect build.log'
binary=obj/('pll_lock_probe.exe' if os.name=='nt' else 'pll_lock_probe')
sources=[p for p in sorted(obj.glob('Vpll_lock_model_probe*.cpp')) if '__ALL' not in p.name]
r=build.compile_and_link(obj,sources,binary,dict(os.environ),log,
    top='Vpll_lock_model_probe',cache_root=root)
assert r.returncode==0 and binary.exists(), 'Native compiler failed; inspect build.log'
if os.name=='nt':assert binary.open('rb').read(2)==b'MZ'
results=[]
for mode in (0,2):
    for seed in (1,2,3,4):
        r=subprocess.run([str(binary),f'+verilator+rand+reset+{mode}',f'+verilator+seed+{seed}'],
            capture_output=True,text=True)
        match=re.search(r'original_count=(\d+) single_driver_count=(\d+) expected=(\d+)',r.stdout)
        assert r.returncode==0 and match, 'Probe failed; retain its native output'
        old,new,expected=map(int,match.groups())
        assert new==expected==5050
        results.append({'random_reset_mode':mode,'seed':seed,'original_count':old,
            'single_driver_count':new,'expected_count':expected})
version=subprocess.run([*util.verilator_argv(),'--version'],capture_output=True,text=True).stdout.strip()
report={'scope':'Minimal PLL lock-driver probe with the actual Preflight native compiler',
    'native_version':version,'cases':results,
    'minimal_original_failure_reproduced':any(r['original_count']!=5050 for r in results),
    'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
    'elf_or_pe_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'full_wrapper_findings_waived':False,'complete_simulation_gate_pass':False}
(output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'report':str(output/'result.json'),'native_version':version,
    'original_counts':[r['original_count'] for r in results],
    'single_driver_counts':[r['single_driver_count'] for r in results]}))
