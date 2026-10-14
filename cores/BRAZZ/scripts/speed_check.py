"""Full-board frame-cadence measurement on a frozen RTL snapshot (independent speed check).

Copies the physical_boot sources (real cs_memory_fabric + SDRAM/DDR models) into
build/speed/snap/<stamp>/ so concurrent RTL edits do not change the measured model, records
git HEAD + RTL diff + per-file SHA256, builds sim/speed/board_speed.cpp with a read-only
Verilator public config, and runs it there.  Outputs (frames.csv, flips.csv, gpu_states.csv)
land in <snap>/sim/obj_dir/boot_probe/activity/<run_id>/.

usage: python scripts/speed_check.py build            -> prints snapshot dir
       python scripts/speed_check.py run <snap> <max_clocks> [--oracle]
"""
import hashlib, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import sim  # noqa: E402  (reuses TARGETS / toolchain paths; sim.py is not modified)

MEMWAIT = {"RD_FILL", "RD_FILL_WAIT", "FLUSH", "FLUSH_WAIT", "DEST_LOAD", "DEST_WAIT"}


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def build():
    t = sim.TARGETS["physical_boot"]
    stamp = time.strftime("%Y%m%d_%H%M%S")
    snap = ROOT / "build/speed/snap" / stamp
    files = list(t["files"]) + [t["main"]] + list(t.get("dependencies", []))
    files += ["sim/boot/" + n for n in os.listdir(ROOT / "sim/boot") if n.endswith(".hpp")]
    files += ["sim/memory/" + n for n in os.listdir(ROOT / "sim/memory") if n.endswith(".hpp")]
    files += ["sim/speed/board_speed.cpp", "sim/speed/cadence_probe.hpp", "sim/speed/speed_public.vlt",
              "roms/images/bios.bin", "roms/images/crysking.bin"]
    files = sorted(set(files))
    for f in files:
        (snap / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / f, snap / f)
    git = lambda *a: subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True).stdout
    (snap / "rtl.diff").write_text(git("diff", "HEAD", "--", "rtl", "donors", "sim", "scripts/sim.py"))
    gpu = (snap / "rtl/video/vr0_gpu.sv").read_text()
    enum = re.search(r"typedef enum logic \[\d+:0\] \{([^}]*)\}\s*state_t", gpu, re.S).group(1)
    names = [n.strip() for n in enum.replace("\n", " ").split(",") if n.strip()]
    mask = sum(1 << i for i, n in enumerate(names) if n in MEMWAIT)
    manifest = {"head": git("rev-parse", "HEAD").strip(), "status": git("status", "--short"),
                "gpu_states": names, "memwait_mask": mask,
                "files": {f: sha(snap / f) for f in files if not f.startswith("roms/")}}
    (snap / "manifest.json").write_text(json.dumps(manifest, indent=1))
    env = os.environ.copy()
    env["PATH"] = str(sim.MSYS / "ucrt64/bin") + os.pathsep + str(sim.MSYS / "usr/bin") + os.pathsep + env["PATH"]
    env["VERILATOR_PROJECT"] = "CrystalSystem"
    ws = subprocess.run([str(sim.VERILATOR), "workspace"], cwd=snap, env=env, capture_output=True, text=True)
    if ws.returncode:
        print(ws.stderr); return ws.returncode
    workspace = Path(ws.stdout.strip())
    env["VERILATOR_WORKSPACE"] = str(workspace)
    mdir = workspace / "obj_dir"; mdir.mkdir(parents=True, exist_ok=True)
    srcs = list(t["files"]) + ["sim/speed/board_speed.cpp"]
    cmd = [str(sim.VERILATOR), "--cc", "--exe", "--build", "-j", "4", "-O3", "--top-module", t["top"],
           "--Mdir", mdir.as_posix(), "-CFLAGS", "-O2", "-MAKEFLAGS", "OPT_FAST=-O2", "-MAKEFLAGS", "OPT_GLOBAL=-O2",
           "-Wno-fatal", *t["parameters"], (snap / "sim/speed/speed_public.vlt").as_posix(), *((snap / f).as_posix() for f in srcs)]
    with (snap / "build.log").open("w") as log:
        r = subprocess.run(cmd, cwd=snap, env=env, stdout=log, stderr=subprocess.STDOUT)
    (snap / "build.json").write_text(json.dumps({"cmd": cmd, "workspace": str(workspace), "exit": r.returncode}, indent=1))
    if r.returncode:
        lines = (snap / "build.log").read_text(errors="replace").splitlines()
        print("\n".join([l for l in lines if "rror" in l][:20] or lines[-20:])); return r.returncode
    print(snap)
    return 0


def run(snap, max_clocks, oracle):
    snap = Path(snap)
    b = json.loads((snap / "build.json").read_text()); m = json.loads((snap / "manifest.json").read_text())
    env = os.environ.copy()
    env["PATH"] = str(sim.MSYS / "ucrt64/bin") + os.pathsep + str(sim.MSYS / "usr/bin") + os.pathsep + env["PATH"]
    env["VERILATOR_WORKSPACE"] = b["workspace"]
    env["CS_GPU_MEMWAIT_MASK"] = str(m["memwait_mask"])
    if not oracle:
        env["CS_NO_ORACLE"] = "1"
    exe = Path(b["workspace"]) / "obj_dir" / "Vcs_crystal_board.exe"
    cmd = [str(sim.VERILATOR), "sim", str(exe), str(max_clocks), "0", "50000000"]
    with (snap / "run.stdout.txt").open("w") as o, (snap / "run.stderr.txt").open("w") as e:
        r = subprocess.run(cmd, cwd=snap, env=env, stdout=o, stderr=e)
    (snap / "run.exit.txt").write_text(str(r.returncode) + "\n")
    return r.returncode


REPLAY_RTL = ["rtl/video/vr0_pixel_pkg.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/video/vr0_gpu.sv",
              "rtl/memory/cs_bus_arbiter.sv", "rtl/board/cs_address_decode.sv", "rtl/video/cs_diagnostic_video.sv",
              "rtl/video/vr0_scanout.sv", "donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv", "rtl/memory/cs_burst_mux.sv", "rtl/memory/cs_texq.sv",
              "rtl/memory/cs_ddr_rom_backend.sv", "rtl/memory/cs_nvram_port.sv", "rtl/memory/cs_memory_fabric.sv"]


def build_replay(snap):
    """GPU frame-replay bench built from the SAME frozen RTL snapshot as the board run."""
    snap = Path(snap).resolve()
    for f in ["sim/speed/gpu_replay.sv", "sim/speed/gpu_replay.cpp"]:
        (snap / f).parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / f, snap / f)
    for f in REPLAY_RTL:
        if not (snap / f).exists():
            (snap / f).parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / f, snap / f)
            print("WARNING copied from live tree (not in snapshot):", f)
    env = os.environ.copy()
    env["PATH"] = str(sim.MSYS / "ucrt64/bin") + os.pathsep + str(sim.MSYS / "usr/bin") + os.pathsep + env["PATH"]
    env["VERILATOR_PROJECT"] = "CrystalSystem"
    ws = subprocess.run([str(sim.VERILATOR), "workspace"], cwd=snap, env=env, capture_output=True, text=True)
    workspace = Path(ws.stdout.strip()); env["VERILATOR_WORKSPACE"] = str(workspace)
    mdir = workspace / "obj_dir"; mdir.mkdir(parents=True, exist_ok=True)
    cmd = [str(sim.VERILATOR), "--cc", "--exe", "--build", "-j", "4", "-O3", "--top-module", "cs_gpu_replay",
           "--Mdir", mdir.as_posix(), "-CFLAGS", "-O2", "-MAKEFLAGS", "OPT_FAST=-O2", "-MAKEFLAGS", "OPT_GLOBAL=-O2",
           "-Wno-fatal", "-GMAME_PALETTE_HACK=1", *((snap / f).as_posix() for f in REPLAY_RTL + ["sim/speed/gpu_replay.sv", "sim/speed/gpu_replay.cpp"])]
    with (snap / "replay_build.log").open("w") as log:
        r = subprocess.run(cmd, cwd=snap, env=env, stdout=log, stderr=subprocess.STDOUT)
    (snap / "replay_build.json").write_text(json.dumps({"cmd": cmd, "workspace": str(workspace), "exit": r.returncode}, indent=1))
    if r.returncode:
        lines = (snap / "replay_build.log").read_text(errors="replace").splitlines()
        print("\n".join([l for l in lines if "rror" in l][:20] or lines[-20:]))
    return r.returncode


def replay(snap, dump, peer):
    snap = Path(snap); b = json.loads((snap / "replay_build.json").read_text()); m = json.loads((snap / "manifest.json").read_text())
    env = os.environ.copy()
    env["PATH"] = str(sim.MSYS / "ucrt64/bin") + os.pathsep + str(sim.MSYS / "usr/bin") + os.pathsep + env["PATH"]
    env["VERILATOR_WORKSPACE"] = b["workspace"]
    exe = Path(b["workspace"]) / "obj_dir" / "Vcs_gpu_replay.exe"
    r = subprocess.run([str(sim.VERILATOR), "sim", str(exe), str(Path(dump).resolve()), str(peer), str(m["memwait_mask"])],
                       cwd=snap, env=env, capture_output=True, text=True)
    print(r.stdout.strip()); print(r.stderr.strip(), file=sys.stderr)
    return r.returncode


if __name__ == "__main__":
    if sys.argv[1] == "build_replay":
        raise SystemExit(build_replay(sys.argv[2]))
    if sys.argv[1] == "replay":
        raise SystemExit(replay(sys.argv[2], sys.argv[3], sys.argv[4]))
    if sys.argv[1] == "build":
        raise SystemExit(build())
    raise SystemExit(run(sys.argv[2], int(float(sys.argv[3])), "--oracle" in sys.argv))
