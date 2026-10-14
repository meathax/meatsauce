"""Bounded offline ROM return-site candidates; never infer the unobserved A7."""
from pathlib import Path
import hashlib, json, subprocess

O = Path(__file__).resolve().parent
R = O.parents[1]
N = O / "japan_joined720"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
rom = R / "roms/kyrosj/maincpu.bin"
data = rom.read_bytes()
payload = Path(js(O / "japan_joined720_preparation.json")["ROM"]["path"])
assert payload.read_bytes()[0x100:0x100+len(data)] == data
assert data[:8].hex() == "00020ff800000400"
tool = R / "tools/mame0289/unidasm.exe"
assert tool.read_bytes()[:2] == b"MZ"
lineage = js(N / "oracle_lineage_supplement.json")
def calls_ending(pc):
    found = []
    for length in (2, 4, 6):
        start = pc-length
        if start < 0 or pc > len(data): continue
        code = data[start:pc]
        op = int.from_bytes(code[:2], "big")
        valid = ((length == 6 and op == 0x4eb9)
                 or (length == 4 and (op in (0x4eb8, 0x4eba, 0x4ebb, 0x6100) or 0x4ea8 <= op <= 0x4eb7))
                 or (length == 2 and (0x4e90 <= op <= 0x4e97 or (op & 0xff00 == 0x6100 and op & 0xff != 0))))
        if valid:
            command = [str(tool), str(rom), "-arch", "m68000", "-skip", hex(start), "-count", "16", "-basepc", hex(start)]
            result = subprocess.run(command, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            found.append({"candidate_call_address_hex": f"0x{start:06x}", "candidate_return_address_hex": f"0x{pc:06x}", "bytes_hex": code.hex(), "command": command, "actual_exit": result.returncode, "disassembly": result.stdout,
                          "limit": "Exact loadedROM encoding candidate only; linear data can resemble an opcode. Execution, call ancestry, activeSP and stale-stack status are unproven."})
    return found
cases = []
for case in lineage["current_atomic_work_differences"]:
    field = case["field"]
    memories = {"native": (N / "capture" / f"frame_{field:06d}.work.bin").read_bytes(), "MAME": (R / "sim/captures/kyrosj/gameplay" / f"frame_{field:06d}.work.bin").read_bytes()}
    words = []
    for offset in sorted({x["offset"] & ~1 for x in case["differences"]}):
        interpretations = []
        for source, memory in memories.items():
            for pc_offset in (offset-2, offset):
                if pc_offset < 2 or pc_offset+4 > len(memory): continue
                pc = int.from_bytes(memory[pc_offset:pc_offset+4], "big")
                if pc & 1 or pc >= len(data): continue
                interpretations.append({"source": source, "longword_address_hex": f"0x{0x20000+pc_offset:06x}", "longword_hex": memory[pc_offset:pc_offset+4].hex(), "candidate_ROM_PC_hex": f"0x{pc:06x}",
                    "preceding_word_hex": memory[pc_offset-2:pc_offset].hex(), "candidate_prior_call_encodings": calls_ending(pc),
                    "meaning": "Unassigned RAM longword that fits the ROM address range, not a proven PC or exception frame."})
        words.append({"word_address_hex": f"0x{0x20000+offset:06x}", "native_word_hex": memories["native"][offset:offset+2].hex(), "MAME_word_hex": memories["MAME"][offset:offset+2].hex(), "exact_byte_differences": [x for x in case["differences"] if x["offset"] & ~1 == offset], "candidate_interpretations": interpretations})
    cases.append({"field": field, "words": words})
result = {"scope": "Offline bounded mapping of existing differing RAM values to exact loaded68000 ROM encodings; no replay or stack-causality claim.", "ROM": pin(rom), "payload": pin(payload), "main_ROM_offset_hex": "0x100", "payload_main_ROM_bytes_exact": True, "unidasm": pin(tool), "cases": cases,
    "known_reset_A7_hex": "0x020ff8", "current_SP_known": False, "proven_stale_stack_values": False,
    "limits": ["No actual A7 or accepted stack writes were recorded at240/360/600.", "Raw32-bit values and preceding SR-shaped words do not establish a valid return or exception frame.", "Exact call opcode candidates do not prove these bytes were executed; no RTL cause or acceptance mask follows."]}
output = N / "work_ROM_candidates.json"
assert not output.exists()
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
lines = ["# Japan720 strict work-RAM differences", "", "All8 differing bytes remain failures. Actual SP and stale-stack status are unproven; offline ROM candidates are diagnostics only.", "", "| Field | CPU byte address | Native byte | MAME byte | Native word | MAME word |", "|---:|---|---|---|---|---|"]
for case in lineage["current_atomic_work_differences"]:
    for x in case["differences"]:
        lines.append(f"| {case['field']} | {x['address_hex']} | 0x{x['native']:02x} | 0x{x['MAME']:02x} | 0x{x['native_word_hex']} | 0x{x['MAME_word_hex']} |")
table = N / "work_difference_table.md"
assert not table.exists()
table.write_text("\n".join(lines)+"\n", encoding="utf-8")
hits = [x for case in cases for word in case["words"] for interpretation in word["candidate_interpretations"] for x in interpretation["candidate_prior_call_encodings"]]
print(json.dumps({"candidates": str(output), "sha256": sha(output), "table": str(table), "table_sha256": sha(table), "words": sum(len(x["words"]) for x in cases), "call_encoding_candidates": len(hits), "current_SP_known": False, "stale_stack_proven": False}))
