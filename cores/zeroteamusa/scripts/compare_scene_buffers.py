"""Compare completed live renderer buffers with one MAME scene, retaining exact differences."""
from pathlib import Path
import argparse,hashlib,json
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('frame',type=int)
parser.add_argument('--prefix',default='board-av-')
args=parser.parse_args()
mapping={'bg':('bg_src',0xb800),'fg':('fg_src',0xc000),'mg':('mg_src',0xc800),
         'text':('text_src',0xd000),'palette':('pal_src',0xe000),'sprite':('sprite_src',0xf000)}
if (root/'sim/results'/f'{args.prefix}crtc.bin').exists():
    mapping['crtc']=('reg_crtc',0x600)
rows={}
sha=lambda b:hashlib.sha256(b).hexdigest()
for layer,(reference,base) in mapping.items():
    actual_path=root/'sim/results'/f'{args.prefix}{layer}.bin'
    ref_path=root/f'sim/results/mame-attract-{args.frame}'/f'{reference}.bin'
    actual=actual_path.read_bytes();expected=ref_path.read_bytes()
    assert len(actual)>=len(expected) and len(expected)%2==0
    actual=actual[:len(expected)]
    differences=[(i,int.from_bytes(actual[i:i+2],'little'),int.from_bytes(expected[i:i+2],'little'))
        for i in range(0,len(expected),2) if actual[i:i+2]!=expected[i:i+2]]
    rows[layer]={'bytes_compared':len(expected),'different_words':len(differences),
        'rtl_path':actual_path.relative_to(root).as_posix(),'mame_path':ref_path.relative_to(root).as_posix(),
        'rtl_sha256':sha(actual),'mame_sha256':sha(expected),
        'first_differences':[{'source_address':hex(base+i),'rtl':hex(a),'mame':hex(b)} for i,a,b in differences[:12]]}
meta={'frame':args.frame,'ranges':rows,
    'limits':'Renderer buffers versus MAME CPU source ranges at approximately aligned scenes; differences require state/DMA timing analysis, not automatic RTL fault attribution.'}
path=root/'sim/results'/f'scene-buffer-comparison-{args.frame}.json'
path.write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({key: {'different_words':value['different_words'],'first_differences':value['first_differences'][:3]} for key,value in rows.items()}))
print('Exact recovery:',path)
