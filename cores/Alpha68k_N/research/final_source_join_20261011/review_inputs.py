exec(open('D:/Arcade/AI/aCORES/Alpha68k N/research/final_source_join_20261011/inspect_join.py',encoding='utf-8').read().split('for root in [PRIVATE,P2]:')[0])
STAGE=OLD/'research/final_source_join_20261011'
for rel in ['rtl/alpha68kn_board.sv','rtl/alpha68kn_mcu.sv','rtl/vendor/jt12/jt49/hdl/jt49_div.v','rtl/alpha68kn_system.sv']:
 a=(CAN/rel).read_text(); b=(PRIVATE/'source'/rel).read_text()
 d=''.join(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='canonical/'+rel,tofile='joined/'+rel))
 print('DIFF',rel,d)
for p in [P2/'SOURCE.proposed.json',CAN/'rtl/vendor/jt12/SOURCE.json',CAN/'rtl/vendor/t48/LICENSE.upstream',CAN/'docs/MAME_KLUDGES.md']:
 if p.exists(): print('DOC',p,p.read_text(encoding='utf-8')[:9000])
print('QIP', (CAN/'files.qip').read_text())
print('STAGE_JSON',[(str(p.relative_to(PRIVATE)),p.stat().st_size) for p in PRIVATE.glob('*.json')])
print('PROGRESS_TAIL','\n'.join((CAN/'progress.md').read_text(encoding='utf-8').splitlines()[-85:])[:12000])
