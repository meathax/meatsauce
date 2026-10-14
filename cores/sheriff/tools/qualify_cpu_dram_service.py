# SPDX-License-Identifier: GPL-3.0-or-later
"""Joined conditional CPU/control/storage/readback/READY native qualification."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,re,shutil,subprocess,sys
PROJECT=Path(__file__).resolve().parent.parent
ROOT=PROJECT/(sys.argv[1] if len(sys.argv)>1 else "_checks/agent-cpu-dram-service-20261010")
def sha(p):
 with Path(p).open("rb") as f:return hashlib.file_digest(f,"sha256").hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+"\n",encoding="utf-8",newline="")
def linux(p):
 s=Path(p).resolve().as_posix();return "/mnt/"+s[0].lower()+s[2:]
def main():
 ROOT.mkdir(parents=True,exist_ok=False)
 compile_names=["rtl/n8080_cpu.sv","rtl/n8080_vm80a_ce.v","rtl/n8080_ram_readback.sv","rtl/n8080_memory_phases.sv","rtl/n8080_dram_control.sv","rtl/n8080_dram_storage.sv","sim/cpu_dram_service_qualification.sv","sim/cpu_dram_service_qualification.cpp"]
 names=compile_names+["tools/run_native_with_receipt.sh","tools/qualify_cpu_dram_service.py","sim/cpu_ready_service_qualification.sv","sim/cpu_ready_service_qualification.cpp","docs/evidence/sheriff_cpu_ready_service_native.json","docs/evidence/sheriff_dram_storage_native.json","docs/evidence/sheriff_dram_storage_inference.json","docs/evidence/sheriff_memory_mux_connections.json","docs/CPU_DRAM_SERVICE.md"]
 hashes={}
 for n in names:
  q=ROOT/"sources"/n;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(PROJECT/n,q);hashes[n]=sha(q)
 old=json.loads((ROOT/"sources/docs/evidence/sheriff_cpu_ready_service_native.json").read_text())
 for n,h in old["source_sha256"].items():assert hashes.get(n,sha(PROJECT/n))==h,n
 origins=[c["origin_phase"] for c in old["cases"]];assert origins==[0,5,10,15,20]
 def program(n):
  text=(ROOT/"sources"/n).read_text()
  return bytes(int(x.strip(),0) for x in re.search(r"\bp=\{([^}]+)\}",text,re.S).group(1).split(","))
 oldprogram=program("sim/cpu_ready_service_qualification.cpp")
 assert oldprogram==program("sim/cpu_dram_service_qualification.cpp")
 fixture=dict(origins=origins,CPU_WR_RD_supplied_constant=1,physical_Hbyte=19,physical_V=166,program_length=len(oldprogram),program_sha256=hashlib.sha256(oldprogram).hexdigest(),ROM_subroutine_return_address=0x70,ROM_failure_halt_address=0x80,RAM_data_provider="Actual n8080_dram_storage.DO through n8080_ram_readback captured_data; no synthetic host RAM",RAM_write_event="Actual storage.memory_write on source RAS/CAS/WE; not CPU WR release",assumptions=["CPU_WR_RD=1 is explicit external stimulus, not a qualified production generator.","Existing50.4MHz/20.16MHz rounded shared-clock phase projection and five named synthetic reset origins are retained.","Physical Hbyte/V inputs are held fixed for the video row; no raster/address generator is chosen.","Readback consumes pre-edge held DO. This causal model does not qualify electrical simultaneous-edge propagation."])
 write(ROOT/"fixture.json",fixture)
 paths=" ".join('"'+linux(ROOT/"sources"/n)+'"' for n in compile_names)
 shell=f"""#!/usr/bin/env bash
set -euo pipefail
root="{linux(ROOT)}"
trap 'code=$?; printf "%s\\n" "$code" > "$root/workflow-exit-code.txt"' EXIT
cd "$root/sources"
verilator --version > "$root/toolchain.txt"
set +e
verilator -Wno-fatal --assert --timing --threads 1 --x-initial unique --x-assign unique --cc --exe --build -j 2 -CFLAGS '-O2 -std=c++17' --top-module cpu_dram_service_qualification --Mdir "$root/build" {paths} > "$root/build.log" 2>&1
code=$?
printf "%s\\n" "$code" > "$root/build-exit-code.txt"
if [ "$code" -ne 0 ]; then exit "$code"; fi
set -e
for origin in 0 5 10 15 20; do
 /bin/bash "$root/sources/tools/run_native_with_receipt.sh" "$root/origin-$origin-exit-code.txt" "$root/build/Vcpu_dram_service_qualification" "$origin" "$root/origin-$origin.csv" "$root/origin-$origin.json" +verilator+seed+1 > "$root/origin-$origin.stdout.log" 2> "$root/origin-$origin.stderr.log"
done
"""
 (ROOT/"build_run.sh").write_text(shell,encoding="utf-8",newline="")
 shutil.copyfile(Path(__file__),ROOT/"qualified-runner.py")
 launch=dict(started_utc=datetime.now(timezone.utc).isoformat(),source_sha256=hashes,fixture_sha256=sha(ROOT/"fixture.json"),shell_sha256=sha(ROOT/"build_run.sh"),runner_sha256=sha(Path(__file__)),top="cpu_dram_service_qualification",source_snapshot=(ROOT/"sources").as_posix(),scope="Conditional functional CPU RAM service using actual source-control RAS/CAS/WE and storage DO through readback/READY, ordinary instruction fixture; not physical-board or production qualification.")
 write(ROOT/"launch.json",launch)
 command=["wsl.exe","-d","Ubuntu","--cd",str(PROJECT),"--exec","/bin/bash",linux(ROOT/"build_run.sh")]
 with (ROOT/"host.stdout.log").open("wb") as out,(ROOT/"host.stderr.log").open("wb") as err:
  child=subprocess.Popen(command,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW);write(ROOT/"child.json",dict(pid=child.pid,command=command));code=child.wait()
 cases=[]
 for origin in origins:
  p=ROOT/f"origin-{origin}-exit-code.txt"
  if p.exists():
   q=ROOT/f"origin-{origin}.json"
   cases.append(dict(origin=origin,actual_OS_exit=int(p.read_text()),native=json.loads(q.read_text()) if q.exists() else None))
 receipt=dict(launch,finished_utc=datetime.now(timezone.utc).isoformat(),actual_workflow_OS_exit=code,actual_build_OS_exit=int((ROOT/"build-exit-code.txt").read_text()) if (ROOT/"build-exit-code.txt").exists() else None,cases=cases,model_sha256=sha(ROOT/"build/Vcpu_dram_service_qualification") if (ROOT/"build/Vcpu_dram_service_qualification").exists() else None)
 write(ROOT/"terminal.json",receipt)
 for n,h in hashes.items():assert sha(PROJECT/n)==sha(ROOT/"sources"/n)==h,n
 assert sha(ROOT/"fixture.json")==launch["fixture_sha256"]
 native_pass=code==0 and receipt["actual_build_OS_exit"]==0 and len(cases)==5 and all(c["actual_OS_exit"]==0 and c["native"] and c["native"]["pass"] for c in cases)
 filelist=["launch.json","child.json","terminal.json","fixture.json","build_run.sh","qualified-runner.py","workflow-exit-code.txt","build-exit-code.txt","build.log","toolchain.txt"]+[p.name for p in ROOT.glob("origin-*") if p.is_file()]
 artifacts={ROOT.relative_to(PROJECT).as_posix()+"/"+n:sha(ROOT/n) for n in filelist}
 report=dict(scope=launch["scope"],receipt=receipt,source_sha256=hashes,evidence_sha256=artifacts,conditional_joined_service_qualified=native_pass,actual_RAS_CAS_WE_DO_exercised=bool(cases),physical_memory_timing_qualified=False,CPU_WR_RD_generation_qualified=False,production_integration_qualified=False,prior_abstract_service_rerun=False,production_RTL_changed=False,board_QIP_changed=False,fixture=fixture,limits=fixture["assumptions"]+["Exact Sheriff revision, DRAM vendor/grade, CPU setup/hold and READY electrical timing remain unresolved.","Committed-byte ledger observes real pin writes solely for checking; it never supplies RAM read data.","Unsupported coincident storage edges stop qualification; no phase offset, propagation delay or commit bias is fitted."])
 path=PROJECT/"docs/evidence/sheriff_cpu_dram_service.json";write(path,report)
 for n,h in {**hashes,**artifacts}.items():assert sha(PROJECT/n)==h,n
 audit=dict(actual_exit=0,source_artifacts_verified=len(hashes),evidence_artifacts_verified=len(artifacts),actual_build_OS_exit=receipt["actual_build_OS_exit"],actual_workflow_OS_exit=code,actual_native_OS_exits=[c["actual_OS_exit"] for c in cases],qualified=native_pass,model_sha256=receipt["model_sha256"],report_sha256=sha(path),native_receipts_and_source_hashes_verified=True)
 write(ROOT/"independent-verification.json",audit)
 print(json.dumps(dict(report=path.as_posix(),qualified=native_pass,build_exit=receipt["actual_build_OS_exit"],workflow_exit=code,cases=cases,report_sha256=sha(path))))
 return 0 if native_pass else 1
if __name__=="__main__":sys.exit(main())
