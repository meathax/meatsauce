"""Bind the narrow successful CPU seam result to its actual input/source hashes."""
from pathlib import Path
import hashlib, json
ROOT=Path(__file__).resolve().parents[1]
report=json.loads((ROOT/'sim/results/cpu-boot.json').read_text())
if not report['passed']: raise SystemExit('Cannot record a failed CPU seam as passed')
report['program_sha256']=hashlib.sha256((ROOT/'roms/regions/maincpu.bin').read_bytes()).hexdigest()
report['source_hashes']={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [ROOT/'sim/zero_cpu_top.sv', ROOT/'sim/main.cpp', *sorted((ROOT/'rtl/ucore').glob('*.sv'))]}
report['command']='wsl.exe -d Ubuntu --cd D:\\Arcade\\AI\\aCORES\\zero\\sim --exec make cpu-run'
report['limitations']=['COP/CRTC/video/audio not connected in this seam','Unmapped device reads are open bus and recorded','No attract/gameplay or integrated board milestone is proved']
long_wait=ROOT/'sim/results/cpu-latency-13.json'
if long_wait.exists():
    check=json.loads(long_wait.read_text())
    if check.get('external_rom_ce_stalls',0)>0 and check['ram_writes']>1000:
        report['long_wait_probe']={k:check[k] for k in ['cycles','memory_latency','unique_prefetch_addresses','unique_debug_pcs','ram_writes','external_rom_ce_stalls','final_cs','final_ip']}
        report['long_wait_command']='wsl.exe -d Ubuntu --cd D:\\Arcade\\AI\\aCORES\\zero --exec ./sim/build/cpu/Vzero_cpu_top --rom roms/regions/maincpu.bin --output sim/results/cpu-latency-13.json --cycles 600000 --latency 13'
dest=ROOT/'docs/evidence/cpu-seam.json'; dest.parent.mkdir(parents=True,exist_ok=True)
dest.write_text(json.dumps(report,indent=2)+'\n')
print('Recorded narrow CPU evidence at '+dest.relative_to(ROOT).as_posix())
