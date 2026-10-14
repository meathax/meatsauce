"""Reject a saved RTL state when its hardware/ROM inputs no longer match."""
from pathlib import Path
import sys,json
args=sys.argv[1:]
if '--load' not in args:raise SystemExit(0)
base=Path(args[args.index('--load')+1])
saved=json.loads(Path(str(base)+'.json').read_text())
current=json.loads(Path('sim/results/av-source-stamp.json').read_text())
old={p:h for p,h in saved['sources'].items() if p.startswith('rtl/') or p.endswith('zero_av_top.sv')}
now={p:h for p,h in current['sources'].items() if p.startswith('rtl/') or p.endswith('zero_av_top.sv')}
assert old==now,'RTL inputs changed; cold boot required for the changed hardware'
assert saved['rom_regions']==current['rom_regions'],'ROM inputs changed'
assert saved['verilator_version']==current['verilator_version'],'Verilator serialization version changed'
assert saved['model_config']==current['model_config'],'Model configuration changed'
assert Path(str(base)+'.rtl').is_file() and Path(str(base)+'.host').is_file(),'Missing checkpoint stream'
print('Verified checkpoint hardware/ROM identity.')
