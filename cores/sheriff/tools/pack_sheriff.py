"""Create ignored simulation/MRA image from verified parent chips only."""
from pathlib import Path
import hashlib
import json
import zlib

ROOT = Path(__file__).resolve().parents[1]
CHIPS = [
    ("sh.f1", 0x0000, "e79df6e8"), ("sh.f2", 0x0400, "da67721a"),
    ("sh.g1", 0x0800, "3fb7888e"), ("sh.g2", 0x0c00, "585fcfee"),
    ("sh.h1", 0x1000, "e59eab52"), ("sh.h2", 0x1400, "79e69a6a"),
    ("sh.i1", 0x1800, "dda7d1e8"), ("sh.i2", 0x1c00, "5c5f3f86"),
    ("sh.j1", 0x2000, "0aa8b79a"), ("sh.snd", 0x4000, "75731745"),
    ("82s137.3l", 0x4400, "820f8cdd"),
]
image = bytearray(0x4800)
for name, offset, crc in CHIPS:
    data = (ROOT / "roms" / "sheriff" / name).read_bytes()
    assert len(data) == 1024 and f"{zlib.crc32(data):08x}" == crc, name
    image[offset:offset + len(data)] = data
target = ROOT / "roms" / "sheriff.bin"
target.write_bytes(image)
print(json.dumps({"path": str(target), "size": len(image),
                  "sha256": hashlib.sha256(image).hexdigest(),
                  "source": "MAME 0.289 sheriff parent", "fill": 0}))
