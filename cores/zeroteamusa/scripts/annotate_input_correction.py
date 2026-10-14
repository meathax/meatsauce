"""Retain historical evidence while making its incorrect coin input explicit."""
from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
p=root/'docs/evidence/audio-live-60.json'
d=json.loads(p.read_text())
d['input_state']={'coin_byte':0,'correct_idle':255,'status':'Historical run incorrectly held active-low coin pins active'}
limit='Incorrect idle coin input: this checkpoint does not prove uncredited attract or credited input behavior.'
if limit not in d['limits']:d['limits'].append(limit)
p.write_text(json.dumps(d,indent=2)+'\n')
print('Historical video/sound evidence retained with explicit coin-input limitation.')
