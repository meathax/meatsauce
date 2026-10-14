"""Bounded ROM/projectile/coordinate source diagnosis from immutable completed capture."""
from pathlib import Path
import csv,json,hashlib,subprocess,re,collections
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
BASE=Path(__file__).resolve().parent/'stingray_route1800'
REF=BASE/'revised_reference_v1';CAP=REF/'capture';OUT=BASE/'attack_diagnosis'
assert not OUT.exists();OUT.mkdir()
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
tool=ROOT/'tools/mame0289/unidasm.exe';rom=ROOT/'roms/sstingry/maincpu.bin'
cmd=[str(tool),str(rom),'-arch','m68000','-count','45056','-basepc','0']
child=subprocess.run(cmd,capture_output=True,text=True);assert child.returncode==0
source=child.stdout.splitlines();matches=[]
for i,line in enumerate(source):
    if re.search(r'\(\$20,A6\)|\(\$28,A6\)|\(\$770,A6\)|\b(?:bsr|jsr)\s+\$(?:16[0-9a-f]{2}|3e[0-9a-f]{2})',line):
        matches.append(dict(line=line,context=source[max(0,i-2):i+3]))
regions=[]
for base,count in [(0x1600,250),(0x3198,550),(0x3eb4,170),(0x4100,200),(0x2430,160)]:
    command=[str(tool),str(rom),'-arch','m68000','-skip',str(base),'-count',str(count),'-basepc',f'{base:x}']
    child=subprocess.run(command,capture_output=True,text=True);assert child.returncode==0
    p=OUT/f'ROM_{base:06x}.asm.txt';p.write_text(child.stdout+child.stderr)
    regions.append(dict(command=command,actual_exit=0,output=pin(p)))
memory=bytearray((CAP/'frame_000000.work.bin').read_bytes())
stats={};samples=[];shot_writes=[];coord_changes=[];source_counts=collections.Counter();observed_fields=set()
def u16(off):return memory[off]*256+memory[off+1]
def sample(f):
    return dict(frame=f,turn=memory[0x5b],spares=list(memory[0xe:0x10]),orientation=memory[0x104],mode=memory[0x10b],
        current_YX=list(memory[0x126:0x128]),words_XY=[u16(0x116),u16(0x118)],
        shot_direction=list(memory[0x10e:0x113]),shot_state=list(memory[0x120:0x125]),
        shot_YX=[hex(u16(0x81a+2*i)) for i in range(5)],score=memory[0x20:0x24].hex())
lastf=0
for r in csv.DictReader((CAP/'guest_effect_events.csv').open()):
    f=int(r['frame']);a=int(r['address']);d=int(r['data']);m=int(r['mask'])
    if f!=lastf:
        if lastf in [878,879,880,881,900,990,1000,1100,1200,1273,1400,1600,1642,1643,1644,1645,1799]:samples.append(sample(lastf))
        lastf=f
    if r['area']!='work_write':continue
    for target in [a,a+1]:
        lane=0xff00 if target==a else 255
        if not m&lane:continue
        off=target-0x20000;v=(d>>8)&255 if target==a else d&255
        previous=memory[off];memory[off]=v
        if f>=879 and off in [0x104,0x10a,0x10b,0x126,0x127]:
            key=hex(target);item=stats.setdefault(key,dict(values=collections.Counter(),writers=collections.Counter(),changes=0))
            item['values'][v]+=1;item['writers'][hex(int(r['main_pc']))]+=1
            if v!=previous:
                item['changes']+=1
                if off in [0x126,0x127]:coord_changes.append(dict(frame=f,offset=hex(target),old=previous,new=v,PC=hex(int(r['main_pc']))))
        if f>=879 and (0x10e<=off<=0x112 or 0x120<=off<=0x124 or 0x81a<=off<=0x823):
            source_counts[hex(int(r['main_pc']))]+=1
            if v!=previous and len(shot_writes)<32:shot_writes.append(dict(frame=f,address=hex(target),old=previous,new=v,PC=hex(int(r['main_pc']))))
samples.append(sample(lastf))
for item in stats.values():item['values']=dict(item['values']);item['writers']=dict(item['writers'])
p=OUT/'analysis.json';p.write_text(json.dumps(dict(scope='Source-only completed official1800: no new game runtime',
    source_pins=[pin(rom),pin(tool),pin(CAP/'guest_effect_events.csv'),pin(REF/'terminal_import_manifest_v4.json'),pin(Path(__file__))],
    full_ROM_decode_actual_exit=0,bounded_regions=regions,relevant_ROM_calls_and_RAM_consumers=matches,
    actual_selected_state=samples,coordinate_and_mode_stats=stats,first32_shot_slot_changes=shot_writes,shot_writers=dict(source_counts),
    coordinate_change_count=len(coord_changes),first_last_coordinate_changes=coord_changes[:8]+coord_changes[-8:],
    limitations='RAM values reconstructed from actual CPU work-write taps; MCU direct shared writes are outside this stream. Actor/projectile consumers require disassembly before semantic labels. No whole-RAM exact claim.'),indent=2)+'\n')
print(json.dumps(dict(analysis=pin(p),bounded_disassembly_exits=[0]*5,ROM_matches=[x['line'] for x in matches],coordinate_and_mode_stats=stats,samples=samples[2:5]+samples[-4:],shot_writers=source_counts.most_common(15)),indent=2))
