"""Stage a hash-verified private native first-draw fixture for real RTL replay."""
from pathlib import Path
import csv
import hashlib
import json
ROOT=Path(__file__).resolve().parents[1]
def main():
    report=json.loads((ROOT/'docs/mame_gpu_fixture.json').read_text())
    private=Path(report['output_directory'])
    artifacts={x['path']:x for x in report['artifacts']}
    required=['first_gpu_batch.json','first_gpu_frame_before.bin','first_gpu_texture.bin','gpu_packets.csv']
    for name in required:
        data=(private/name).read_bytes();expected=artifacts[name]
        if len(data)!=expected['bytes'] or hashlib.sha256(data).hexdigest()!=expected['sha256']:
            raise RuntimeError('Native GPU fixture changed: '+name)
    state=json.loads((private/'first_gpu_batch.json').read_text())
    texture=(private/'first_gpu_texture.bin').read_bytes()
    with (private/'gpu_packets.csv').open() as f:rows=list(csv.DictReader(f))
    active=[r for r in rows if r['active']=='1']
    first=active[0]
    assert int(first['frame'])==state['frame'] and int(first['index'])==state['first']
    assert state['end']==(state['first']+1)&2047
    words=[int(first['word'+str(i)],16) for i in range(32)]
    assert all(int.from_bytes(texture[state['first']*64+i*2:state['first']*64+i*2+2],'little')==w for i,w in enumerate(words))
    out=ROOT/'sim/obj_dir/gpu_game';out.mkdir(parents=True,exist_ok=True)
    (out/'fixture.txt').write_text((private/'first_gpu_texture.bin').as_posix()+'\n'+(private/'first_gpu_frame_before.bin').as_posix()+'\n'+' '.join(str(state[k]) for k in ['frame','first','end','control','display_bank','bank1'])+'\n')
    result={'scope':'Hash-verified first active native game GPU submission; not full-game boot or presentation',
        'capture_frame':state['frame'],'queue_start':state['first'],'queue_end':state['end'],
        'control':state['control'],'display_bank':state['display_bank'],'bank1':state['bank1'],
        'preceding_active_packets':0,'captured_memory_bytes':len(texture)*2,
        'capture_artifacts':{name:artifacts[name] for name in required},
        'packet_flags':words[0],'limits':['Only first captured submission has coherent initial RAM','No subsequent packet/CPU writes assumed','Initial renderer state is reset state; no earlier active packet was recorded']}
    (ROOT/'docs/gpu_game_fixture.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Verified native first active GPU fixture: frame',state['frame'],'queue',state['first'],'->',state['end'],'flags',hex(words[0]))
if __name__=='__main__':main()
