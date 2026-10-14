from pathlib import Path
import csv,json,hashlib,collections
P=Path(__file__).resolve().parent;V=P/'opportunity_route_v16';R=V/'output';D=P/'route_stall_v17';D.mkdir()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(V/'import_manifest.json')=='cd729c252e58aa10580f1e74cf6b1d4aea52ecc39547c712287e129aee5961a6'
data={};small=[]
for name in ['movement_terrain_reads.csv','work_ancestry.csv','consumed_inputs.csv','route_steps.csv','actors.csv']:
 rows=collections.deque(maxlen=64);counts=collections.Counter()
 with (R/name).open(newline='') as f:
  for r in csv.DictReader(f):
   if int(r['frame'])<1255:continue
   if name=='movement_terrain_reads.csv':
    if int(r['a4'])!=0x20400 or not 0x515a<=int(r['pc'])<=0x5204:continue
    counts[(r['address'],r['data'],r['pc'])]+=1
   elif name=='work_ancestry.csv':
    if int(r['a4'])!=0x20400 or int(r['address']) not in [0x20340,0x20342,0x20344,0x20346,0x20348,0x2034e,0x2090e,0x2090f,0x20402,0x20404,0x20408,0x2040a]:continue
    counts[(r['address'],r['data'],r['mask'],r['pc'])]+=1
   elif name=='consumed_inputs.csv':counts[(r['data'],r['pc'])]+=1
   elif name=='actors.csv' and int(r['base'])!=0x20400:continue
   rows.append(r)
 data[name]={'count_groups':[{'values':list(k),'count':v} for k,v in counts.items()],'last64_rows':list(rows)}
b=(R/'frame_001303.work.bin').read_bytes();data['terminal_work']={'20320_2032f':b[0x320:0x330].hex(),'20340_2034f':b[0x340:0x350].hex(),'20900_2095f':b[0x900:0x960].hex(),'20400_player':b[0x400:0x420].hex()}
asm=(P.parents[1]/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm').read_text().splitlines()
data['responsible_source']=[s for s in asm if len(s)>6 and s[5]==':' and (0x51a0<=int(s[:5],16)<=0x5204 or 0x4c12<=int(s[:5],16)<=0x4cc0)]
data['reference_manifest_sha256']=sha(V/'import_manifest.json');data['limits']=['A4==20400 is mandatory for player evidence; terminal global raw tile can have been overwritten by another actor','No new runtime or source edits; finite no-motion failure retained','Only last64 decisive rows retained here; full qualified CSV remains pinned reference']
(D/'findings.json').write_text(json.dumps(data,indent=2)+'\n')
(D/'import_manifest.json').write_text(json.dumps({'scope':'source-only qualified actual player stall','files':[{'path':str(x),'sha256':sha(x)} for x in [D/'findings.json',Path(__file__)]],'reference_manifest_sha256':data['reference_manifest_sha256'],'new_runtime':False},indent=2)+'\n')
print(json.dumps({'manifest':str(D/'import_manifest.json'),'sha256':sha(D/'import_manifest.json'),'player_raw_reads':data['movement_terrain_reads.csv']['count_groups'],'player_work_groups':data['work_ancestry.csv']['count_groups'],'consumed_inputs':data['consumed_inputs.csv']['count_groups'],'terminal_work':data['terminal_work'],'source':data['responsible_source']}))
