"""Freeze actual complete baseline overlay; change only case2 and absolute root rebases."""
from pathlib import Path
import hashlib,json,shutil,re
base=Path(__file__).resolve().parent
out=base/'case2_full_map'
meta=json.loads((out/'prepared.json').read_text())
launch=json.loads((base/'complete_overlay_launch.json').read_text(encoding='utf-8-sig'))
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
prior=base.parent/'board15_complete_check'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
key=hashlib.sha256((str(prior/'Alpha68k_N.qpf').lower()+':Alpha68k_N').encode()).hexdigest()[:20]
actual=Path(r'C:\Users\meath\QuartusFast\cache')/key/'dev-fast-check'
assert actual.exists(),str(actual)
qsf=(actual/'Alpha68k_N.qsf').read_text()
assert 'PRE_FLOW_SCRIPT_FILE' not in qsf
def assignment(key):
    matches=re.findall(r'^set_global_assignment -name ["{]?'+key+r'["}]?\s+(.+)$',qsf,re.M)
    assert matches,(key,'assignment missing')
    return matches[-1].strip().strip('"{}')
baseline_rbf_setting=assignment('GENERATE_RBF_FILE')
assert baseline_rbf_setting in ('ON','OFF'),baseline_rbf_setting
for k,v in meta['baseline_recorded_settings'].items(): assert assignment(k)==str(v),(k,assignment(k),v)
source_root=out/'source'
source_root.mkdir(exist_ok=True)
for name,digest in launch['canonical_source_pins'].items():
    src=canonical/name
    assert sha(src)==digest,name
    dst=source_root/name
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(src,dst)
    assert sha(dst)==digest,name
old=prior.as_posix()+'/alpha68kn_board.sv'
assert qsf.count(old)==1
assert canonical.as_posix() in qsf
candidate=qsf.replace(old,(out/'alpha68kn_board.sv').as_posix()).replace(canonical.as_posix(),source_root.as_posix())
assert candidate.replace((out/'alpha68kn_board.sv').as_posix(),old).replace(source_root.as_posix(),canonical.as_posix())==qsf
# This assembly-only option is forced OFF for the authorized partial check.
candidate=re.sub(r'^set_global_assignment -name ["{]?GENERATE_RBF_FILE["}]?\s+.+\n','',candidate,flags=re.M)
candidate+='set_global_assignment -name GENERATE_RBF_FILE OFF\n'
# Search roots use frozen assigned sources; no generated/capture metadata becomes a hardware dependency.
(out/'Alpha68k_N.qsf').write_text(candidate,encoding='utf-8',newline='\r\n')
shutil.copyfile(actual/'Alpha68k_N.qpf',out/'Alpha68k_N.qpf')
for name in ['build_id.v','microrom.mem','nanorom.mem']:
    original=(actual/name) if (actual/name).exists() else (prior/name)
    assert sha(original)==launch['canonical_source_pins'][name]
    shutil.copyfile(original,out/name)
meta.pop('effective_baseline_qsf_equivalence',None)
meta.update(status='frozen_ready_not_launched',effective_baseline_map_qsf_equivalence=True,baseline_actual_work=str(actual),baseline_qsf_sha256=sha(actual/'Alpha68k_N.qsf'),qsf_sha256=sha(out/'Alpha68k_N.qsf'),source_roots_rebased=True,canonical_pins_count=161,baseline_rbf_setting=baseline_rbf_setting,candidate_rbf_setting='OFF',non_map_assignment_delta='GENERATE_RBF_FILE forced OFF; no assembler invocation',only_functional_delta='Sound-ROM diagnostic case2 under VERILATOR; original simulation branch exact; physical top kind0')
(out/'prepared.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({k:v for k,v in meta.items() if k!='canonical_source_pins'}))
