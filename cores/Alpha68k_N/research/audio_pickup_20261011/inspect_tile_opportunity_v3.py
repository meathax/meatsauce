"""Prove actual tile pickup opportunities and source scope; never run the guest."""
from pathlib import Path
import hashlib,json,re
HERE=Path(__file__).resolve().parent;OLD=HERE.parents[1]
DEST=HERE/'source_tile_opportunity_v3';DEST.mkdir()
RUN=HERE/'corrected_reference_v2/output'
ROM=OLD/'roms/kyros/maincpu.bin';ASM=OLD/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm'
CORE=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
rom=ROM.read_bytes();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(ROM)=='6949ea5dc91dfced8c1afccbadee18c2e795ab38d8adbc3795f05a19b8f3b2b3'
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
snapshots=[]
for work in sorted(RUN.glob('*.work.bin')):
 sprite=work.with_name(work.name.replace('.work.bin','.sprites.bin'))
 b=work.read_bytes();s=sprite.read_bytes();cells=[]
 for offset in range(0x1002,0x1800,4):
  tile=int.from_bytes(s[offset:offset+2],'big')
  if 0x2340<=tile<0x2370:
   address=0x40000+offset
   candidates=[]
   for c0 in range(256):
    x=(((c0+0x20+b[0x112])&255)>>4)&15
    for c1 in range(256):
     y=((((c1+0x1c-(b[0x111]&15))&255)>>4)-(b[0x111]>>4))&15
     computed=((0x41000+((y*128-x*4)&0x7ff))|2)&~0x40
     if computed==address:candidates.append([c0,c1])
   playerptr=int.from_bytes(b[0x40c:0x40e],'big')
   playercoord=list(b[playerptr:playerptr+2]) if playerptr and playerptr<0xfff else None
   closest=min(candidates,key=lambda v:abs(v[0]-playercoord[0])+abs(v[1]-playercoord[1])) if candidates and playercoord else None
   cells.append({'address':address,'tile':tile,'source_branch':'b9d2→ba04 pickup53','matching_coordinate_count':len(candidates),'closest_player_coord':closest,'source_geometry_only_not_reachable_route':True})
  elif 0x2300<=tile<0x2400:
   pass
 all_special=[{'address':0x40000+offset,'tile':int.from_bytes(s[offset:offset+2],'big')} for offset in range(0x1002,0x1800,4) if 0x2300<=int.from_bytes(s[offset:offset+2],'big')<0x2400]
 ptr=int.from_bytes(b[0x40c:0x40e],'big')
 snapshots.append({'field':int(work.name.split('.')[0].split('_')[-1]),'work20100_2011f':b[0x100:0x120].hex(),'player_pointer':ptr,'player_coord':list(b[ptr:ptr+2]) if ptr and ptr<0xfff else None,'source_tile_pickup_opportunities':cells,'all_23xx_foreground':all_special,'work20c40_20c5b':b[0xc40:0xc5c].hex()})
ins=[]
for line in ASM.read_text().splitlines():
 m=re.match(r'([0-9a-f]{5}):\s+((?:[0-9a-f]{4}\s+)+)(.+)',line)
 if m:
  a=int(m[1],16)
  if 0xb902<=a<0xbb54 or 0x5292<=a<0x52e4 or a in (0x4b42,0x4ee8):
   op=bytes.fromhex(m[2]);assert rom[a:a+len(op)]==op
   ins.append({'pc':a,'opcode':op.hex(),'instruction':m[3].strip()})
table=[]
for i in range(16):table.append({'selector_high_nibble':i,'dispatch_address':int.from_bytes(rom[0xba90+i*2:0xba92+i*2],'big')})
plan=CORE/'plan.md';bugs=CORE/'mamebug.md'
coverage=[]
for path in (plan,bugs):
 for i,line in enumerate(path.read_text().splitlines(),1):
  if ('pickup' in line.lower() and ('B04' in line or 'P1 action' in line or '05959' in line or 'jump' in line)) or 'Exact PCM identity is not an acceptance claim' in line:
   coverage.append({'path':str(path),'line':i,'text':line})
result={'scope':'Source-only, actual retained foreground snapshots and pinned ROM; no new pilot/native execution','retained_tile_opportunities':snapshots,'actual_transform_dispatch':table,'source_instructions':ins,'coverage_contract':coverage,'required_semantic_gate':'B04 requires genuine pickup effect coverage; plan P5 action replay includes pickup. Qualified absence cannot close effect coverage. B03 concerns punch cleanup, release/death/reset and does not require ordinary item type20..25 specifically.','alternative_pickup_path':'b902 tests20911 flag, samples actualplayer5292 tile,2340<=tile<2370 dispatchb9d2. ba04 writes53 to2035f; subsequentscore10000 at20300/20370. This path clears4-byte record20c40..20c4b, not ordinary7-slot item.','ordinary_type24_25_producer':'ba66 reads active-player selection from20026 or2002a high nibble, tableba90 choosesbab0/baec. bab4 enumerates7 slots20420..204e0, skipsinactive/type11/byte9!=0, bad0 writes24/25 and clearscollisionflags+0a. It does not create a differentrecordbank.','generic_spawn_table_limit':'The prior256-entry10000 scan crossed the separate102f0 and10650 tables; apparent20..25 entries are not proven ordinaryspawn opportunities. Do not use source_opportunity_v1 table coincidences as route targets.','input_phase_limit':'Recorded first player type80/coord field294 does not prove controls were accepted then. Legal movement calibration from720 is actual; earlieractivationrequires genuine consumed-input/game-state evidence.','route_qualified':False,'next_action':'If an actual2340..236f tile is retained, derive shortest legal geometry approach and verify health/flags/20911 consumerconditions. Otherwise no shortestpickup route is proven by these3 snapshots. Further observation must be specifically authorized and source-informed, not automaticextension.'}
save(DEST/'findings.json',result)
files=[Path(__file__),DEST/'findings.json']
pins=[ROM,ASM,plan,bugs,HERE/'corrected_reference_v2/import_manifest.json']+list(RUN.glob('*.work.bin'))+list(RUN.glob('*.sprites.bin'))
save(DEST/'import_manifest.json',{'files':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in files],'source_pins':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in pins],'actual_exit_code':0,'source_only':True,'route_qualified':False})
print(json.dumps({'snapshots':snapshots,'transform_dispatch':table,'contract_rows':len(coverage),'source_instruction_rows':len(ins),'manifest_sha256':sha(DEST/'import_manifest.json'),'route_qualified':False}))
