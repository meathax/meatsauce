from pathlib import Path
import hashlib,json,re,difflib,subprocess,itertools,shutil
OLD=Path('D:/Arcade/AI/aCORES/Alpha68k N')
CAN=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
PRIV=OLD/'research/stingray_combined_stage/next_coupled_scope_v2'
P2=OLD/'research/stingray_game_divergence_20261011/p2_candidate_qualification_v7'
ROOT=OLD/'research/final_source_join_20261011'
CAND=ROOT/'candidate'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,s):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s,encoding='utf-8',newline='\n')
def js(p,o):write(p,json.dumps(o,indent=2)+'\n')
def tokens(s):return re.findall(r'\w+|[^\s]',re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S))
def once(s,a,b):assert s.count(a)==1,(a,s.count(a));return s.replace(a,b)
assert not CAND.exists(), 'Frozen candidate already exists; do not silently mutate.'
assert sha(CAN/'rtl/alpha68kn_board.sv')=='ba9357acc26ac391c71a01b166e96c7879fed726274eb13c60a25a494093f8fc'
closure=json.loads((PRIV/'source_closure.json').read_text())
sources=closure['source_files'];assert len(sources)==75
baselines={};changed=[]
for item in sources:
 src=Path(item['path']);assert sha(src)==item['combined_sha256']
 rel=src.relative_to(PRIV/'source')
 base=CAN/rel
 selected=base if base.exists() else src
 dest=CAND/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(selected,dest)
 baselines[str(rel).replace('\\','/')]={'canonical_path':str(base) if base.exists() else None,'canonical_sha256':sha(base) if base.exists() else None,'joined_path':str(src),'joined_sha256':sha(src)}
# Integrate exactly the private P6 board while preserving both production RAM fixes.
board=(PRIV/'source/rtl/alpha68kn_board.sv').read_text()
old="sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;"
assert old in board, '15-bit production sound loader lost upstream'
reader="            2:debug_rom_data<={sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};"
assert '`ifdef VERILATOR\n'+reader not in board
board=once(board,reader,'`ifdef VERILATOR\n'+reader+'\n`endif')
write(CAND/'rtl/alpha68kn_board.sv',board)
for rel,src in [('rtl/alpha68kn_mcu.sv',P2/'candidate/alpha68kn_mcu.sv'),('rtl/vendor/t48/t48_core.v',P2/'candidate/t48_core.v'),('rtl/vendor/jt12/jt49/hdl/jt49_div.v',PRIV/'source/rtl/vendor/jt12/jt49/hdl/jt49_div.v')]:
 shutil.copyfile(src,CAND/rel)
assert sha(CAND/'rtl/vendor/t48/t48_core.v')=='2ad3acf392e1deec18d5d7f2c8d878b33b00073c55a7c032cd0155dfac46bf6d'
assert sha(CAND/'rtl/alpha68kn_mcu.sv')=='26614f565524e7dc136c3c898eb044807d22d2c6ce473dcc64d7f54258a97120'
# Add the two already staged dependencies omitted from canonical synthesis assignments.
qip=(CAN/'files.qip').read_text();assert 'rtl/alpha68kn_mcu.sv' not in qip and 'rtl/vendor/t48/t48_core.v' not in qip
qip+='set_global_assignment -name SYSTEMVERILOG_FILE rtl/alpha68kn_mcu.sv\nset_global_assignment -name VERILOG_FILE rtl/vendor/t48/t48_core.v\n'
write(CAND/'files.qip',qip)
for rel in ['Alpha68k_N.sv','Alpha68k_N.sdc','rtl/alpha68kn_audio.qip','rtl/pll.qip']:
 shutil.copyfile(CAN/rel,CAND/rel)
for base in [CAN/'rtl/vendor/t48',CAN/'rtl/vendor/jt12',CAN/'rtl/vendor/fx68k']:
 for src in base.rglob('*'):
  if src.is_file() and (src.name.lower().startswith(('license','copying','source','provenance')) or src.suffix in ['.mem','.hex','.qip']):
   dest=CAND/src.relative_to(CAN);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
for rel in ['docs/STATE.md','docs/HACKS.md','donormap.md']:
 shutil.copyfile(CAN/rel,CAND/rel) if (CAND/rel).parent.exists() else None
shutil.copyfile(CAN/'donormap.md',CAND/'donormap.md')
# Metadata explicitly remains a proposed source inventory, not evidence of production acceptance.
prov=json.loads((P2/'SOURCE.proposed.json').read_text());prov['scope']='Staged conditional final-source join; not production integration or gameplay/timing acceptance.'
prov['sha256']=sha(CAND/'rtl/vendor/t48/t48_core.v');prov['bytes']=(CAND/'rtl/vendor/t48/t48_core.v').stat().st_size
js(CAND/'rtl/vendor/t48/SOURCE.json',prov)
ssg=(CAND/'rtl/vendor/jt12/jt49/hdl/jt49_div.v')
js(CAND/'rtl/vendor/jt12/SSG_PERIOD_ZERO_FORK.json',{'upstream':'https://github.com/jotego/jt12','jt12_revision':'dc9be7c1ff75 (full pin in donors.lock.json)','upstream_notice':'Original JT49 notices remain in the unchanged dependency closure.','path':'rtl/vendor/jt12/jt49/hdl/jt49_div.v','baseline_sha256':sha(CAN/'rtl/vendor/jt12/jt49/hdl/jt49_div.v'),'candidate_sha256':sha(ssg),'adaptation':'Remove forced constant output for period zero; zero follows the same toggle cadence as period one.','scope':'Shared sound behavior change for all profiles; finite prior private replay evidence requires final image binding.'})
write(CAND/'docs/STATE.md', '''# Proposed integrated state inventory — 2026-10-11

This staged candidate retains the real 68000/Z80, SDRAM graphics pipeline, PROM decode, AY/YM2203/DAC and framework interface. It is not a production acceptance receipt. Diagnostic state is not a shipped savestate feature.

The board uses one 48 MHz game clock with enables. Kyros/Japan retain their existing CPU enable, memory, IRQ2, MCU compatibility and bus acceptance paths. Profile2 adds a rational 3,579,545 Hz Z80 enable and genuine T48 firmware MCU, rational MCU clock enables, low-byte shared RAM write arbitration, firmware IRQ2, flip and accepted-transaction HALT drain. The RAM address/data port serves MCU replies before conflicting main-CPU work accesses; hiscore borrow waits for the registered MCU write drain.

P2 transaction data comes from the donor's architectural latch at the already delayed enabled write observation. Physical P2 output remains unchanged. Sound ROM loader word address remains explicitly 15 bits; its extra diagnostic read exists only in Verilator. Registered CPU read and byte-lane timing remain unchanged.

Production ROM admission remains profiles0/1. A separate conditional patch enables profile2 only after the parent's genuine181 gameplay and wrapper gates. This candidate has no new build, replay, fit, timing, hardware or release qualification. Complete current-source acceptance and constraints remain parent-owned.
''')
write(CAND/'docs/HACKS.md', (CAN/'docs/HACKS.md').read_text()+'''
## Proposed Stingray integration boundary

The proposed profile2 path executes the authentic 1024-byte 8748 firmware rather than the Kyros compatibility callbacks. The T48 port observation fork exports architectural P2 write data because delayed physical pins lose the ready transition. Prior genuine-firmware component evidence does not establish current whole-game acceptance. MCU oscillator frequency, original PCB timing, analog audio and undocumented hardware remain explicit fidelity limits; no guessed PCB correction is claimed.

The fx68k HALT pin is a single-step input. The board drains an accepted AS transaction, then holds its existing phase enables at AS-high while the MCU owns HALT. The physical/MAME timing equivalence of this boundary remains subject to coupled CPU evidence. No synthetic CPU/game action is added.

The shared YM2203 SSG period-zero correction changes all profiles and requires final-source replay binding. It is not covered by the profile0/1 board-cone equivalence claim.
''')
write(CAND/'docs/MAME_KLUDGES.md','''# Proposed MAME compatibility and limits — 2026-10-11

Kyros/Japan use the existing MAME0.289 compatibility MCU; original undumped/partial Alpha8511 firmware is not fabricated. Stingray uses real T48 firmware and the existing pinned profile constants. Uncertain MCU clock and physical fidelity limits remain open as catalogued in mamebug.md. No new MAME bug closure is claimed here.

Completed PNG texture/display RGB is the visible-frame oracle; post-swap diagnostic drawing-buffer RGB is a separate artifact. No mismatching pixel or RAM data is masked. Final CPU-consumed input phase and exact gameplay gates remain parent-owned; earlier callback-only phase inference must not be used as acceptance evidence.
''')
write(CAND/'donormap.md',(CAN/'donormap.md').read_text()+'''
## Proposed final-source join — 2026-10-11

This candidate adds `rtl/alpha68kn_mcu.sv` and `rtl/vendor/t48/t48_core.v` to files.qip. The donor remains JTFRAME revision548b87b32a1b528a16cb41f689accb179e85d1a8 / Arnim Laeuger T48. The fork retains enabled BUS/P2 decoder observations and additionally exports the architectural P2 latch; SOURCE.json and original LICENSE.upstream travel with it. No donor CPU/timer clock logic is changed by the P2 export.

The board profile2 path integrates real firmware ROM, command byte, coin T0/T1, shared reply, firmware IRQ2, flip, rational enables and accepted-AS HALT drain. Kyros/Japan preserve their existing board functional cone. The shared nested JT49 divider removes period-zero constant output; its fork manifest binds baseline and proposed hashes. This shared sound correction applies to all profiles and needs current-source acceptance.

These are staged proposals. The existing complete161-source fit does not include the new MCU/T48 assignments or changed board/divider/donor, and cannot qualify this image. Pinned sys remains external and unchanged. Profile2 production admission is a separate conditional patch, to apply only after genuine181 gameplay and realHPS wrapper qualification, followed by complete current-source timing/resource acceptance.
''')
top=(CAN/'Alpha68k_N.sv').read_text();enabled=once(top,'board_load_data[15:8]<=1','board_load_data[15:8]<=2')
write(ROOT/'conditional_profile2_enable.patch',''.join(difflib.unified_diff(top.splitlines(True),enabled.splitlines(True),fromfile='a/Alpha68k_N.sv',tofile='b/Alpha68k_N.sv')))
# Freeze baseline pointers and exact diffs; no production writes.
paths=sorted(p for p in CAND.rglob('*') if p.is_file())
for p in paths:
 rel=p.relative_to(CAND).as_posix();base=CAN/rel
 if not base.exists() or p.read_bytes()!=base.read_bytes():
  changed.append({'path':rel,'baseline_path':str(base) if base.exists() else None,'baseline_sha256':sha(base) if base.exists() else None,'candidate_sha256':sha(p),'bytes':p.stat().st_size})
diff=''.join(''.join(difflib.unified_diff((CAN/x['path']).read_text().splitlines(True) if (CAN/x['path']).exists() else [],(CAND/x['path']).read_text().splitlines(True),fromfile='a/'+x['path'],tofile='b/'+x['path'])) for x in changed)
write(ROOT/'candidate.patch',diff)
js(ROOT/'source_baselines.json',baselines)
js(ROOT/'changed_files.json',changed)
js(ROOT/'preparation.json',{'scope':'Prepare only; root integrates centrally after actual gates. No native build/test/Quartus/RBF/hardware.','canonical_head':subprocess.run(['git','-C',str(CAN),'rev-parse','HEAD'],capture_output=True,text=True,check=True).stdout.strip(),'private_source_closure':{'path':str(PRIV/'source_closure.json'),'sha256':sha(PRIV/'source_closure.json'),'sources':len(sources)},'p2_manifest':{'path':str(P2/'import_manifest.json'),'sha256':sha(P2/'import_manifest.json')},'board_sound_fix_sha256':sha(CAN/'rtl/alpha68kn_board.sv'),'changed_files':changed,'profile2_admission':'Unchanged <=1; conditional patch separate.','sys':'No sys source copied or changed; use pinned canonical framework.','fit_source_gap':'Adds two assignments MCU/T48; changes board, nested SSG divider and T48/MCU contents. Existing 161-source fitted image is not acceptance for this graph.'})
print(json.dumps({'candidate':str(CAND),'source_files':len(sources),'changed_files':[(x['path'],x['candidate_sha256']) for x in changed],'new_assignments':['rtl/alpha68kn_mcu.sv','rtl/vendor/t48/t48_core.v'],'preparation_sha256':sha(ROOT/'preparation.json')},indent=2))
