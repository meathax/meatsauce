"""Freeze the static primary-source audit and exact joined MCU loading offset."""
from pathlib import Path
import hashlib, json, re

O = Path(__file__).resolve().parent
R = Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
audit_path = O / "metadata_audit.json"
audit = json.loads(audit_path.read_text())
assert audit["all_static_metadata_checks_pass"]
assert all(sha(Path(x["path"])) == x["sha256"] for x in audit["source_pins"])
assert all(sha(Path(x["MRA"]["path"])) == x["MRA"]["sha256"] and sha(Path(x["payload"]["path"])) == x["payload"]["sha256"] for x in audit["cases"])
layout = json.loads((R / "rom_layout.json").read_text())
board = Path(audit["joined_board"]["path"])
assert sha(board) == audit["joined_board"]["sha256"]
lines = board.read_text().splitlines()
mcu_load = []
for i, line in enumerate(lines):
    if "mcu_rom[" not in line or "load_data" not in line: continue
    for j in range(i, max(-1, i-5), -1):
        match = re.search(r"load_addr\s*>=\s*'h([0-9a-fA-F]+)\s*&&\s*load_addr\s*<\s*'h([0-9a-fA-F]+)", lines[j])
        if match:
            mcu_load.append({"base": int(match[1], 16), "end": int(match[2], 16), "guard_line": j+1, "write_line": i+1, "guard": lines[j].strip(), "write": line.strip()})
            break
assert len(mcu_load) == 1 and mcu_load[0]["write"].count("mcu_rom[") == 2
firmware = next(x for x in layout["sets"]["sstingry"]["regions"] if x["name"] == "mcu")
assert firmware["base"] == mcu_load[0]["base"]
checks_count = sum(len(x["checks"]) for x in audit["cases"]) + len(audit["menu_checks"])
report = {
    "scope": "Pinned primaryMAME0289 metadata audit plus exact joinedMCU loader/base linkage, no functional qualification.",
    "audit": pin(audit_path), "all_static_checks_pass": True, "static_checks_count": checks_count,
    "MAME_XML_actual_exits": [x["MAME_XML_actual_exit"] for x in audit["cases"]],
    "MRA_ROM_CRC_parts": sum(len(x["CRC_parts"]) for x in audit["cases"]),
    "all3_expanded_ROM_streams_match_pinned_payloads": True,
    "download_bytes_each": 655360, "header_profiles": {"kyros": 0, "kyrosj": 1, "sstingry": 2},
    "DIP_defaults": {x["set"]: x["DIP_default"] for x in audit["cases"]},
    "menu_max_columns": max(x["max_columns"] for x in audit["menu_items"]),
    "joined_mcu_ROM_region": firmware, "joined_mcu_loader": mcu_load,
    "joined_mcu_byte_lane_writes": 2,
    "preliminary_tooling_failure": "Initial finisher expected two MCU assignment lines; actual pinnedRTL contains both byte-lane assignments on one line. The bounded parser assertion was corrected; no source/layout defect or canonical change occurred.",
    "canonical_profile2_rejection_preserved": True,
    "metadata_fix_required": False,
    "limits": audit["unqualified"] + ["Future profile2 wrapper integration must supply actual MRA DIPdefault0x01 via HPS index254; canonical power-on fallback0x8e remains the existing Kyros default.", "Static core J1 fallback is Punch/Jump; Stingray MRA action labels are provisional. Real frontend/profile-specific button naming remains a final integration observation, not proven by this audit."],
}
summary = O / "metadata_summary.json"
assert not summary.exists()
summary.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
doc = O / "metadata_audit.md"
assert not doc.exists()
doc.write_text(f"# Final profile metadata audit\n\nAll{checks_count} static checks pass against the pinned officialMAME0289 executable/source and three freshly exported listXML definitions. All76 MRA ROM parts have primaryMAME CRCs and all three expanded655360byte streams match their previously pinned download payloads. Header profile IDs remain0/1/2, DIP defaults8e/8e/01 and every DIP label/value/bitrange is exact. Core option lines occupy at most{report['menu_max_columns']}columns. Directvideo orientation/rotation/scale visibility, enabledCRT children and configuredhiscore visibility match the intended masks. No concrete metadata error was found, so no fix is staged.\n\nThe joinedP6 MCU load begins at{hex(firmware['base'])}, exactly matching the packed Stingray MCU region; both byte-lane writes and their guards are pinned in metadata_summary.json. Profile2 remains in development and the canonical header guard still rejects it. No early enablement. All three year fields match primaryMAME (1987/1986/1986).\n\nActual nondefaultDIP/coin/cocktail/flip effects, Japan/Stingray CPU-earned hiscore, profile2 MCU-safe wrapper borrowing, affected finalframework modes, provisional Stingray action names and physicaloutputs remain unqualified. Static labels and byte expansion do not supply those gates. No replay, Quartus, RBF, hardware, publication or canonical edit occurred.\n", encoding="utf-8")
files = [O / "audit_metadata.py", O / "finalize_metadata.py", audit_path, summary, doc] + [O / f"mame0289_{name}.xml" for name in ("kyros", "kyrosj", "sstingry")]
manifest = O / "import_manifest.json"
assert not manifest.exists()
manifest.write_text(json.dumps({"scope": report["scope"], "source_pins": audit["source_pins"], "joined_board": audit["joined_board"], "small_import_files": [pin(p) for p in files], "static_metadata_pass": True, "metadata_fix_required": False, "profile2_enabled": False, "runtime_acceptance": False}, indent=2)+"\n", encoding="utf-8")
print(json.dumps({"manifest": str(manifest), "manifest_sha256": sha(manifest), "summary_sha256": sha(summary), "static_checks": checks_count, "CRC_parts": 76, "mcu_base_hex": hex(firmware["base"]), "max_menu_columns": report["menu_max_columns"], "metadata_fix": False, "canonical_profile2_enabled": False}))
