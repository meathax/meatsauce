# SPDX-License-Identifier: GPL-3.0-or-later
"""Qualify isolated DRAM pin equations against frozen connected source evidence."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,itertools,json,os,shutil,subprocess
PROJECT=Path(__file__).resolve().parent.parent
LOCAL=Path("D:/Arcade/AI/aCORES/sherrif")
ROOT=PROJECT/"_checks/agent-dram-control-20261010"
def sha(p):
 with Path(p).open("rb") as f:return hashlib.file_digest(f,"sha256").hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+"\n",encoding="utf-8",newline="")
def now():return datetime.now(timezone.utc).isoformat()
def linux(p):
 s=Path(p).resolve().as_posix();return "/mnt/"+s[0].lower()+s[2:]
def source(n):
 p=PROJECT/n
 return p if p.exists() else LOCAL/n
def fixture(mux,edges):
 columns=mux["address_input_columns_AR0_to_AR6"]
 selectors={(r["COMADR_n"],r["HREAD_n"]):int(r["BA"],2) for r in mux["physical_selector_rows"]}
 strows={(r["A14"],r["SYNC"],r["phi1_TTL"]):(r["STSTB"],r["RAMSTB_n"]) for r in mux["RAMSTB_boolean_rows"]}
 nand={(0,0):1,(0,1):1,(1,0):0,(1,1):1}
 lines=[];manifest=[]
 for index,row in enumerate(edges["rows"]):
  for signal in ["RAS_n","CAS_n"]:
   assert row["events"][signal]==(row["before"][signal]==1 and row["after"][signal]==0)
   assert row["events"][signal+"_rise"]==(row["before"][signal]==0 and row["after"][signal]==1)
  for phase in ["before","after"]:
   pins=row[phase];selector=selectors[pins["COMADR_n"],pins["HREAD_n"]]
   assert selector==pins["selector"]
   for a14,wr,sync,phi in itertools.product([0,1],repeat=4):
    address=0x2a55|(a14<<14);h,v=19,166
    wires={**{f"A{i}":(address>>i)&1 for i in range(14)},**{f"H{i}":(h>>i)&1 for i in range(5)},**{f"V{i}":(v>>i)&1 for i in range(8)},"0":0}
    ar=sum(wires[label]<<bit for bit,label in enumerate(columns[f"C{selector}"]))
    st,ram=strows[a14,sync,phi]
    we=nand[a14,wr] if selector==1 else 1
    values=[row["cpu_WR_RD"],address,wr,sync,phi,h,v,pins["raw_CAS_n"],pins["raw_RAS_n"],pins["COMADR_n"],pins["HREAD_n"],
            selector,ar,pins["CAS_n"],pins["RAS_n"],we,st,ram,pins["disable"],1-we]
    lines.append(" ".join(map(str,values)))
   manifest.append(dict(source_row=index,crystal_edge=row["crystal_edge"],phase=phase,cpu_WR_RD=row["cpu_WR_RD"],cases=16))
 assert len(lines)==1024 and len(edges["rows"])==32
 return "\n".join(lines)+"\n",manifest
def main():
 ROOT.mkdir(parents=True,exist_ok=False)
 names=["rtl/n8080_dram_control.sv","sim/dram_control_qualification.cpp","tools/run_native_with_receipt.sh",
        "docs/evidence/sheriff_memory_mux_connections.json","docs/evidence/sheriff_dram_cycle_edges.json","tools/derive_dram_cycle_edges.py"]
 hashes={}
 for n in names:
  q=source(n);target=ROOT/"sources"/n;target.parent.mkdir(parents=True,exist_ok=True)
  shutil.copyfile(q,target);hashes[n]=sha(q)
 mux=json.loads((ROOT/"sources"/names[3]).read_text())
 edges=json.loads((ROOT/"sources"/names[4]).read_text())
 assert not mux["physical_memory_timing_qualified"] and not edges["physical_memory_timing_qualified"]
 generator_digests=[h for n,h in edges["evidence_sha256"].items() if n.replace(chr(92),"/").endswith("/tools/derive_dram_cycle_edges.py") or n=="tools/derive_dram_cycle_edges.py"]
 assert len(generator_digests)==1 and generator_digests[0]==hashes["tools/derive_dram_cycle_edges.py"]
 data,manifest=fixture(mux,edges)
 (ROOT/"frozen-pins.txt").write_text(data,encoding="utf-8",newline="")
 write(ROOT/"fixture-cases.json",manifest)
 shell=f"""#!/usr/bin/env bash
set -euo pipefail
root="{linux(ROOT)}"
trap 'code=$?; printf "%s\\n" "$code" > "$root/workflow-exit-code.txt"' EXIT
cd "$root/sources"
verilator --version > "$root/toolchain.txt"
verilator -Wall -Wno-fatal --assert --timing --threads 1 --x-initial unique --x-assign unique --cc --exe --build -j 2 -CFLAGS '-O2 -std=c++17' --top-module n8080_dram_control --Mdir "$root/build" "$root/sources/rtl/n8080_dram_control.sv" "$root/sources/sim/dram_control_qualification.cpp" > "$root/build.log" 2>&1
printf '0\\n' > "$root/build-exit-code.txt"
/bin/bash "$root/sources/tools/run_native_with_receipt.sh" "$root/native-exit-code.txt" "$root/build/Vn8080_dram_control" "$root/frozen-pins.txt" "$root/native-result.json" +verilator+seed+1 > "$root/run.log" 2>&1
"""
 (ROOT/"build_run.sh").write_text(shell,encoding="utf-8",newline="")
 launch=dict(started_utc=now(),source_sha256=hashes,fixture_sha256=sha(ROOT/"frozen-pins.txt"),runner_sha256=sha(Path(__file__)),shell_sha256=sha(ROOT/"build_run.sh"),
  top="n8080_dram_control",seed=1,flags="--assert --timing --threads1 --x-initial unique --x-assign unique -j2 -O2 -std=c++17",
  source_snapshot=str(ROOT/"sources"),scope="Isolated combinational settled related-Bandido control/address pin equations, not4116 data/storage/timing or production integration.")
 shutil.copyfile(Path(__file__),ROOT/"qualified-runner.py")
 write(ROOT/"launch.json",launch)
 command=["wsl.exe","-d","Ubuntu","--cd",str(PROJECT),"--exec","/bin/bash",linux(ROOT/"build_run.sh")]
 with (ROOT/"host.stdout.log").open("wb") as out,(ROOT/"host.stderr.log").open("wb") as err:
  child=subprocess.Popen(command,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
  write(ROOT/"child.json",dict(pid=child.pid,command=command));code=child.wait()
 receipt=dict(launch,finished_utc=now(),workflow_exit=code,
  build_OS_exit=int((ROOT/"build-exit-code.txt").read_text()) if (ROOT/"build-exit-code.txt").exists() else None,
  native_OS_exit=int((ROOT/"native-exit-code.txt").read_text()) if (ROOT/"native-exit-code.txt").exists() else None,
  snapshot_changed=[n for n,h in hashes.items() if sha(ROOT/"sources"/n)!=h],
  fixture_changed=sha(ROOT/"frozen-pins.txt")!=launch["fixture_sha256"],
  model_sha256=sha(ROOT/"build/Vn8080_dram_control") if (ROOT/"build/Vn8080_dram_control").exists() else None)
 write(ROOT/"terminal.json",receipt)
 if code or receipt["build_OS_exit"]!=0 or receipt["native_OS_exit"]!=0 or receipt["snapshot_changed"] or receipt["fixture_changed"]:raise RuntimeError(receipt)
 result=json.loads((ROOT/"native-result.json").read_text())
 assert result["frozen_pin_cases"]==1024 and result["CPU_address_cases"]==65536 and result["video_address_cases"]==8192
 for n,h in hashes.items():assert sha(source(n))==h,n
 files=["launch.json","child.json","terminal.json","build-exit-code.txt","native-exit-code.txt","workflow-exit-code.txt","build.log","run.log","toolchain.txt","native-result.json","frozen-pins.txt","fixture-cases.json","qualified-runner.py"]
 report=dict(scope=launch["scope"],receipt=receipt,native=result,frozen_source_edge_rows=32,source_edge_points=64,RAMSTB_truth_rows=8,CPU_WR_RD_levels_tested=[0,1],
  CPU_WR_RD_generation_qualified=False,phase_derivation_rerun=False,pin_logic_qualified=True,address_projection_qualified=True,
  physical_4116_storage_qualified=False,physical_memory_timing_qualified=False,production_integration_qualified=False,strict_graphics_gate_pass=False,quartus_executed=False,rbf_built=False,
  evidence_sha256={ROOT.relative_to(PROJECT).as_posix()+"/"+n:sha(ROOT/n) for n in files},
  limits=["Related-Bandido connectivity remains conditional for actual Sheriff revision.","CPU_WR_RD generation and timing remain unresolved; both supplied levels were tested, neither selected.",
          "Hbyte/V are physical pin values; no visible coordinate origin, reset or flip transformation is chosen.","WE/write predicate are Boolean levels, not effective DRAM commit events.",
          "No DRAM data model, access-time/hold/refresh qualification, READY feedback, serializer sampling-order or production board integration is claimed."])
 path=PROJECT/"docs/evidence/sheriff_dram_control_native.json";write(path,report)
 assert b"\r\n" not in path.read_bytes()
 print(json.dumps(dict(report=path.as_posix(),native=result,build_exit=receipt["build_OS_exit"],native_exit=receipt["native_OS_exit"],workflow_exit=code)))
if __name__=="__main__":main()
