from pathlib import Path
import subprocess,json,sys,hashlib,shutil
out=Path(__file__).resolve().parent
can=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
assert json.loads((out/'build_v2_exit.json').read_text())['actual_exit_code']==1
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
original=json.loads((out/'preparation.json').read_text())['original_copies']
entry=next(e for e in original if e['original_path']==str(can/'sys/video_mixer.sv'))
assert sha(can/'sys/video_mixer.sv')==entry['sha256']
staged=out/'source/sys/video_mixer.sv'
shutil.copyfile(staged,out/'scope_adapted_first_attempt_video_mixer.sv')
shutil.copyfile(can/'sys/video_mixer.sv',staged)
(out/'framework_scope_recovery.json').write_text(json.dumps(dict(cause='First failed build normalized staged framework copy before GNU Make rejected spaces. V2 copied already-normalized scope and correctly rejected double adaptation. Restore exact pinned original framework only in private source; original production remains unchanged.',restored_sha256=sha(staged),preserved_adapted_sha256=sha(out/'scope_adapted_first_attempt_video_mixer.sv')),indent=2)+'\n',newline='\n')
text=(out/'run_job_v2.py').read_text().replace('worker_v2','worker_v3').replace('build_v2','build_v3').replace('run_v2','run_v3').replace('elf_v2','elf_v3').replace('pins_v2','pins_v3')
(out/'run_job_v3.py').write_text(text,newline='\n')
sys.exit(subprocess.run([sys.executable,str(out/'run_job_v3.py'),'--launch']).returncode)
