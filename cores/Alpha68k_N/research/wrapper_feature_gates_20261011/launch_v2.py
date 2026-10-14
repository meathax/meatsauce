from pathlib import Path
import subprocess,json,sys
out=Path(__file__).resolve().parent
text=(out/'run_job.py').read_text()
text=text.replace("worker_job.json","worker_v2_job.json").replace("worker_stdout.log","worker_v2_stdout.log").replace("worker_stderr.log","worker_v2_stderr.log")
text=text.replace("phase('build',","phase('build_v2',").replace("phase('run',","phase('run_v2',").replace("'actual_prebuild_source_pins.json'","'actual_prebuild_source_pins_v2.json'").replace("'elf.json'","'elf_v2.json'")
(out/'run_job_v2.py').write_text(text,newline='\n')
p=subprocess.run([sys.executable,str(out/'run_job_v2.py'),'--launch'])
sys.exit(p.returncode)
