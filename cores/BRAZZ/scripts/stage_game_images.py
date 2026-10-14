"""Stage per-game simulation images from the generated MRAs (scripts/build_mra.py):
roms/images/<set>_cart.bin (populated flash banks with MAME 0.289 patches), <set>_bios.bin and, for a set
with a protection PIC (MRA index 3), <set>_pic.bin.
sim/boot/main.cpp loads them with CS_GAME=<set>. Images contain copyrighted data: roms/ is ignored."""
from pathlib import Path
import sys, zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra, mra
ROOT = build_mra.ROOT
out = ROOT / "roms/images"; out.mkdir(parents=True, exist_ok=True)
for g in build_mra.GAMES:
    if "_alternatives" in g["file"]:
        continue
    path = ROOT / "releases" / g["file"]
    zips = [build_mra.ROMDIR / z for z in dict.fromkeys([g["zip"], g["bios"][0]])]
    image = mra.build_image(path, zips)
    n = len(g["flash"]) * build_mra.BANK
    (out / f"{g['set']}_cart.bin").write_bytes(image[:n])
    (out / f"{g['set']}_bios.bin").write_bytes(image[n:])
    if g.get("pic"):
        with zipfile.ZipFile(build_mra.ROMDIR / g["zip"]) as z:
            (out / f"{g['set']}_pic.bin").write_bytes(z.read(g["pic"][0]))
    print(f"{g['set']}: cart {n:#x} bytes, bios {len(image)-n:#x} bytes" + (", PIC firmware" if g.get("pic") else ""))
