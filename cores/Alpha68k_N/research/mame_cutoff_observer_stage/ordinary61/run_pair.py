from pathlib import Path
import os,subprocess,json,time,hashlib,csv,traceback
HERE=Path(__file__).resolve().parent
OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(name,x):(HERE/name).write_text(json.dumps(x,indent=2)+'\n')
def rows(p):return list(csv.DictReader(p.open()))
def run():
 assert not (HERE/'pair_job.json').exists(),'Do not duplicate paired worker'
 admission=json.loads((HERE/'admission.json').read_text())
 assert all(sha(p)==h for p,h in admission['reference_pins'].items())
 assert all(sha(HERE/n)==h for n,h in admission['workers'].items())
 commands={'native':['wsl.exe','-d','Ubuntu','--cd',str(OLD),'--exec','/usr/bin/python3','/mnt/d/Arcade/AI/aCORES/Alpha68k N/research/mame_cutoff_observer_stage/ordinary61/native_worker.py'], 'mame':[r'D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe',str(HERE/'mame_worker.py')]}
 children={};logs={}
 job={'worker_pid':os.getpid(),'started':time.time(),'admission_sha256':sha(HERE/'admission.json'),'commands':commands}
 for name,command in commands.items():
  logs[name]=(HERE/(name+'_worker.log')).open('wb')
  children[name]=subprocess.Popen(command,cwd=OLD,stdout=logs[name],stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
 job['children']={n:c.pid for n,c in children.items()};save('pair_job.json',job)
 exits={n:c.wait() for n,c in children.items()}
 for l in logs.values():l.close()
 save('pair_exit.json',{'exit_codes':exits,'ended':time.time(),'children':job['children']})
 if any(exits.values()):return 1
 native=OLD/'sim/captures/rtl/irq_ordinary_cutoff61'
 mame=OLD/'sim/captures/kyros/mame_ordinary_cutoff61'
 comparisons={}
 for path,h in admission['reference_pins'].items():
  p=Path(path)
  if 'irq_sampling_edge_latch61' in path:new=native/p.name
  else:new=mame/p.name
  comparisons[path]={'old_unchanged':sha(p)==h,'new_exact':new.exists() and sha(new)==h,'new_path':str(new)}
 # Native run.log may have namespace-dependent text; original CSVs and arrays are strict.
 original_native=OLD/'sim/captures/rtl/irq_sampling_edge_latch61'
 strict_native=[v for p,v in comparisons.items() if str(original_native) in p and Path(p).suffix.lower() in {'.csv','.rgb','.bin'}]
 strict_mame=[v for p,v in comparisons.items() if 'mame_cutoff_observer61' in p and Path(p).suffix.lower() in {'.csv','.rgb','.bin'}]
 original_cutoff=OLD/'sim/captures/kyros/mame_cutoff_observer61/error.log'
 cutoff=lambda p:[l.strip()[l.find('IRQ_CUTOFF,'):] for l in p.read_text(errors='replace').splitlines() if 'IRQ_CUTOFF,' in l]
 nb=rows(native/'ordinary_bus.csv');mr=rows(mame/'ordinary_rom.csv')
 checks={'actual_both_terminal0':not any(exits.values()),'all_old_reference_files_unchanged':all(v['old_unchanged'] for v in comparisons.values()),'all_native_csv_and_raw_arrays_exact':all(v['new_exact'] for v in strict_native),'all_mame_csv_and_raw_arrays_exact':all(v['new_exact'] for v in strict_mame),'original_cutoff_sequence_exact':cutoff(original_cutoff)==cutoff(mame/'error.log'),'native61_contiguous':len(rows(native/'frames.csv'))==61,'mame61_contiguous':len(rows(mame/'frame_states.csv'))==61,'native_both_windows_nonvacuous':all(any(lo<=int(r['tick'])<=hi for r in nb) for lo,hi in admission['windows']),'mame_both_windows_nonvacuous':all(any(lo<=int(r['machine_ticks'])<=hi for r in mr) for lo,hi in admission['windows'])}
 save('qualification.json',{'checks':checks,'accepted':all(checks.values()),'comparisons':comparisons,'new_native_rows':len(nb),'new_mame_rows':len(mr),'native_csv_sha256':sha(native/'ordinary_bus.csv'),'mame_csv_sha256':sha(mame/'ordinary_rom.csv'),'physical_cause_proven':False,'B16_closed':False})
 return 0 if all(checks.values()) else 1
try:
 code=run();save('pair_worker_exit.json',{'exit_code':code,'ended':time.time()});raise SystemExit(code)
except Exception as e:
 save('pair_failure.json',{'error':str(e),'traceback':traceback.format_exc()});raise
