"""Fix only unidasm's hex base-PC consumer; freeze the terminal diagnostic supplement."""
from pathlib import Path
import hashlib,json,subprocess,sys
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
STAGE=Path(__file__).resolve().parent
HERE=STAGE/'paired601'
def pin(p):
    return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
prior=STAGE/'disassemble_stack_sources601.py'
source=prior.read_text()
assert source.count("'-basepc',str(base)")==1
source=source.replace("'-basepc',str(base)","'-basepc',f'{base:x}'")
source=source.replace('.asm.txt','.v2.asm.txt').replace('retired_stack_classification.json','retired_stack_classification_v2.json')
proof=Path(r'D:\Arcade\AI\mame289\src\tools\unidasm.cpp')
proof_lines=proof.read_text().splitlines()
assert 'parse_number(curarg, std::hex, &opts->basepc)' in proof_lines[1176]
insertion="""classification['prior_consumer_failure']={
    'failure':'Original decimal base-PC strings were interpreted as hexadecimal; printed absolute addresses were wrong. Instruction bytes and strict RAM qualification were unchanged.',
    'fix':'Supply base-PC as a hexadecimal string. Preserve original outputs; no guest replay or RTL mutation.',
    'parser_source':pin(proof),'parser_source_line':1177,
    'prior_artifacts':[pin(prior),pin(HERE/'retired_stack_classification.json')]+[pin(HERE/f'ROM_{base:06x}.asm.txt') for base in [0x500,0x580,0x1ff0]]}
for entry in regions:
    actual=(HERE/f"ROM_{entry['base']:06x}.v2.asm.txt").read_text()
    first=actual.splitlines()[0].split(':',1)[0].strip()
    assert int(first,16)==entry['base'],(first,entry['base'])
classification['basePC_presentation_verified']=True
"""
source=source.replace("p=HERE/'retired_stack_classification_v2.json'",insertion+"p=HERE/'retired_stack_classification_v2.json'")
# Suppress bulky assembly printing; outputs remain independently pinned.
source=source.replace("print((HERE/'ROM_000500.v2.asm.txt').read_text())",'').replace("print((HERE/'ROM_001ff0.v2.asm.txt').read_text())",'')
v2=STAGE/'disassemble_stack_sources601_v2.py'
assert not v2.exists()
v2.write_text(source)
child=subprocess.run([sys.executable,str(v2)],capture_output=True,text=True)
log=HERE/'retired_stack_classification_v2.log'
log.write_text(child.stdout+child.stderr)
receipt=HERE/'retired_stack_classification_v2_exit.json'
receipt.write_text(json.dumps(dict(command=[sys.executable,str(v2)],actual_exit=child.returncode,source=pin(v2),log=pin(log)),indent=2)+'\n')
assert child.returncode==0,child.stdout+child.stderr
classification=json.loads((HERE/'retired_stack_classification_v2.json').read_text())
assert classification['strict_work_gate'] is False and classification['actual_strict_verifier_exit']==1
assert len(classification['observations'])==7 and classification['basePC_presentation_verified']
asm=(HERE/'ROM_000500.v2.asm.txt').read_text().lower()
assert all(any(int(line.split(':',1)[0],16)==addr for line in asm.splitlines() if ':' in line) for addr in [0x500,0x512,0x52e,0x532])
asm=(HERE/'ROM_001ff0.v2.asm.txt').read_text().lower()
assert any(int(line.split(':',1)[0],16)==0x1ffa for line in asm.splitlines() if ':' in line)
files=[STAGE/'freeze_stack_classification_v2.py',prior,v2,proof,
    HERE/'terminal_import_manifest.json',HERE/'verification.json',HERE/'verification_exit.json',
    HERE/'snapshot_read_annotation.json',HERE/'compact_RAM_writer_report.json',
    HERE/'retired_stack_classification.json',HERE/'retired_stack_classification_v2.json',receipt,log]
files += [HERE/f'ROM_{base:06x}{suffix}.asm.txt' for base in [0x500,0x580,0x1ff0] for suffix in ['', '.v2']]
manifest=dict(scope='Japan paired601 finite retired-stack diagnosis; original strict qualification failure preserved',
    actual_native_exit=0,actual_MAME_exit=0,actual_strict_verifier_exit=1,strict_verifier_checks='14/15',strict_work_gate=False,
    native_fields=601,MAME_fields=601,graphics_exact=6,strip_exact=6,work_exact=3,work_different_fields=[240,360,600],
    residual_bytes=8,residual_words=7,observer_consumer_v2_actual_exit=0,
    source_and_runtime_recovery='terminal_import_manifest.json',
    conclusion='All seven words are below the active supervisor A7 at the checkpoint, have physical last-lane-write proof, and were consumed by MOVEM restores or RTE before it. They are retired stack contents at these specific checkpoints.',
    limitation='Physical PCB IRQ instruction phase and complete live-state equivalence are not established. No timing correction, RAM waiver, acceptance loosening, or transfer to Stingray is justified.',
    pins=[pin(p) for p in files])
out=HERE/'stack_diagnosis_import_manifest_v2.json'
assert not out.exists()
out.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(import_manifest=pin(out),classification=pin(HERE/'retired_stack_classification_v2.json'),actual_consumer_exit=0,strict_work_gate=False),indent=2))
