"""Pin byte-level work-RAM context and the verified oracle consumer defect."""
from pathlib import Path
import hashlib, json

O = Path(__file__).resolve().parent
R = O.parents[1]
N = O / "japan_joined720"
M = R / "sim/captures/kyrosj/gameplay"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
lineage = js(N / "oracle_lineage_supplement.json")
assert lineage["all6_canonical_displayed_PNG_RGB_exact"]
assert lineage["available_original_native_arrays"] == 6 and lineage["all_available_original_native_arrays_exact"]
rom = R / "roms/kyrosj/maincpu.bin"
data = rom.read_bytes()
assert data[:8].hex() == "00020ff800000400"
sites = []
position = 0
while True:
    position = data.find(bytes.fromhex("4ff900020ff8"), position)
    if position < 0: break
    sites.append({"ROM_address_hex": f"0x{position:06x}", "opcode_hex": data[position:position+6].hex(), "operation": "LEA absolute0x020ff8,A7"})
    position += 2
items = []
for case in lineage["current_atomic_work_differences"]:
    field = case["field"]
    native_path = N / "capture" / f"frame_{field:06d}.work.bin"
    mame_path = M / native_path.name
    native, reference = native_path.read_bytes(), mame_path.read_bytes()
    words = []
    for offset in sorted({x["offset"] & ~1 for x in case["differences"]}):
        start, end = max(0, offset-12), min(4096, offset+14)
        words.append({"word_address_hex": f"0x{0x20000+offset:06x}", "native_word_hex": native[offset:offset+2].hex(), "MAME_word_hex": reference[offset:offset+2].hex(),
            "context_start_address_hex": f"0x{0x20000+start:06x}", "native_context_hex": native[start:end].hex(), "MAME_context_hex": reference[start:end].hex(),
            "byte_differences": [x for x in case["differences"] if (x["offset"] & ~1) == offset],
            "meaning": "Upper workRAM below verified reset A7. Exact active/stale stack or register meaning is not established: no SP or accepted stores to this address at this field were recorded."})
    items.append({"field": field, "native": pin(native_path), "MAME": pin(mame_path), "words": words})
contracts = [R / "scripts/normalize_oracle_display.py", R / "scripts/analyze_system_capture.py", R / "docs/REFERENCE_ORACLE.md", R / "docs/COMBAT_HUD_DIAGNOSIS.md", R / "research/combat1799_stack_interpretation.json"]
source = R / "research/stingray_combined_stage/next_coupled_scope_v2/source/sim/system_main.cpp"
result = {
    "scope": "Read-only byte/context and consumer diagnosis. Original nativeexit0/verifierexit1 and 13of14 qualification failure remain immutable.",
    "lineage_supplement": pin(N / "oracle_lineage_supplement.json"),
    "original_failure_import": pin(N / "import_manifest.json"),
    "boot_ROM": pin(rom), "reset_A7_hex": "0x020ff8", "reset_PC_hex": "0x000400", "explicit_A7_setup_sites": sites,
    "work_words": items,
    "consumer_defect": {"responsible_file": str(O / "run_japan_joined720.py"), "responsible_function": "verify", "problem": "RGB branch compares native field to MAME frame_N.rgb drawing buffer; authoritative contract requires frame_N.display.rgb decoded from completed PNG.",
        "minimum_fix": "In a separately pinned verifier revision, choose suffix display.rgb only when comparing native RGB; retain work.bin and sprites.bin references unchanged and keep their mismatch gate false. Reuse the completed capture; no game replay or RTL change.",
        "proof": "All six original/native RGB hashes and all six lossless completed-PNG normalizations match exactly. Field0 raw MAME drawing buffer differs from its displayed sidecar; the original qualification oracle hash matches display sidecar, not raw.",
        "qualification_limit": "Correcting RGB oracle selection does not clear the 3/1/4 work-byte residuals or promote broad P7/P8 acceptance."},
    "known_residual_relation": "World1799 evidence decodes retained SR/PC at0x20fee and differs at0x20ff3 across adjacent wait-loop PCs. Japan residual addresses0x20f5f..0x20fe3 are different locations/fields, so that interpretation cannot be transferred. Only their upperRAM proximity to resetA7 is established.",
    "native_observer": {"source": pin(source), "limitations": "Instruction observer records fields59..60 only (lines274..285). Full epoch stream selects IRQ/backdrop/latch/framecounter/message-strip writes (lines294..302), excluding these upper-workRAM addresses. General bus stream is capped to4096 samples plus2048 selected extras (lines287..293). No accepted-stack-write timing at240/360/600 follows from this capture."},
    "contract_pins": [pin(p) for p in contracts],
    "no_RTL_fix_justified": True,
    "next_work_diagnosis": "The existing IRQ/MAME investigators should decide whether source/boundary evidence can explain these atomic snapshots. A future focused observer would need actual A7 and accepted upperRAM writes at selected fields; none was launched or authorized by this diagnostic."}
output = N / "work_and_consumer_diagnosis.json"
assert not output.exists()
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
supplement = N / "supplement_import_manifest.json"
assert not supplement.exists()
files = [O / "diagnose_japan_terminal.py", O / "characterize_japan_work.py", N / "oracle_lineage_supplement.json", output, O / "wrapper_gates.md"]
supplement.write_text(json.dumps({"scope": result["scope"], "original_import_manifest_unchanged": pin(N / "import_manifest.json"), "small_import_files": [pin(p) for p in files], "new_replay": False, "new_RTL": False, "failure_preserved": True}, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"diagnosis": str(output), "diagnosis_sha256": sha(output), "supplement_manifest": str(supplement), "supplement_sha256": sha(supplement), "work_differing_bytes": [3,1,4], "canonical_RGB_exact": True, "original_verifier_exit": 1, "no_RTL_fix": True}))
