"""Run MAME crysking with scripts/mame_sound_usage.lua and summarize VRender0 sound-register usage.

  python -X utf8 scripts/mame_sound_usage.py run  <name> <frames> [--inputs FILE] [--nvram DIR] [--snap N]
  python -X utf8 scripts/mame_sound_usage.py report <name>...   (writes docs/mame_sound_usage.json)

Private artifacts live in sim/obj_dir/sound_usage/<name>/ (ignored). Input files are
"frame port field value" lines (see scripts/mame_sound_usage_inputs.py). Blank NVRAM
leaves the game's Demo Sound = WITHOUT; pass --nvram with a saved NVRAM that has
Demo Sound = WITH (service menu: Cabinet DIP Set Up) to exercise the attract music.
The report FAILS (exit 1) if any run used a feature MAME/the RTL do not implement.
"""
import argparse, collections, csv, json, os, shutil, subprocess, sys, wave, array
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
MAME = Path(r"D:\Arcade\AI\mameexe\mame.exe")
BASE = ROOT / "sim/obj_dir/sound_usage"


def run(a):
    out = BASE / a.name
    for s in ("cfg", "nvram", "states", "snap", "input"):
        (out / s).mkdir(parents=True, exist_ok=True)
    if a.nvram:
        shutil.copytree(a.nvram, out / "nvram/crysking", dirs_exist_ok=True)
    env = dict(os.environ, SU_DIR=out.as_posix(), SU_FRAMES=str(a.frames), SU_SNAP=str(a.snap),
               SU_INPUTS=str(Path(a.inputs).resolve().as_posix()) if a.inputs else "none")
    cmd = [str(MAME), "crysking", "-noreadconfig", "-rompath", str(ROOT / "roms"), "-video", "none", "-sound", "none",
           "-nothrottle", "-skip_gameinfo", "-noplugins", "-cfg_directory", str(out / "cfg"),
           "-nvram_directory", str(out / "nvram"), "-state_directory", str(out / "states"),
           "-snapshot_directory", str(out / "snap"), "-input_directory", str(out / "input"),
           "-wavwrite", str(out / "audio.wav"), "-autoboot_delay", "0",
           "-autoboot_script", str(ROOT / "scripts/mame_sound_usage.lua"),
           "-seconds_to_run", str(a.frames // 60 + 30)]
    return subprocess.run(cmd, cwd=ROOT, env=env, stdout=open(out / "stdout.txt", "w"), stderr=open(out / "stderr.txt", "w")).returncode


def summarize(name):
    d = BASE / name
    notes = list(csv.DictReader(open(d / "note_on.csv")))
    ev = list(csv.DictReader(open(d / "sound_events.csv")))
    summ = (d / "summary.txt").read_text().splitlines()
    r = {"run": name, "frames": int(summ[0].split("=")[1]), "note_on": len(notes)}
    modes = collections.Counter(n["mode"] for n in notes)
    r["status_on_by_mode"] = dict(modes)
    r["channels_used"] = sorted({int(n["channel"]) for n in notes})
    mb = lambda b: sum(1 for n in notes if int(n["mode"], 16) & b)
    r["mode_bits"] = {"loop": mb(1), "sustain": mb(2), "envelope": mb(4), "pingpong": mb(8), "ulaw": mb(16), "8bit": mb(32), "texture": mb(64)}
    r["nonzero_env_rate_or_target"] = sum(1 for n in notes if any(int(n[k], 16 if k.startswith("rate") else 10) for k in ("rate0", "rate1", "rate2", "rate3", "tgt0", "tgt1", "tgt2", "tgt3")))
    gw = collections.defaultdict(collections.Counter)
    for e in ev:
        if e["op"] == "W" and e["offset"] not in ("404", "406", "408", "40a") and int(e["offset"], 16) >= 0x400:
            gw[e["offset"]][e["value"]] += 1
    r["global_write_values"] = {k: dict(v) for k, v in sorted(gw.items()) if k in ("410", "412", "420", "422", "440", "442", "480", "482", "500", "502", "600", "602")}
    r["first_note_frame"] = int(notes[0]["frame"]) if notes else None
    wav = d / "audio.wav"
    if wav.is_file():
        with wave.open(str(wav)) as w:
            a = array.array("h", w.readframes(w.getnframes()))
        r["wav"] = {"rate": w.getframerate(), "seconds": round(w.getnframes() / w.getframerate(), 1), "peak": max(map(abs, a), default=0), "nonzero_samples": sum(1 for x in a if x)}
    gv = r["global_write_values"]
    # supported: ctrl RS only (0x8000), zero reverb/buffer regs, only mode bits 0x10 (ulaw)/0x00, no env rates, intmask all-masked
    bad = []
    if r["mode_bits"]["sustain"] or r["mode_bits"]["pingpong"] or r["mode_bits"]["envelope"] or r["mode_bits"]["loop"]: bad.append("channel mode loop/sustain/envelope/pingpong used")
    if r["nonzero_env_rate_or_target"]: bad.append("envelope rate/target nonzero")
    for k in ("410", "412", "420", "422", "440", "442"):
        if set(gv.get(k, {})) - {"0000"}: bad.append("reverb reg %s nonzero" % k)
    if set(gv.get("602", {})) - {"0000", "8000"}: bad.append("ctrl bits other than RS")
    if set(gv.get("500", {})) - {"0000", "ffff"} or set(gv.get("502", {})) - {"0000", "ffff"}: bad.append("interrupt pend writes")
    if set(gv.get("480", {})) - {"0000", "ffff"}: bad.append("int mask enabling channel IRQs")
    r["unimplemented_feature_use"] = bad
    return r


def main():
    p = argparse.ArgumentParser(); s = p.add_subparsers(dest="cmd", required=True)
    r = s.add_parser("run"); r.add_argument("name"); r.add_argument("frames", type=int)
    r.add_argument("--inputs"); r.add_argument("--nvram"); r.add_argument("--snap", type=int, default=0)
    q = s.add_parser("report"); q.add_argument("names", nargs="+")
    a = p.parse_args()
    if a.cmd == "run":
        return run(a)
    res = [summarize(n) for n in a.names]
    (ROOT / "docs/mame_sound_usage.json").write_text(json.dumps(res, indent=1) + "\n")
    for x in res: print(json.dumps(x))
    return 1 if any(x["unimplemented_feature_use"] for x in res) else 0


if __name__ == "__main__":
    sys.exit(main())
