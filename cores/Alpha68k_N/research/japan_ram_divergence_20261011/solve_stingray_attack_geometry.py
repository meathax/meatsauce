"""Reconstruct source-defined target rectangles at actual projectile-coordinate writes."""
from pathlib import Path
import json,csv,hashlib
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
BASE=Path(__file__).resolve().parent/'stingray_route1800';HERE=BASE/'attack_diagnosis';CAP=BASE/'revised_reference_v1/capture'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
rom=(ROOT/'roms/sstingry/maincpu.bin').read_bytes();memory=bytearray((CAP/'frame_000000.work.bin').read_bytes());observations=[];phase=[]
def u16(o):return memory[o]*256+memory[o+1]
for r in csv.DictReader((CAP/'guest_effect_events.csv').open()):
    if r['area']!='work_write':continue
    f=int(r['frame']);a=int(r['address']);d=int(r['data']);m=int(r['mask']);pc=int(r['main_pc'])
    for lane in [0,1]:
        lm=0xff00 if lane==0 else 255
        if m&lm:memory[a-0x20000+lane]=(d>>8)&255 if lane==0 else d&255
    if f<879 or not 0x2081a<=a<=0x20822 or pc not in [0x3f56,0x4214]:continue
    i=(a-0x2081a)//2;sy=memory[0x81a+2*i];sx=memory[0x81b+2*i]
    wx=(240-sx+u16(0x12))&65535;wy=(224-sy+u16(0x1c))&65535
    targets=[]
    for slot,obj in enumerate(memory[0x600:0x608]):
        if obj>=128:continue
        off=0x620+obj*16
        if off+15>=len(memory):continue
        typ=memory[off];tx=u16(off+2);ty=u16(off+4);radius=rom[0x72c8+typ]
        targets.append(dict(slot=slot,object=obj,type=typ,word2_X=tx,word4_Y=ty,world_delta_X=tx-wx,world_delta_Y=ty-wy,source_radius_byte=radius,
            first_axis_pass=((tx-wx+16)&65535)<32,
            normal_positive_radius=0<radius<128,
            both_rectangle_axes_pass=0<radius<128 and ((tx-wx+16)&65535)<32 and ((ty-wy+radius)&65535)<2*radius))
    observations.append(dict(frame=f,writer_PC=hex(pc),projectile_slot=i,orientation=memory[0x104],mode=memory[0x10b],screen_pair=[sy,sx],world_pair=[wx,wy],scroll_words=[u16(0x12),u16(0x1c)],targets=targets))
births=[x for x in observations if x['writer_PC']=='0x3f56'];updates=[x for x in observations if x['writer_PC']=='0x4214']
summary=dict(scope='Source-defined collision inputs at retained projectile commits; no claimed execution trace',births=births,updates=updates,
    actual_update_count=len(updates),first_axis_candidate_count=sum(any(t['first_axis_pass'] for t in x['targets']) for x in updates),
    both_rectangle_candidate_count=sum(any(t['both_rectangle_axes_pass'] for t in x['targets']) for x in updates),
    source=pin(Path(__file__)),ROM=pin(ROOT/'roms/sstingry/maincpu.bin'),raw=pin(CAP/'guest_effect_events.csv'),
    limits='Reconstructed at actual coordinate write, before later collision read. Terrain tile gate can prevent reaching this enemy test; target type FF/FE special handlers remain ineligible normal-radius cases, not ignored game state. No CPU register or branch trace proves every actual path.')
p=HERE/'geometry.json';assert not p.exists();p.write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(dict(geometry=pin(p),birth_targets=births[0],actual_updates=len(updates),first_axis_candidates=summary['first_axis_candidate_count'],both_axis_candidates=summary['both_rectangle_candidate_count']),indent=2))
