# SPDX-License-Identifier: GPL-2.0-or-later
"""Receipt-backed connected controller/real8035 mixed prefix, frozen CPU writes."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone
PROJECT=Path(__file__).resolve().parent.parent
LOCAL=Path("D:/Arcade/AI/aCORES/sherrif")
ROOT=PROJECT/"_checks/agent-audio-current-mixed-20261010"
PYTHON=sys.executable
def sha(p):
 with Path(p).open("rb") as f:return hashlib.file_digest(f,"sha256").hexdigest()
def write(p,v):Path(p).write_text(json.dumps(v,indent=2)+"\n",encoding="utf-8",newline='')
def now():return datetime.now(timezone.utc).isoformat()
def linux(p):
 s=Path(p).resolve().as_posix();return "/mnt/"+s[0].lower()+s[2:]
def prepare():
 ROOT.mkdir(parents=True,exist_ok=False)
 original=json.loads((LOCAL/"docs/evidence/sheriff_current_cocktail.json").read_text())["native_receipt"]
 assert original["exit_code"]==0 and not original["source_changed_during_run"]
 assert original["inputs"]=="sim/inputs/sheriff_cocktail_two_player.csv"
 assert sha(LOCAL/original["inputs"])==original["inputs_sha256"]
 source=["rtl/n8080_mcs48.sv","rtl/vendor/t48/t48_core.v","rtl/sheriff_sn76477.sv","rtl/sheriff_sn_constants.svh","sim/mixed_audio_connected.sv","sim/mixed_audio_connected.cpp","tools/run_native_with_receipt.sh"]
 hashes={}
 for n in source:
  src=PROJECT/n
  if not src.exists():src=LOCAL/n
  target=ROOT/"sources"/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target);hashes[n]=sha(src)
 for n in ["rtl/n8080_mcs48.sv","rtl/sheriff_sn76477.sv"]:
  assert hashes[n]==original["source_sha256"][n],n
 gain=json.loads((LOCAL/"docs/evidence/sheriff_current_gain_integration.json").read_text())
 assert hashes["rtl/sheriff_sn_constants.svh"]==gain["receipt"]["source_sha256"]["rtl/sheriff_sn_constants.svh"]
 old=LOCAL/"_checks/sn-gameplay-replay-20261010/old_sn_constants.svh"
 assert sha(old)==original["source_sha256"]["rtl/sheriff_sn_constants.svh"]
 shutil.copyfile(old,ROOT/"sources/rtl/old_sn_constants.svh")
 sn=(ROOT/"sources/rtl/sheriff_sn76477.sv").read_text().replace("module sheriff_sn76477","module sheriff_old_sn76477").replace('"sheriff_sn_constants.svh"','"old_sn_constants.svh"')
 (ROOT/"sources/rtl/sheriff_old_sn76477.sv").write_text(sn,encoding="utf-8",newline='')
 mixed_path=LOCAL/"docs/evidence/sheriff_sn_mixed_gameplay.json"
 mixed=json.loads(mixed_path.read_text())
 component=LOCAL/"_checks/sn-mixed-gameplay-20261010/run/current-sn.raw"
 assert sha(component)==mixed["evidence_sha256"]["_checks/sn-mixed-gameplay-20261010/run/current-sn.raw"]
 native=LOCAL/original["runtime_output"]
 fixtures={"io.csv":native/"io.csv","sound.csv":native/"sound.csv","old-audio.raw":native/"audio.raw","current-sn.raw":component,"sheriff.bin":LOCAL/"roms/sheriff.bin"}
 fixture_hash={}
 for n,p in fixtures.items():
  shutil.copyfile(p,ROOT/n);fixture_hash[n]=sha(p)
 bridge={"original_native_receipt":original,"original_receipt_sha256":sha(LOCAL/"docs/evidence/sheriff_current_cocktail.json"),"component_report_sha256":sha(mixed_path),"component_original_os_receipt_retained_as_unknown":mixed.get("terminal",{}).get("native_exit_code") is None,"current_gain_receipt_sha256":sha(LOCAL/"docs/evidence/sheriff_current_gain_integration.json"),"board_source_sha256":sha(PROJECT/"rtl/n8080_board.sv")}
 assert bridge["board_source_sha256"]==original["source_sha256"]["rtl/n8080_board.sv"]
 shell=f"""#!/usr/bin/env bash
set -euo pipefail
root="{linux(ROOT)}"
trap 'code=$?; printf "%s\\n" "$code" > "$root/workflow-exit-code.txt"' EXIT
cd "$root/sources"
verilator --version > "$root/toolchain.txt"
verilator -Wall -Wno-fatal --assert --timing --threads 1 --x-initial unique --x-assign unique --cc --exe --build -j 2 -I"$root/sources/rtl" -CFLAGS '-O2 -std=c++17' --top-module mixed_audio_connected --Mdir "$root/build" "$root/sources/sim/mixed_audio_connected.sv" "$root/sources/rtl/n8080_mcs48.sv" "$root/sources/rtl/vendor/t48/t48_core.v" "$root/sources/rtl/sheriff_sn76477.sv" "$root/sources/rtl/sheriff_old_sn76477.sv" "$root/sources/sim/mixed_audio_connected.cpp" > "$root/build.log" 2>&1
printf 'native\\n' > "$root/phase.txt"
/bin/bash "$root/sources/tools/run_native_with_receipt.sh" "$root/native-exit-code.txt" "$root/build/Vmixed_audio_connected" "$root/sheriff.bin" "$root/io.csv" "$root/sound.csv" "$root/old-audio.raw" "$root/current-sn.raw" "$root/native" +verilator+seed+1 > "$root/run.log" 2>&1
printf 'complete\\n' > "$root/phase.txt"
"""
 (ROOT/"build_run.sh").write_text(shell,encoding="utf-8",newline="")
 manifest=dict(started_utc=now(),source_sha256=hashes,fixture_sha256=fixture_hash,bridge=bridge,
  source_snapshot_sha256={p.relative_to(ROOT/"sources").as_posix():sha(p) for p in sorted((ROOT/"sources").rglob("*")) if p.is_file()},
  runner_sha256=sha(Path(__file__)),shell_sha256=sha(ROOT/"build_run.sh"),seed=1,root_clock_hz=50400000,reset_load_clocks=18432,reset_hold_clocks=1000,samples=1439875,
  scope="Saved same-side native connected production audio controller, real8035 ROM and dual SN chips with frozen actual8080 latch writes; no fresh mainCPU or fullwrapper claim.")
 write(ROOT/"launch.json",manifest)
 command=["wsl.exe","-d","Ubuntu","--cd",str(PROJECT),"--exec","/bin/bash",linux(ROOT/"build_run.sh")]
 with (ROOT/"host.stdout.log").open("wb") as out,(ROOT/"host.stderr.log").open("wb") as err:
  child=subprocess.Popen(command,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
  write(ROOT/"child.json",dict(pid=child.pid,started_utc=now(),command=command))
  code=child.wait()
 receipt=dict(manifest,workflow_exit=code,native_OS_exit=int((ROOT/"native-exit-code.txt").read_text()) if (ROOT/"native-exit-code.txt").exists() else None,finished_utc=now(),
  snapshot_changed=[n for n,h in manifest["source_snapshot_sha256"].items() if sha(ROOT/"sources"/n)!=h],
  fixture_changed=[n for n,h in fixture_hash.items() if sha(ROOT/n)!=h],model_sha256=sha(ROOT/"build/Vmixed_audio_connected") if (ROOT/"build/Vmixed_audio_connected").exists() else None)
 write(ROOT/"terminal.json",receipt)
 if code or receipt["native_OS_exit"]!=0 or receipt["snapshot_changed"] or receipt["fixture_changed"]:raise RuntimeError(receipt)
 result=json.loads((ROOT/"native/result.json").read_text())
 paths=["launch.json","child.json","terminal.json","native-exit-code.txt","workflow-exit-code.txt","run.log","build.log","toolchain.txt","native/result.json","native/current-audio.raw","native/controls.csv"]
 report=dict(scope=manifest["scope"],receipt=receipt,native=result,evidence_sha256={str(ROOT.relative_to(PROJECT)).replace("\\","/")+"/"+n:sha(ROOT/n) for n in paths},
 mixed_connected_delivery_qualified=True,whole_audio_gate_pass=False,physical_enable_pulse_qualified=False,current_fullwrapper_qualified=False,fresh_mainCPU_execution=False,
 limits=["132 source-ordered versus106 atomic mixed-reference envelope restarts retain unresolved physical applicability.","The older mixed component OS receipt remains UNKNOWN; this new receipt applies only to the connected replay.","Recorded command stimulus retains qualified ordinary-input two-player provenance; mainCPU is not rerun.","Reference DAC timestamps, LOFI graph operator and native Q32/binary64 boundaries remain separate scopes."])
 write(PROJECT/"docs/evidence/sheriff_mixed_audio_connected.json",report)
 print(json.dumps(result))
if __name__=="__main__":prepare()
