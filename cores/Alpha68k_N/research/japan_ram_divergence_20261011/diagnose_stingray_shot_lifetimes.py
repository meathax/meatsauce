"""Exact retained shot birth/retirement coordinates and bounded collision ROM proof."""
from pathlib import Path
import json,csv,hashlib,subprocess
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
BASE=Path(__file__).resolve().parent/'stingray_route1800';CAP=BASE/'revised_reference_v1/capture';HERE=BASE/'attack_diagnosis'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
memory=bytearray((CAP/'frame_000000.work.bin').read_bytes());open_shots={};shots=[]
def u16(i):return memory[i]*256+memory[i+1]
for row in csv.DictReader((CAP/'guest_effect_events.csv').open()):
    if row['area']!='work_write':continue
    f=int(row['frame']);a=int(row['address']);d=int(row['data']);mask=int(row['mask']);pc=int(row['main_pc'])
    for lane in [0,1]:
        lm=0xff00 if lane==0 else 255
        if mask&lm:memory[a-0x20000+lane]=(d>>8)&255 if lane==0 else d&255
    if f<879 or not 0x2081a<=a<=0x20822:continue
    index=(a-0x2081a)//2;word=u16(0x81a+2*index);age=memory[0x120+4-index]
    if pc==0x3f56:
        assert index not in open_shots
        open_shots[index]=dict(slot=index,born=f,birth_YX=hex(word),orientation=memory[0x104],mode=memory[0x10b],last_active_YX=hex(word),age=age,writes=[])
    if index in open_shots:
        shot=open_shots[index]
        if word!=0xf0f0:shot['last_active_YX']=hex(word);shot['age']=age
        if len(shot['writes'])<12:shot['writes'].append(dict(frame=f,word=hex(word),PC=hex(pc),age=age))
        if word==0xf0f0:
            shot.update(retired=f,retire_PC=hex(pc),retire_age=age);shots.append(shot);del open_shots[index]
assert not open_shots
tool=ROOT/'tools/mame0289/unidasm.exe';rom=ROOT/'roms/sstingry/maincpu.bin';entries=[]
for base,count in [(0x43cc,94),(0x446a,180),(0x1dc8,48),(0x7288,64)]:
    command=[str(tool),str(rom),'-arch','m68000','-skip',str(base),'-count',str(count),'-basepc',f'{base:x}']
    child=subprocess.run(command,capture_output=True,text=True);assert child.returncode==0
    p=HERE/f'ROM_{base:06x}.asm.txt';assert not p.exists();p.write_text(child.stdout+child.stderr);entries.append(dict(command=command,actual_exit=0,output=pin(p)))
p=HERE/'shot_lifetimes.json';assert not p.exists();p.write_text(json.dumps(dict(scope='Nine retained genuine P1 shots; source-only, no new runtime',shots=shots,ROM_source=entries,source=pin(Path(__file__)),raw=pin(CAP/'guest_effect_events.csv')),indent=2)+'\n')
print(json.dumps(dict(report=pin(p),shots=[{k:v for k,v in s.items() if k!='writes'} for s in shots],actual_source_exits=[0]*4),indent=2))
