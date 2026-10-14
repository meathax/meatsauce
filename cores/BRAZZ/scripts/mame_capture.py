"""Capture native MAME boot/attract MMIO, frames and WAV in private artifacts."""
import argparse
import array
from collections import Counter
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import time
import wave
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MAME = Path(r"D:\Arcade\AI\mameexe\mame.exe")


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--gameplay", action="store_true")
    parser.add_argument("--sound-provider", choices=["none", "auto"], default="none")
    parser.add_argument("--pixel-frames", default="", help="comma-separated native presented frame numbers")
    args = parser.parse_args()
    pixel_frames=[int(x) for x in args.pixel_frames.split(",") if x]
    assert all(0<x<=args.seconds*60 for x in pixel_frames), "pixel frame outside capture"
    out = ROOT / "sim/obj_dir/mame_capture" / time.strftime("%Y%m%d_%H%M%S")
    for sub in ["cfg", "nvram", "states", "snap", "input"]:
        (out / sub).mkdir(parents=True, exist_ok=True)
    script = out / "mame_capture.lua"
    shutil.copyfile(ROOT / "scripts/mame_capture.lua", script)
    script_sha256 = sha(script)
    env = os.environ.copy()
    env["CS_CAPTURE_DIRECTORY"] = out.as_posix()
    env["CS_CAPTURE_GAMEPLAY"] = "1" if args.gameplay else "0"
    env["CS_CAPTURE_FRAMES"] = str(args.seconds * 60)
    env["CS_CAPTURE_PIXEL_FRAMES"] = ",".join(map(str,pixel_frames))
    command = [str(MAME), "crysking", "-noreadconfig", "-rompath", str(ROOT / "roms"),
               "-video", "none", "-sound", args.sound_provider, "-volume", "-32", "-nothrottle", "-skip_gameinfo", "-noplugins",
               "-cfg_directory", str(out / "cfg"), "-nvram_directory", str(out / "nvram"),
               "-state_directory", str(out / "states"), "-snapshot_directory", str(out / "snap"),
               "-input_directory", str(out / "input"), "-wavwrite", str(out / "audio.wav"),
               "-autoboot_delay", "0", "-autoboot_script", str(script),
               "-seconds_to_run", str(args.seconds + 2)]
    begin = time.monotonic()
    with (out / "stdout.txt").open("w", encoding="utf-8") as stdout, (out / "stderr.txt").open("w", encoding="utf-8") as stderr:
        run = subprocess.run(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    report = {"scope": "MAME reference capture; not RTL acceptance", "route": "scripted P1/P2 inputs" if args.gameplay else "boot/attract", "sound_provider": args.sound_provider, "game": "crysking", "command": command,
              "exit_code": run.returncode, "run_seconds": time.monotonic() - begin,
              "output_directory": out.as_posix(), "script_sha256": script_sha256,
              "rom_archives": {name: sha(ROOT / "roms" / name) for name in ["crysking.zip", "crysbios.zip"]}}
    complete = out / "complete.json"
    if not complete.is_file():
        report["error"] = "Lua capture did not complete"
    else:
        report["capture"] = json.loads(complete.read_text())
        counts = Counter()
        first = []
        with (out / "mmio.csv").open() as stream:
            for row in csv.DictReader(stream):
                counts[row["operation"] + " " + row["address"]] += int(row.get("count", "1"))
                if len(first) < 24: first.append(row)
        report["first_mmio"] = first
        report["mmio_address_counts"] = dict(sorted(counts.items()))
        if sum(value for key, value in counts.items() if key.startswith("R ")) != report["capture"]["reads"] or sum(value for key, value in counts.items() if key.startswith("W ")) != report["capture"]["writes"]:
            report["error"] = "MMIO record counts do not match capture totals"
        native=[]
        for frame in pixel_frames:
            stem=out/f"native_{frame:06d}"
            metadata=json.loads(stem.with_suffix(".json").read_text())
            image_rgb=Image.open(stem.with_suffix(".png")).convert("RGB")
            assert image_rgb.size==(metadata["width"],metadata["height"])
            raw=image_rgb.tobytes()
            words=[((raw[i]&0xf8)<<8)|((raw[i+1]&0xfc)<<3)|(raw[i+2]>>3)
                   for i in range(0,len(raw),3)]
            packed=struct.pack("<"+"H"*len(words),*words)
            image=stem.with_suffix(".rgb565")
            image.write_bytes(packed)
            candidates=list(out.glob(stem.name+"_bank_*.rgb565"))
            matches=[int(candidate.stem.rsplit("_",1)[1],16) for candidate in candidates if candidate.read_bytes()==packed]
            metadata.update({"pixel_format":"RGB565 little endian, full native visible rectangle",
                             "rgb565_sha256":sha(image),"native_snapshot_sha256":sha(stem.with_suffix(".png")),
                             "presented_bank_matches":matches,
                             "presented_bank_identified":len(matches)==1,
                             "bank_selection_limit":"Only a unique full-frame match identifies the presented bank; register value alone is insufficient",
                             "route":report["route"],"script_sha256":script_sha256,"rom_archives":report["rom_archives"]})
            stem.with_suffix(".json").write_text(json.dumps(metadata,indent=2)+"\n")
            native.append({"frame":frame,"metadata":stem.with_suffix(".json").name,
                           "rgb565_sha256":metadata["rgb565_sha256"],"presented_bank_matches":matches,
                           "width":metadata["width"],"height":metadata["height"]})
        report["native_presented_frames"]=native
        report["artifacts"] = [{"path": p.name, "bytes": p.stat().st_size, "sha256": sha(p)}
                               for p in out.iterdir() if p.is_file() and p.name not in ["stdout.txt", "stderr.txt"]]
        audio = out / "audio.wav"
        if audio.is_file():
            with wave.open(str(audio), "rb") as stream:
                report["audio"] = {"channels": stream.getnchannels(), "sample_rate": stream.getframerate(),
                                   "sample_width": stream.getsampwidth(), "frames": stream.getnframes()}
                peak = 0
                nonzero = 0
                if stream.getsampwidth() == 2:
                    while True:
                        data = stream.readframes(65536)
                        if not data: break
                        samples = array.array("h", data)
                        peak = max(peak, max(map(abs, samples), default=0))
                        nonzero += sum(value != 0 for value in samples)
                    report["audio"].update({"peak_sample": peak, "nonzero_samples": nonzero})
    report_path = ROOT / "docs/mame_capture.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if run.returncode or "error" in report:
        print((out / "stderr.txt").read_text(encoding="utf-8", errors="replace")[-4000:])
        print((out / "stdout.txt").read_text(encoding="utf-8", errors="replace")[-2000:])
        print(f"capture failed; exit={run.returncode}; evidence={report_path}")
        return run.returncode or 2
    print(f"MAME capture: {report['capture']}; MMIO addresses={len(counts)}; snapshots={len(list(out.glob('frame_*.png')))}; audio={report.get('audio')}")
    print(f"evidence={report_path.relative_to(ROOT)}; private artifacts={out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
