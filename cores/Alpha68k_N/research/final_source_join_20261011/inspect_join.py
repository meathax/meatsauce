from pathlib import Path
import json, hashlib, subprocess, difflib
OLD=Path('D:/Arcade/AI/aCORES/Alpha68k N')
CAN=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
PRIVATE=OLD/'research/stingray_combined_stage/next_coupled_scope_v2'
P2=OLD/'research/stingray_game_divergence_20261011/p2_candidate_qualification_v7'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
for root in [PRIVATE,P2]:
 print('ROOT',root)
 for p in sorted(root.rglob('*')):
  if p.is_file() and ('build' not in p.parts) and (p.name in ['sources.json','source_pins.json','SOURCE.json','SOURCE.proposed.json','PROPOSAL.md','files.qip','prepare.json','preparation.json'] or p.suffix in ['.sv','.v','.qip']):
   print(str(p.relative_to(root)),p.stat().st_size,sha(p))
for rel in ['AGENTS.md','docs/STATE.md','docs/HACKS.md','docs/MAME_KLUDGES.md','rtl/vendor/t48/SOURCE.json','rtl/vendor/jt49/SOURCE.json','files.qip']:
 p=CAN/rel
 if p.exists(): print('FILE',rel,'\n',p.read_text(encoding='utf-8')[:14000])
for rel in ['rtl/alpha68kn_board.sv','rtl/alpha68kn_mcu.sv','rtl/vendor/jt12/hdl/jt03.v']:
 p=CAN/rel
 if p.exists(): print('BASELINE',rel,sha(p))
print('LESSONS',subprocess.run(['D:/vibes/fpga/toolchains/msys64/ucrt64/bin/python.exe','-X','utf8','C:/Users/meath/codex-tools/maintenance/lessons_index.py','search','sound ROM inference T48'],capture_output=True,text=True).stdout[:5000])
