from pathlib import Path
import hashlib,json,re
R=Path(r'D:\Arcade\AI\aCORES\Alpha68k N');O=Path(__file__).resolve().parent
p=R/'research/kyros_rom_disassembly_candidates.json';pins=json.loads(p.read_text())
rom=(R/'roms/kyros/maincpu.bin').read_bytes();ap=R/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm';raw=ap.read_bytes()
assert hashlib.sha256(rom).hexdigest()==pins['rom_sha256']
assert hashlib.sha256(raw).hexdigest()==pins['disassembly_sha256']
ins=[]
for line in raw.decode().splitlines():
    m=re.match(r'^([0-9a-f]{5}): ((?:[0-9a-f]{4} ?)+)\s+(.+)$',line)
    if not m:continue
    pc=int(m[1],16);op=bytes.fromhex(m[2]);assert rom[pc:pc+len(op)]==op
    ins.append({'pc':pc,'hex':hex(pc),'instruction':m[3].strip(),'opcode':op.hex()})
contexts={}
for pc,pre,post in [(0x2cc0,0,34),(0x6f66,0,40),(0x781e,0,30)]:
    i=next(i for i,x in enumerate(ins) if x['pc']==pc)
    contexts[hex(pc)]=ins[max(0,i-pre):i+post+1]
refs=[x for x in ins if re.search(r'move.b.*#\$58.*\(\$35f,A6\)|move.b.*#\$.*\(\$346,A6\)',x['instruction'])]
snapshots=[]
for n in ['sim/captures/rtl/kyros_combat_hud3301','sim/captures/kyros/combat3600_clocked']:
    for f in sorted((R/n).glob('frame_*.work.bin')):
        frame=int(f.name[6:12])
        if not 780<=frame<=1140:continue
        b=f.read_bytes();snapshots.append({'namespace':n,'frame':frame,'player400_420_hex':b[0x400:0x420].hex(),'sha256':hashlib.sha256(b).hexdigest()})
r={'scope':'Pinned actual ROM opcode contexts and observed player RAM bytes; no action semantics inferred yet.','rom_sha256':pins['rom_sha256'],'disassembly_sha256':pins['disassembly_sha256'],'contexts':contexts,'refs':refs,'snapshots':snapshots}
(O/'semantic_rom_inspection_v6.json').write_text(json.dumps(r,indent=2)+'\n')
for k,xs in contexts.items():
    print('CONTEXT',k)
    for x in xs:print(x['hex'],x['instruction'])
print('PRODUCER_COUNT',len(refs))
print('SNAPSHOT_COUNT',len(snapshots))
