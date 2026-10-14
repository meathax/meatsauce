"""Pin the actual ROM ending dispatch; no ROM or RTL modification."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "research/kyros_ending_fixture_profile.json"
if out.exists():
    raise SystemExit("Refusing to replace ending source evidence")
blocks = {
    0x1e000: "4a2e0d10664c4a2e090b66024e751d6e01010d10",
    0x1e062: "0001e1680001e1680001e1680001e16a0001e6360001e81a0001e1680001e168",
    0x1e82c: "0001e83c0001e8600001eca80001edd4",
    0x1edae: "49ee04204e711d7c001c035f4e4413fc000a00060001426e0d1a61000412610003fa6000f3de",
    0x1f004: "302e0d1a123b002c67260c0100206606526e0d1a60ea0c010018671434000240000f0242fff0d040e54a9440318120004e75",
}
programs = {}
for name in ("kyros", "kyrosj"):
    rom = (ROOT / "roms" / name / "maincpu.bin").read_bytes()
    for address, data in blocks.items():
        expected = bytes.fromhex(data)
        assert rom[address:address+len(expected)] == expected, (name, hex(address))
    assert rom[0x1f036:0x1f03d] == b"KAIROSU"
    programs[name] = hashlib.sha256(rom).hexdigest()
record = {
    "program_sha256": programs,
    "blocks": [{"address": address, "hex": data} for address, data in blocks.items()],
    "fixture_writes": {"0x20d10": 5, "0x20d11": 2, "0x20d12": 2},
    "derivation": "Natural main-loop JSR1e000 dispatches d10=5 to1e81a. d11=2 selects1eca8; d12=2 selects1edae. It initializes staff text and advances d11=3, where1edd4 calls1f004 every8 iterations, copying text from1f036 into411b0 onward. No ending PC redirect.",
    "scope": "Explicit MAME-only final-boss state fixture; not legal playthrough or RTL CPU acceptance.",
}
out.write_text(json.dumps(record, indent=2)+"\n", encoding="utf-8")
print(json.dumps({"profile": str(out.relative_to(ROOT)), "sets": list(programs), "validated_blocks": len(blocks)}))
