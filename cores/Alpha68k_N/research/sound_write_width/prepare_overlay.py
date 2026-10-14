from pathlib import Path
import json,hashlib,shutil,datetime,subprocess
base=Path(__file__).resolve().parent
root=base.parents[1]
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
launch=json.loads((root/'research/quartus_check_merged_fast_launch.json').read_text(encoding='utf-8-sig'))
assert len(launch['source_pins'])==161
for relative,pin in launch['source_pins'].items(): assert sha(canonical/relative)==pin,relative
proof=json.loads((base/'matched_result.json').read_text())
assert proof['exact_probe_source_join'] and proof['jobs']['uncast']['map_exit']==0 and proof['jobs']['cast']['map_exit']==0
admission=root/'research/quartus_check_merged_preprocessed_admission.json'
admit=json.loads(admission.read_text(encoding='utf-8-sig'))
prior=root/'research/merged_design_fastcheck'
assert sha(prior/'Alpha68k_N.qpf')=='8554cfb7549f3d631c6ca5c8f574f60c1cbb58fc80c87491befdbb2efc703910'
assert sha(prior/'Alpha68k_N.qsf')=='e5d1a576cfef51f70a475b280ba3760d2e1ef293ab626ff9828c15f473b743d6'
overlay=root/'research/board15_complete_check'
overlay.mkdir(exist_ok=True)
shutil.copyfile(prior/'Alpha68k_N.qpf',overlay/'Alpha68k_N.qpf')
shutil.copyfile(base/'board_write15.sv',overlay/'alpha68kn_board.sv')
qsf=(prior/'Alpha68k_N.qsf').read_text()
old=canonical.as_posix()+'/rtl/alpha68kn_board.sv'
new=(overlay/'alpha68kn_board.sv').as_posix()
assert qsf.count(old)==1
assert 'PRE_FLOW_SCRIPT_FILE' not in qsf
modified=qsf.replace(old,new)
(overlay/'Alpha68k_N.qsf').write_text(modified,encoding='utf-8',newline='\r\n')
assert (overlay/'Alpha68k_N.qsf').read_text().replace(new,old)==qsf
prereq={}
for name in ['build_id.v','microrom.mem','nanorom.mem']:
    assert sha(canonical/name)==launch['source_pins'][name]
    shutil.copyfile(canonical/name,overlay/name)
    assert sha(overlay/name)==sha(canonical/name)
    prereq[name]=sha(overlay/name)
head=subprocess.check_output(['git','-C',str(canonical),'rev-parse','HEAD'],text=True).strip()
record=dict(status='ready_not_launched',prepared_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),hardware_frozen_head=launch['hardware_frozen_head'],current_docs_head=head,canonical_source_pins=launch['source_pins'],canonical_source_pin_count=161,only_substitution=dict(canonical_path=str(canonical/'rtl/alpha68kn_board.sv'),canonical_sha256=launch['source_pins']['rtl/alpha68kn_board.sv'],actual_path=str(overlay/'alpha68kn_board.sv'),actual_sha256=sha(overlay/'alpha68kn_board.sv')),source_proof=dict(path=str(base/'matched_result.json'),sha256=sha(base/'matched_result.json')),admission=dict(path=str(admission),sha256=sha(admission),previous_qsf_sha256=sha(prior/'Alpha68k_N.qsf'),reviewed_preprocessing=admit),overlay_qsf_sha256=sha(overlay/'Alpha68k_N.qsf'),overlay_qpf_sha256=sha(overlay/'Alpha68k_N.qpf'),prerequisites=prereq,commands=['C:\\Users\\meath\\QuartusFast\\quartus-fast.ps1','build','--project',str(overlay/'Alpha68k_N.qpf'),'--threads','2','--no-fallback'],assembly_allowed=False,rbf_authorized=False,production_queue_lease=False,qualification='Candidate graph only. Preserve all7 strictresource gates and positive fullyqualified timing; missing externalSDRAM I/O limits remain unknown.')
(base/'complete_overlay_launch.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(dict(status=record['status'],project=str(overlay/'Alpha68k_N.qpf'),source_pins=161,board_sha256=record['only_substitution']['actual_sha256'],qsf_sha256=record['overlay_qsf_sha256'],docs_head=head)))
