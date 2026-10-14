"""Bind the observed-US-operand COP check; never publish raw actor/ROM data."""
from pathlib import Path
import json,hashlib,csv,subprocess
root=Path(__file__).resolve().parents[1]
result=json.loads((root/'sim/results/cop-distance.json').read_text())
assert result=={'cases':78,'different_results':0,'unexpected_distance_writes':0}
fixture=root/'sim/results/mame-play-900-play-2p/distance-cases.csv'
with fixture.open() as f:rows=list(csv.DictReader(f))
files=['rtl/Raiden2/Raiden2_cop3.sv','rtl/common/savestate.sv','rtl/common/savestate_ram.sv',
       'sim/zero_cop_math_top.sv','sim/cop_math_main.cpp','sim/run_cop_math.sh','sim/mame/play.lua']
old=subprocess.check_output(['git','show','4f5b292686027480ed8f63af33b999f708d8d2dc:rtl/Raiden2/Raiden2_cop3.sv'],cwd=root)
meta={'scope':'Actual COP RTL on 78 observed US 3b30 operand/result cases, preceded by real angle operation',
      'result':result,'first_observed_frame':min(int(r['frame']) for r in rows),
      'change':'3b30 selects the existing restoring-integer-square-root distance datapath; bit 7 still gates RAM writes',
      'baseline_source_sha256':hashlib.sha256(old).hexdigest(),
      'sources':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},
      'fixture_sha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),
      'limits':['No main CPU runs in this narrow real-chip replay; full-board continuation is separate.',
                'Replay source memory uses the production two-clock input latency; initial one-clock replay was corrected before this passing result.',
                'MAME operand snapshots and readback values are the independent expected results; no host-side CPU/protection substitute.',
                'Only the observed 3b30 cases and no-RAM-write behavior are covered; other COP operations and later gameplay remain pending.',
                'Pre-fix live checkpoints after the first 3b30 call are diagnostically affected and must not be used as validated bring-up states.']}
(root/'docs/evidence/cop-distance-us.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Recorded 78 exact target distance results and zero unexpected result writes.')
