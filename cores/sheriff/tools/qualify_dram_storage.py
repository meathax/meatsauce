# SPDX-License-Identifier: GPL-3.0-or-later
"""One focused native pin-event storage regression, with frozen source closure."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, shutil, subprocess, sys
PROJECT = Path(__file__).resolve().parent.parent
ROOT = PROJECT / (sys.argv[1] if len(sys.argv) > 1 else "_checks/agent-dram-storage-20261010")
def sha(p):
 with Path(p).open("rb") as f: return hashlib.file_digest(f,"sha256").hexdigest()
def write(p,v):
 Path(p).write_text(json.dumps(v,indent=2)+"\n",encoding="utf-8",newline="")
def now(): return datetime.now(timezone.utc).isoformat()
def linux(p):
 s=Path(p).resolve().as_posix()
 return "/mnt/"+s[0].lower()+s[2:]
def fixture(mux,edges):
 columns=mux["address_input_columns_AR0_to_AR6"]
 selectors={(r["COMADR_n"],r["HREAD_n"]):int(r["BA"],2) for r in mux["physical_selector_rows"]}
 address,h,v=0x2a55,19,166
 wires={**{f"A{i}":(address>>i)&1 for i in range(14)},**{f"H{i}":(h>>i)&1 for i in range(5)},**{f"V{i}":(v>>i)&1 for i in range(8)},"0":0}
 lines=[];manifest=[]
 for cpu in [0,1]:
  for row in sorted((r for r in edges["rows"] if r["cpu_WR_RD"]==cpu),key=lambda r:r["crystal_edge"]):
   for signal in ["RAS_n","CAS_n"]:
    assert row["events"][signal]==(row["before"][signal]==1 and row["after"][signal]==0)
    assert row["events"][signal+"_rise"]==(row["before"][signal]==0 and row["after"][signal]==1)
   for phase in [0,1]:
    pins=row["after" if phase else "before"]
    selector=selectors[pins["COMADR_n"],pins["HREAD_n"]]
    assert selector==pins["selector"]
    ar=sum(wires[label]<<bit for bit,label in enumerate(columns[f"C{selector}"]))
    capture=int(bool(phase and row["candidate_pre7_clock"]))
    values=[row["crystal_edge"],cpu,phase,pins["raw_RAS_n"],pins["raw_CAS_n"],pins["COMADR_n"],pins["HREAD_n"],pins["RAS_n"],pins["CAS_n"],selector,ar,capture]
    lines.append(" ".join(map(str,values)));manifest.append(dict(crystal_edge=row["crystal_edge"],cpu_WR_RD=cpu,phase=phase,capture=capture))
 assert len(edges["rows"])==32 and len(lines)==64
 return "\n".join(lines)+"\n",manifest
def main():
 ROOT.mkdir(parents=True,exist_ok=False)
 names=["rtl/n8080_dram_storage.sv","rtl/n8080_dram_control.sv","sim/dram_storage_qualification.sv","sim/dram_storage_qualification.cpp","tools/run_native_with_receipt.sh","docs/evidence/sheriff_memory_mux_connections.json","docs/evidence/sheriff_dram_cycle_edges.json","docs/evidence/sheriff_dram_data_ordering.json","tools/qualify_dram_storage.py","docs/DRAM_STORAGE.md"]
 hashes={}
 for n in names:
  p=PROJECT/n;q=ROOT/"sources"/n;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,q);hashes[n]=sha(p)
 mux=json.loads((ROOT/"sources"/names[5]).read_text())
 edges=json.loads((ROOT/"sources"/names[6]).read_text())
 ordering=json.loads((ROOT/"sources"/names[7]).read_text())
 assert not mux["physical_memory_timing_qualified"] and not edges["physical_memory_timing_qualified"]
 for n,h in ordering["source_sha256"].items(): assert sha(PROJECT/n)==h,n
 data,manifest=fixture(mux,edges)
 (ROOT/"frozen-pins.txt").write_text(data,encoding="utf-8",newline="")
 write(ROOT/"fixture-cases.json",manifest)
 shell=f"""#!/usr/bin/env bash
set -euo pipefail
root="{linux(ROOT)}"
trap 'code=$?; printf "%s\\n" "$code" > "$root/workflow-exit-code.txt"' EXIT
cd "$root/sources"
verilator --version > "$root/toolchain.txt"
set +e
verilator -Wall -Wno-fatal --assert --timing --threads 1 --x-initial unique --x-assign unique --cc --exe --build -j 2 -CFLAGS '-O2 -std=c++17' --top-module dram_storage_qualification --Mdir "$root/build" "$root/sources/rtl/n8080_dram_control.sv" "$root/sources/rtl/n8080_dram_storage.sv" "$root/sources/sim/dram_storage_qualification.sv" "$root/sources/sim/dram_storage_qualification.cpp" > "$root/build.log" 2>&1
code=$?
printf "%s\\n" "$code" > "$root/build-exit-code.txt"
if [ "$code" -ne 0 ]; then exit "$code"; fi
set -e
/bin/bash "$root/sources/tools/run_native_with_receipt.sh" "$root/native-exit-code.txt" "$root/build/Vdram_storage_qualification" "$root/frozen-pins.txt" "$root/native-result.json" +verilator+seed+1 > "$root/run.log" 2>&1
"""
 (ROOT/"build_run.sh").write_text(shell,encoding="utf-8",newline="")
 launch=dict(started_utc=now(),source_sha256=hashes,fixture_sha256=sha(ROOT/"frozen-pins.txt"),runner_sha256=sha(Path(__file__)),shell_sha256=sha(ROOT/"build_run.sh"),source_snapshot=str(ROOT/"sources"),top="dram_storage_qualification",seed=1,scope="Isolated synthesizable functional pin-event storage and old-state clocked consumer ordering, conditional related-Bandido pins. No physical4116 timing or production integration.")
 shutil.copyfile(Path(__file__),ROOT/"qualified-runner.py");write(ROOT/"launch.json",launch)
 command=["wsl.exe","-d","Ubuntu","--cd",str(PROJECT),"--exec","/bin/bash",linux(ROOT/"build_run.sh")]
 with (ROOT/"host.stdout.log").open("wb") as out,(ROOT/"host.stderr.log").open("wb") as err:
  child=subprocess.Popen(command,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
  write(ROOT/"child.json",dict(pid=child.pid,command=command));code=child.wait()
 receipt=dict(launch,finished_utc=now(),workflow_exit=code,build_OS_exit=int((ROOT/"build-exit-code.txt").read_text()) if (ROOT/"build-exit-code.txt").exists() else None,native_OS_exit=int((ROOT/"native-exit-code.txt").read_text()) if (ROOT/"native-exit-code.txt").exists() else None,snapshot_changed=[n for n,h in hashes.items() if sha(ROOT/"sources"/n)!=h],fixture_changed=sha(ROOT/"frozen-pins.txt")!=launch["fixture_sha256"],model_sha256=sha(ROOT/"build/Vdram_storage_qualification") if (ROOT/"build/Vdram_storage_qualification").exists() else None)
 write(ROOT/"terminal.json",receipt)
 if code or receipt["build_OS_exit"]!=0 or receipt["native_OS_exit"]!=0 or receipt["snapshot_changed"] or receipt["fixture_changed"]: raise RuntimeError(receipt)
 result=json.loads((ROOT/"native-result.json").read_text())
 assert result["primary_scenarios"]==8 and result["frozen_source_edge_points"]==64 and result["frozen_reads"]==6 and result["frozen_writes"]==0 and result["frozen_ignored_CAS"]==2 and result["old_state_capture_cases"]==4 and result["functional_mismatches"]==0
 for n,h in hashes.items(): assert sha(PROJECT/n)==h,n
 files=["launch.json","child.json","terminal.json","build-exit-code.txt","native-exit-code.txt","workflow-exit-code.txt","build.log","run.log","toolchain.txt","native-result.json","frozen-pins.txt","fixture-cases.json","qualified-runner.py","build_run.sh"]
 evidence={ROOT.relative_to(PROJECT).as_posix()+"/"+n:sha(ROOT/n) for n in files}
 report=dict(scope=launch["scope"],receipt=receipt,native=result,source_sha256=hashes,evidence_sha256=evidence,source_declared_event_semantics_qualified=True,old_state_consumer_ordering_qualified=True,source_control_branches=[0,1],CPU_WR_RD_generation_qualified=False,physical_memory_timing_qualified=False,actual_Sheriff_revision_qualified=False,production_integration_qualified=False,BRAM_fit_inference_qualified=False,limits=["RAM is uninitialized and never cleared by reset; regression seeds selected addresses through actual write pins.","RAS/CAS and WE/CAS coincident falls are exposed and rejected, without guessed electrical ordering.","One master-clock following a CAS read request updates held DO. CAS rise clears validity after a clocked consumer samples old state; this is a functional ordering contract, not electrical hold proof.","Fixed supplied CPU_WR_RD branches, frozen pin timeline and explicit physical H/V values do not resolve arbitration, dynamic CPU control, row setup/hold, READY, serializer electrical timing, refresh or exact Sheriff chip grade/vendor/load.","Single synchronous16KiBx8 port is intended for BRAM inference; no device fit or productionQIP integration is claimed."])
 path=PROJECT/"docs/evidence/sheriff_dram_storage_native.json";write(path,report)
 for n,h in hashes.items(): assert sha(ROOT/"sources"/n)==h and sha(PROJECT/n)==h,n
 for n,h in evidence.items(): assert sha(PROJECT/n)==h,n
 assert receipt["model_sha256"]==sha(ROOT/"build/Vdram_storage_qualification")
 for name in ["build-exit-code.txt","native-exit-code.txt","workflow-exit-code.txt"]: assert int((ROOT/name).read_text())==0
 audit=dict(actual_exit=0,source_artifacts_verified=len(hashes),evidence_artifacts_verified=len(evidence),source_snapshot_matches_current=True,frozen_fixture_unchanged=True,model_sha256=receipt["model_sha256"],report_sha256=sha(path),actual_OS_exits=dict(build=0,native=0,workflow=0),physical_memory_timing_qualified=False,production_integration_qualified=False)
 write(ROOT/"independent-verification.json",audit)
 print(json.dumps(dict(report=path.as_posix(),native=result,actual_OS_exits=audit["actual_OS_exits"],report_sha256=sha(path),model_sha256=receipt["model_sha256"])))
if __name__=="__main__": main()
