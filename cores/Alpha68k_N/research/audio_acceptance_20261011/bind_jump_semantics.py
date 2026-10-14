from pathlib import Path
import csv,hashlib,json,re
R=Path(r'D:\Arcade\AI\aCORES\Alpha68k N');O=Path(__file__).resolve().parent
N=R/'sim/captures/rtl/kyros_combat_hud3301';M=R/'sim/captures/kyros/combat3600_clocked'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
cache=json.loads((R/'research/kyros_rom_disassembly_candidates.json').read_text())
rp=R/'roms/kyros/maincpu.bin';rom=rp.read_bytes();ap=R/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm'
assert sha(rp)==cache['rom_sha256'] and sha(ap)==cache['disassembly_sha256']
instructions={}
for s in ap.read_text().splitlines():
    m=re.match(r'^([0-9a-f]{5}): ((?:[0-9a-f]{4} ?)+)\s+(.+)$',s)
    if m:instructions[int(m[1],16)]=(bytes.fromhex(m[2]),m[3].strip())
selected=[0x4ae,0x4946,0x494c,0x4968,0x49ac,0x49b2,0x5b22,0x5b26,0x5b28,0x5b48,0x5bec,0x5bf8,0x5c0a,0x5c10,0x5c1c,0x5c22,0x5c24]
instruction_pins=[]
for pc in selected:
    op,text=instructions[pc];assert rom[pc:pc+len(op)]==op
    instruction_pins.append({'pc_hex':hex(pc),'opcode_hex':op.hex(),'instruction':text})
native_latches=[]
with (N/'epoch_events.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        if int(x['iack']) or int(x['rw']) or int(x['address'])!=0xe0000:continue
        native_latches.append({'frame':int(x['frame']),'tick':int(x['tick']),'command':(int(x['data_out'])>>8)&255})
mame_latches=[];ram_events=[];areas=set()
with (M/'events.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        frame=int(x['frame'])
        if frame>1110:break
        if x['area']=='sound_latch_write':mame_latches.append({'frame':frame,'command':(int(x['data'])>>8)&255})
        if int(x['address']) in (0x20408,0x20402,0x20404,0x2035e,0x2040a) and 830<=frame<=1110:
            ram_events.append(x);areas.add(x['area'])
snapshots=[]
for frame in [840,870,900,1020,1050,1080]:
    p=N/f'frame_{frame:06d}.work.bin';b=p.read_bytes()
    snapshots.append({'frame':frame,'sha256':sha(p),'player_state_20408':b[0x408],
       'player_flags_20403':b[0x403],'player_motion_flags_2040a':b[0x40a],
       'player_position1c_2041c':b[0x41c], 'input_20012':b[0x12], 'new_action_20907':b[0x907]})
inputs=[]
with (M/'inputs.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        if int(x['mask'])==32 and int(x['frame']) in (840,844,1020,1024):inputs.append(x)
r={'scope':'Pinned ROM input-to-jump state/effect path with actual accepted mainCPU sound commands and retained native player RAM. No old raw-RGB semantics or physical audio claim.',
   'rom_sha256':cache['rom_sha256'],'disassembly_sha256':cache['disassembly_sha256'],'instruction_pins':instruction_pins,
   'actual_native_latch_events':[x for x in native_latches if 830<=x['frame']<=1110],
   'retained_reference_latch_events':[x for x in mame_latches if 830<=x['frame']<=1110],
   'native_snapshots':snapshots,'reference_RAM_event_areas':sorted(areas),'reference_RAM_events':ram_events,
   'reference_jump_inputs':inputs,'full_P5_pass':False}
(O/'jump_semantic_binding_stage.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({k:v for k,v in r.items() if k not in ('instruction_pins','reference_RAM_events')}))
print('RAM_EVENT_COUNT',len(ram_events),'RAM_FIRST',json.dumps(ram_events[:8]))
