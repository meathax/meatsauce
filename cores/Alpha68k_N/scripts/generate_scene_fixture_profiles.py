"""Derive per-ROM fixture addresses; never assume the World and Japan layout match."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
profiles = {}
for name in ("kyros", "kyrosj"):
    path = ROOT / "roms" / name / "maincpu.bin"
    rom = path.read_bytes()
    scene_signature = bytes.fromhex("026ef0000110006e00f00110")
    room_signature = bytes.fromhex("102e0110e8080240000fc1fc0050")
    assert rom.count(scene_signature) == rom.count(room_signature) == 1
    scene = rom.index(scene_signature)
    room = rom.index(room_signature)
    delta = scene - 0x1a66
    assert room == 0x1b90 + delta
    return_pc = 0x9dde + delta
    assert rom[return_pc-6:return_pc] == b"\x4e\xb9" + (0x19a8+delta).to_bytes(4, "big")
    wait = 0x9e8e + delta
    assert rom[wait:wait+6] == bytes.fromhex("4a2e000467fa")
    lea = room + 0x26
    assert rom[lea:lea+2] == b"\x41\xfa"
    table = lea + 2 + int.from_bytes(rom[lea+2:lea+4], "big", signed=True)
    scene5_table = table + 4*0x50
    assert all(rom[scene5_table+8*i:scene5_table+8*i+8] ==
               bytes.fromhex("090060b068f00000") for i in (8,9))
    profiles[name] = {"program_sha256": hashlib.sha256(rom).hexdigest(),
                      "scene_entry": scene, "room_entry": room, "return_pc": return_pc,
                      "game_wait_lo": 0x9dfa+delta, "game_wait_hi": 0x9e9e+delta,
                      "wait_loop": wait, "room_table": table, "scene5_table_base": scene5_table,
                      "relocation_delta": delta,
                      "derivation": "Unique scene/room signatures, validated JSR return and wait-loop opcodes, PC-relative descriptor table and both late descriptors."}
destination = ROOT / "research/kyros_scene_fixture_profiles.json"
if destination.exists():
    raise SystemExit("Refusing to overwrite existing fixture profiles")
destination.write_text(json.dumps(profiles, indent=2)+"\n", encoding="utf-8")
print(json.dumps({k:{n:v[n] for n in ("relocation_delta","scene_entry","room_entry","return_pc")}
                  for k,v in profiles.items()}))
