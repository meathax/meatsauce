"""Compare only the early-boot DMA buffer ranges; no visual/gameplay claim."""
from pathlib import Path
import hashlib
import json
import argparse

root=Path(__file__).resolve().parents[1]
out=root/'sim/results'
parser=argparse.ArgumentParser()
parser.add_argument('--live',action='store_true')
args=parser.parse_args()
prefix='board-av-' if args.live else 'board-'
mapping={'bg':'bg_src','fg':'fg_src','mg':'mg_src','text':'text_src',
         'palette':'pal_src','sprite':'sprite_src'}
rows={}
for layer,reference in mapping.items():
    actual=(out/f'{prefix}{layer}.bin').read_bytes()
    expected=(out/'mame-attract-60'/f'{reference}.bin').read_bytes()
    assert len(actual)>=len(expected)
    actual=actual[:len(expected)]
    rows[layer]={'bytes_compared':len(expected),'equal':actual==expected,
                 'rtl_sha256':hashlib.sha256(actual).hexdigest(),
                 'mame_sha256':hashlib.sha256(expected).hexdigest()}
metadata={'set':'zeroteam','mame_frame':60,'rtl_cycles':104000000,
          'reference_scene':'Early Seibu logo, before populated attract scenes',
          'ranges':rows,
          'limits':'Actual RTL renderer buffers versus MAME CPU source ranges. The three tilemaps are empty here; this does not prove rendered video, later protection/sort behavior, sound or gameplay.'}
name='live-boot-buffer-comparison.json' if args.live else 'boot-buffer-comparison.json'
(root/'docs/evidence'/name).write_text(json.dumps(metadata,indent=2)+'\n')
failed=[k for k,v in rows.items() if not v['equal']]
if failed: raise SystemExit('Differences: '+', '.join(failed))
print('Exact early-boot matches: '+', '.join(rows))
