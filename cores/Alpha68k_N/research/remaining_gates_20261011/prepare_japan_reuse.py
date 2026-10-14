"""Pin one proposed Japan replay of the already-built shared candidate; never launch."""
from pathlib import Path
import csv, hashlib, json

R = Path(r"D:\Arcade\AI\aCORES\Alpha68k N")
C = Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
O = R / "research/remaining_gates_20261011"
J = R / "research/stingray_combined_stage/next_coupled_scope_v2"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
def load(p): return json.loads(p.read_text(encoding="utf-8-sig"))
def wsl(p): return "/mnt/d/" + str(p)[3:].replace("\\", "/")

closure = load(J / "source_closure.json")
sources = closure["source_files"]
assert len(sources) == 75
assert all(sha(Path(s["path"])) == s["combined_sha256"] for s in sources)
build = load(J / "coupled181/build_exit.json")
terminal = load(J / "coupled181/run_exit.json")
qualified = load(J / "coupled181/verification.json")
assert build["exit_code"] == terminal["exit_code"] == 0
assert qualified["protocol_source_pass"] and all(qualified["checks"].values())
exe = J / "source/sim/build/alpha68kn_system_sim"
assert sha(exe) == "8aeaa8d8b1fa4683aeb1415409cac3f39407c58337001fd38ecd887d3f3243de"
rom = C / "roms/kyrosj/download.bin"
assert sha(rom) == "07d3dbbbc22d8ba039fbbf105106bc54d484d2868b930b0eaef7a49317bea20d"
assert len(rom.read_bytes()) == 0xa0000 and rom.read_bytes()[5] == 1
ports = R / "sim/captures/kyrosj/gameplay/frame_states.csv"
assert sha(ports) == "ed826d092dab4e09aaa0b5ed8222e13c74aed5dc53d211f48b0e548a26776bc5"
with ports.open(newline="") as f:
    rows = list(csv.DictReader(f))
assert len(rows) >= 720 and all(k in rows[0] for k in ("frame", "in0", "in1", "in2"))
reference = R / "sim/captures/kyrosj/gameplay"
references = [pin(reference / f"frame_{field:06d}.{suffix}")
              for field in (0, 30, 90, 240, 360, 600)
              for suffix in ("rgb", "work.bin", "sprites.bin")]
old = load(C / "research/kyrosj_current720_qualification.json")
assert old["passed"] and old["fields"] == 720 and old["terminal"]["exit_code"] == 0
assert all(v["different_pixels"] == 0 for v in old["comparisons"])
output = O / "japan_joined720/capture"
command = ["wsl.exe", "-d", "Ubuntu", "--cd", str(exe.parent), "--exec",
           "./alpha68kn_system_sim", wsl(rom), "720", wsl(output), "gameplay",
           "dac-probe", "--inputs", wsl(ports)]
report = {
    "schema": "proposed_existing_joined_ELF_japan720_v1",
    "scope": "Preparation only; no launch, rebuild, source mutation or new acceptance.",
    "existing_source_closure": pin(J / "source_closure.json"),
    "verified_source_files": 75,
    "existing_build": pin(J / "coupled181/build_exit.json"),
    "existing_terminal": pin(J / "coupled181/run_exit.json"),
    "existing_protocol_qualification": pin(J / "coupled181/verification.json"),
    "ELF": pin(exe), "ROM": pin(rom), "inputs": pin(ports),
    "reference_artifacts": references,
    "old_Japan720": pin(C / "research/kyrosj_current720_qualification.json"),
    "command": command,
    "launch_requires_central_authorization": True,
    "rationale": "One affected-profile cold boot/coin/start/play replay is required for the newly joined shared P6/write15/embedded-SSG graph. Reuse the actual qualified ELF; no second build or natural late-stage pilot.",
    "risks": [
        "Profile2 conditions must preserve profile1 CPU phase, HLE service, IRQ priority, pause/borrow and sound-ROM map. Source guards are evidence, not runtime equivalence.",
        "The shared embedded SSG period0 fix affects both profiles; register/bus event streams should retain exact software order, while PCM phase/sample equality is not required.",
        "Current board RAM inference changes and host SDRAM re-evaluation differ from original720; actual wholeRGB/work/strip checkpoints and accepted bus behavior must be checked.",
        "This finite gameplay sequence does not prove Japan death/restart, actual hit/pickup/jump effects, non-default DIPs/cocktail, earned-score reload or full P7/P8."
    ],
    "minimum_terminal_checks": [
        "Actual terminal exit0 and unchanged75source/ELF/ROM/input pins; retain original command and full exit receipt.",
        "720 contiguous fields; every field57344pixels; zero duplicates, deadline misses, row overflows and unexplained unmapped/stalled transactions.",
        "Every actual input application equals the original ports at the original snapshot-after boundary; do not shift fields.",
        "Six whole57344pixel RGB images, workRAM and stripRAM at0/30/90/240/360/600 exactly match pinned MAME.",
        "Compare sound command/latch, IRQ/NMI and globally ordered AY1/AY2/YM2203 writes against existing Japan720/fulltap reference; retain DAC/PCM and mixer bounds without demanding phase-identical PCM.",
        "Retain observed real CPU-controlled coin/start/movement state; profile1 must not service profile2 MCU shared writes or HALT."
    ],
    "earned_gates_to_reuse": {
        "B01": "Both Kyros sets:5 complete late-room RGB fields each; nonvacuous colorff suppression changes500pixels each.",
        "B02": "World Kyros ending:5 complete RGB fields and real ROM staff-text/character overlap. No natural CPU ending claim is needed by the existing plan.",
        "P8_hiscore": "World v5 actual earned901 score protocol:178saved/restoredbytes exactly; fullfeaturefalse due missing119/179 images and graphics residuals."
    }
}
O.mkdir(parents=True, exist_ok=True)
path = O / "japan_joined720_preparation.json"
assert not path.exists()
path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"path": str(path), "sha256": sha(path), "source_files": 75,
                  "reference_artifacts": len(references), "launched": False}))
