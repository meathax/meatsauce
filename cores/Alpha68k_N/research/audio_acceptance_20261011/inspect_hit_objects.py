from pathlib import Path
import csv,json,hashlib
O=Path(__file__).resolve().parent;R=O.parents[1];N=R/'sim/captures/rtl/kyros_combat_hud3301';M=R/'sim/captures/kyros/combat3600_clocked'
prior=json.loads((O/'semantic_windows_result.json').read_text());frames=sorted(set(x['frame'] for x in prior['candidate_hit_commands58']))
out=[];mask_counts={}
with (M/'events.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        frame=int(x['frame'])
        if frame>max(frames)+2:break
        if x['area']!='work' or not any(v-1<=frame<=v+1 for v in frames):continue
        addr,data,mask=map(int,(x['address'],x['data'],x['mask']))
        # Retain complete target state/direction/hit-response updates, player flags and score bytes.
        if 0x20420<=addr<0x20d00 and (addr&31) in (0,2,6,8,10,16) or 0x20100<=addr<=0x20110 or addr in (0x20400,0x20300,0x20370,0x20950,0x20954,0x206d0,0x206d4):
            out.append(x)
snap=[]
for d in (N,M):
    for fr in (870,900,2280,2310,2340,2400):
        p=d/f'frame_{fr:06d}.work.bin'
        if not p.exists():continue
        b=p.read_bytes();objects=[]
        for off in range(0x420,0xd00,32):
            z=b[off:off+32]
            if z[0] or z[8] or z[17]:objects.append({'offset_hex':hex(off),'type':z[0],'state':z[8],'flags3':z[3],'hit11':z[17],'bytes':z.hex()})
        snap.append({'namespace':d.name,'frame':fr,'sha256':hashlib.sha256(b).hexdigest(),'player400_hex':b[0x400:0x420].hex(),'objects':objects})
r={'scope':'Retained accepted MAME target-object hit candidate writes and actual native RAM; candidate analysis only.','hit_command_fields':frames,'target_events':out,'snapshots':snap}
(O/'hit_object_inspection.json').write_text(json.dumps(r,indent=2)+'\n')
print('FIELDS',frames,'SELECTED_EVENTS',len(out))
for x in out:
    if int(x['frame'])<=898:print(json.dumps(x))
for x in snap:
    if x['frame']==900:print('SNAPSHOT900',json.dumps(x))
