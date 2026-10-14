"""Record the field1799 RAM difference without masking it or changing RTL."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = ROOT / "research/combat1799_stack_interpretation.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if RECEIPT.exists():
        raise SystemExit("Refusing to overwrite the existing interpretation")
    previous = ROOT / "research/kyros_combat_hud3301_checkpoint1799_work_difference.json"
    pins = json.loads(previous.read_text())["source_sha256"]
    paths = [ROOT / name for name in pins]
    assert all(sha(path) == pins[str(path.relative_to(ROOT))] for path in paths)
    native, mame = [path.read_bytes() for path in paths]
    differences = [i for i, pair in enumerate(zip(native, mame)) if pair[0] != pair[1]]
    assert len(native) == len(mame) == 4096 and differences == [0xFF3]
    rom = ROOT / "roms/kyros/maincpu.bin"
    data = rom.read_bytes()
    assert data[:8].hex() == "00020ff800000400"
    assert data[0x9DD2:0x9DDE].hex() == "4ff900020ff84eb9000019a8"
    assert data[0x9E8E:0x9E94].hex() == "4a2e000467fa"
    tool = ROOT / "tools/mame0289/unidasm.exe"
    assert tool.read_bytes()[:2] == b"MZ"
    disassembly = []
    for start in (0x9DD0, 0x9E80):
        command = [str(tool), str(rom), "-arch", "m68000", "-skip", hex(start),
                   "-count", "32", "-basepc", hex(start)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        disassembly.append({"command": command, "exit_code": result.returncode,
                            "stdout": result.stdout, "stderr": result.stderr})
    decoded = []
    for label, memory in zip(("native", "mame"), (native, mame)):
        decoded.append({"source": label, "candidate_frame_address": 0x20FEE,
                        "status_register": int.from_bytes(memory[0xFEE:0xFF0], "big"),
                        "program_counter": int.from_bytes(memory[0xFF0:0xFF4], "big"),
                        "following_return_address": int.from_bytes(memory[0xFF4:0xFF8], "big"),
                        "stack_tail_hex": memory[0xFE8:].hex()})
    assert [x["program_counter"] for x in decoded] == [0x9E92, 0x9E8E]
    assert all(x["status_register"] == 0x2004 and
               x["following_return_address"] == 0x9DDE for x in decoded)
    result = {
        "source_parent": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": {**pins, str(rom.relative_to(ROOT)): sha(rom),
                          str(tool.relative_to(ROOT)): sha(tool),
                          str(previous.relative_to(ROOT)): sha(previous)},
        "differences": [{"offset": 0xFF3, "cpu_address": 0x20FF3,
                         "native": native[0xFF3], "mame": mame[0xFF3]}],
        "decoded_stack_candidates": decoded,
        "disassembly": disassembly,
        "manufacturer_reference": {
            "url": "https://www.nxp.com/docs/en/reference-manual/MC68000UM.pdf",
            "section": "6.2.4 / Figure 6-5, printed page 6-10, PDF index94",
            "fact": "MC68000 group1/2 exception frame contains SR followed by PC high/low words",
            "retrieval": "Web tool verified text; no downloaded PDF hash claimed"},
        "interpretation": "Consistent with a retained six-byte exception frame above the JSR return: native and MAME PCs are adjacent valid TST/BEQ wait-loop instruction boundaries, with identical SR and following return address.",
        "limits": "Snapshot/source interpretation only. No native stack-write timing was captured at1799; this does not establish interrupt identity, a physical clock/phase fault or whole-game equivalence. Preserve the raw byte difference; no acceptance mask or RTL fix follows."
    }
    RECEIPT.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"difference": "0x20ff3", "candidate_pcs": [hex(x["program_counter"]) for x in decoded],
                      "receipt": str(RECEIPT.relative_to(ROOT))}))


if __name__ == "__main__":
    main()
