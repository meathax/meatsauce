"""Bounded loaded-ROM disassembly and source-backed retired stack classification."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'paired601'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
report=json.loads((HERE/'compact_RAM_writer_report.json').read_text())
assert report['original_invariants_pass']
tool=ROOT/'tools/mame0289/unidasm.exe'
rom=ROOT/'roms/kyrosj/maincpu.bin'
proof=Path(r'D:\Arcade\AI\mame289\src\tools\unidasm.cpp')
prior=Path(__file__).resolve().parent/'disassemble_stack_sources601.py'
regions=[]
for base,count in [(0x500,64),(0x580,64),(0x1ff0,32)]:
    command=[str(tool),str(rom),'-arch','m68000','-skip',str(base),'-count',str(count),'-basepc',f'{base:x}']
    child=subprocess.run(command,capture_output=True,text=True)
    path=HERE/f'ROM_{base:06x}.v3.asm.txt';assert not path.exists()
    path.write_text(child.stdout+('\nSTDERR:\n'+child.stderr if child.stderr else ''))
    regions.append(dict(base=base,count=count,command=command,actual_exit=child.returncode,output=pin(path)))
assert all(x['actual_exit']==0 for x in regions),regions
writer_kind={
    (240,'0x020f7e'):'Both sides: IRQ2 MOVEM.L register spill; saved A0 low word. Restored with MOVEM.L in field217.',
    (240,'0x020f9c'):'Different historical uses: native field218 MOVEM.L saved D0 high word; MAME field217 exception return PC low word. Native restore / MAME RTE consume and retire them before checkpoint240.',
    (360,'0x020fe2'):'Both sides: field360 exception return PC low word. RTE at loadedROM000510 consumes it in field360 before checkpoint.',
    (600,'0x020f5e'):'Both sides: IRQ2 field508 MOVEM.L register spill; saved D0 low word. Restored with MOVEM.L in field508.',
    (600,'0x020f6a'):'Both sides: IRQ2 field581 MOVEM.L register spill; saved D0 low word. Restored with MOVEM.L in field581.',
    (600,'0x020fa4'):'Both sides: field581 saved exception SR; native2100/MAME2104. RTE at loadedROM000532 consumes this frame in field581.',
    (600,'0x020fa8'):'Both sides: field581 exception return PC low word; native058a/MAME0590. RTE at loadedROM000532 consumes it in field581.'}
rows=[]
for x in report['words']:
    assert x['both_words_below_present_A7'] and x['A7_selection_proven']
    assert all(l['last_lane_writes_produce_retained_different_bytes'] and l['native_true_lane_commit_has_one_accepted_transaction'] for l in x['lanes'])
    assert all(l['native_raw_reads_after_lane_write']>=1 and l['MAME_qualified_guest_reads_after_lane_write']>=1 for l in x['lanes'])
    native_readers=[r for l in x['lanes'] for r in l['native_recent_upperRAM_reads']]
    MAME_readers=[r for l in x['lanes'] for r in l['MAME_last_guest_reads']]
    rows.append(dict(field=x['field'],word=x['address_hex'],values=x['words'],
        classification='Retired architectural stack content at this qualified snapshot, with differing historical interrupt/register-save contents.',
        source_use=writer_kind[x['field'],x['address_hex']],
        native_snapshot=x['native_snapshot'],MAME_snapshot=x['MAME_snapshot'],
        native_last_readers=native_readers,MAME_last_guest_readers=MAME_readers,
        preserved_strict_work_difference=True))
classification=dict(scope='Source-backed finite checkpoint classification. No ignored bytes, RTL fix, clock shift or additional replay.',
    strict_work_gate=False,actual_native_exit=0,actual_MAME_exit=0,actual_strict_verifier_exit=1,
    decisive='All seven words/eight different bytes were physically written as stack spills/exception frames, read by corresponding restores/RTE, and are below identical current supervisor A7 at their later snapshots. Original full graphics/strip/RAM/audio/input/protocol invariants passed.',
    cause='Different historical interrupt instruction points/register-save depths leave different retired stack bytes; checkpoint differences do not identify a live game-RAM object.',
    not_proven='Exact cause of the native/MAME cycle or interrupt-phase difference versus a physical PCB is not established. No CPU/IRQ timing correction is justified by this classification alone. It does not transfer to Stingray without its own A7/writer proof.',
    observations=rows,ROM_disassemblies=regions,
    source_pins=[pin(tool),pin(rom),pin(HERE/'compact_RAM_writer_report.json'),pin(HERE/'snapshot_read_annotation.json'),
        pin(HERE/'verification.json'),pin(Path(__file__)),pin(Path(r'D:\Arcade\AI\mame289\src\devices\cpu\m68000\m68000.lst'))])
classification['prior_consumer_failure']={
    'failure':'Original decimal base-PC strings were interpreted as hexadecimal; printed absolute addresses were wrong. Instruction bytes and strict RAM qualification were unchanged.',
    'fix':'Supply base-PC as a hexadecimal string. Preserve original outputs; no guest replay or RTL mutation.',
    'parser_source':pin(proof),'parser_source_line':1177,
    'prior_artifacts':[pin(prior),pin(HERE/'retired_stack_classification.json')]+[pin(HERE/f'ROM_{base:06x}.asm.txt') for base in [0x500,0x580,0x1ff0]]}
for entry in regions:
    actual=(HERE/f"ROM_{entry['base']:06x}.v3.asm.txt").read_text()
    first=actual.splitlines()[0].split(':',1)[0].strip()
    assert int(first,16)==entry['base'],(first,entry['base'])
classification['basePC_presentation_verified']=True
p=HERE/'retired_stack_classification_v3.json';assert not p.exists();p.write_text(json.dumps(classification,indent=2)+'\n')
print(json.dumps(dict(classification=pin(p),all7words_below_both_current_A7=True,all7words_physical_lane_writers_and_later_guest_reads=True,
    strict_work_gate=False,disassembly_actual_exits=[x['actual_exit'] for x in regions]),indent=2))


