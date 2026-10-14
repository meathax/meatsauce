"""Materialize private bus images without changing original ROM archives."""
import hashlib
import json
from pathlib import Path
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "roms/images"
FLASH_PARTS = [("bcsv0004f01.u1", 0x8feff120), ("bcsv0004f02.u2", 0x0e799845), ("bcsv0004f03.u3", 0x659e2d17)]
PATCHES = {0x7bb6: 0xdf01, 0x7bb8: 0x9c00, 0x976a: 0x901c, 0x976c: 0x9001,
           0x8096: 0x90fc, 0x8098: 0x9001, 0x8a52: 0x4000, 0x8a54: 0x403c}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save_image(name, data):
    path = OUT / name
    value = digest(data)
    if not path.is_file() or digest(path.read_bytes()) != value:
        path.write_bytes(data)
    return {"path": str(path.relative_to(ROOT)).replace("\\", "/"), "bytes": len(data), "sha256": value}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    archives = {name: digest((ROOT / "roms" / name).read_bytes()) for name in ["crysking.zip", "crysbios.zip"]}
    with zipfile.ZipFile(ROOT / "roms/crysbios.zip") as archive:
        bios = archive.read("mx27l1000.u14")
        if len(bios) != 0x20000 or zlib.crc32(bios) != 0xbeff39a9:
            raise ValueError("Default BIOS CRC/size does not match audited MAME ROM")
    parts = []
    members = []
    with zipfile.ZipFile(ROOT / "roms/crysking.zip") as archive:
        for name, crc in FLASH_PARTS:
            data = archive.read(name)
            if len(data) != 0x1000000 or zlib.crc32(data) != crc:
                raise ValueError(f"Flash CRC/size mismatch: {name}")
            members.append({"name": name, "offset": sum(map(len, parts)), "bytes": len(data), "sha256": digest(data), "crc32": f"{crc:08x}"})
            parts.append(data)
    original = b"".join(parts)
    cartridge = bytearray(original)
    overlay = []
    for offset, value in PATCHES.items():
        before = int.from_bytes(cartridge[offset:offset + 2], "little")
        cartridge[offset:offset + 2] = value.to_bytes(2, "little")
        overlay.append({"byte_offset": f"0x{offset:x}", "original_halfword": f"0x{before:04x}", "loaded_halfword": f"0x{value:04x}"})
    images = [save_image("bios.bin", bios), save_image("flash_original.bin", original), save_image("crysking.bin", cartridge)]
    if archives != {name: digest((ROOT / "roms" / name).read_bytes()) for name in archives}:
        raise RuntimeError("ROM archive identity changed during staging")
    report = {"game": "crysking", "bios": "AMG0110B mx27l1000.u14", "byte_order": "little endian",
              "archives_sha256": archives, "flash_members": members, "images": images,
              "protection_overlay": overlay, "overlay_reference": "pinned MAME crystal.cpp init_crysking",
              "archives_unchanged": True, "private_images_ignored": True}
    (OUT / "manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (ROOT / "docs/rom_image_layout.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS ROM staging: {len(bios)} BIOS bytes, {len(original)} flash bytes, {len(overlay)} protection halfword overlays; original archives unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
