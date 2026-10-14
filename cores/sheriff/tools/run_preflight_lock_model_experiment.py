# SPDX-License-Identifier: GPL-2.0-or-later
"""Retest only the failed power-up seeds with one private PLL model change.

This is an attribution experiment, not a hardware RTL fix or a finding waiver.
The installed tool stays untouched; its native CLI runs in this foreground
process so the private build-helper override also applies to compilation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

parser=argparse.ArgumentParser()
parser.add_argument('--preflight-root',type=Path,required=True)
parser.add_argument('--roms',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
output=args.output.resolve()
assert output.is_relative_to(root), 'Experiment must remain inside this project'
output.mkdir(parents=True,exist_ok=False)
app=args.preflight_root.resolve()
models=output/'private-models'
shutil.copytree(app/'cells',models/'cells')
shutil.copytree(app/'board',models/'board')
cell=models/'cells/altera_pll.sv'
original=cell.read_text()
line="        locked = 1'b0;"
assert original.count(line)==1, 'Unexpected installed PLL model; review it first'
corrected=original.replace(line,'        // locked has one combinational driver; reached already starts at zero.')
cell.write_text(corrected)
receipt={'scope':'Private full-wrapper simulation model attribution experiment',
    'change':'Remove the redundant initial assignment to locked; keep the initialized lock timer and combinational driver',
    'original_model_sha256':hashlib.sha256(original.encode()).hexdigest(),
    'experiment_model_sha256':hashlib.sha256(corrected.encode()).hexdigest(),
    'core_rtl_changed':False,'finding_waived':False,'hardware_result':False}
(output/'experiment.json').write_text(json.dumps(receipt,indent=2)+'\n')
sys.path.insert(0,str(app/'src'))
from preflight import build,util
util.setup_env()
build.APP=models
from preflight.cli import main
# The previous four-boot run is terminal. Keep this retest limited to its two
# failing seeds and avoid repeating its automatic 19-run attribution campaign.
cli=['--repo',str(root),'--roms',str(args.roms.resolve()),'--foreground',
    '--profile','hostile','--seeds','2','--frames','120','--no-diagnose','--force']
receipt['cli_arguments']=cli
(output/'experiment.json').write_text(json.dumps(receipt,indent=2)+'\n')
code=main(cli)
(output/'exit_code.txt').write_text(str(code)+'\n')
raise SystemExit(code)
