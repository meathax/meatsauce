"""Bounded retained-evidence diagnosis. No simulation, build or RTL mutation."""
from pathlib import Path
from collections import deque
import csv, hashlib, json

ROOT = Path(r"D:\Arcade\AI\aCORES\Alpha68k N")
OUT = Path(__file__).resolve().parent
JOIN = ROOT / "research/remaining_gates_20261011/japan_joined720"
SRC = ROOT / "research/stingray_combined_stage/next_coupled_scope_v2/source"
REF = ROOT / "sim/captures/kyrosj/gameplay"
MAME = Path(r"D:\Arcade\AI\mame289")

def pin(p):
    p = Path(p)
    return dict(path=str(p), bytes=p.stat().st_size,
                sha256=hashlib.sha256(p.read_bytes()).hexdigest())

diag = json.loads((JOIN / "work_and_consumer_diagnosis.json").read_text())
words = [(x["field"], int(w["word_address_hex"], 16), w)
         for x in diag["work_words"] for w in x["words"]]
history = {(frame, addr): deque(maxlen=8) for frame, addr, _ in words}
counts = dict.fromkeys(history, 0)
with (REF / "events.csv").open(newline="") as f:
    for ordinal, row in enumerate(csv.DictReader(f), 1):
        if row["area"] != "work":
            continue
        frame, addr = int(row["frame"]), int(row["address"])
        for target, word, _ in words:
            if addr == word and frame <= target:
                key = target, word
                counts[key] += 1
                history[key].append(dict(row_ordinal=ordinal, frame=frame,
                    screen_frame=int(row["screen_frame"]), address_hex=f"0x{addr:06x}",
                    data_hex=f"{int(row['data']):04x}", mask_hex=f"{int(row['mask']):04x}",
                    vpos=int(row["vpos"])))

native_writes = []
with (JOIN / "capture/bus.csv").open(newline="") as f:
    for row in csv.DictReader(f):
        addr = int(row["address"])
        if int(row["rw"]) == 0 and 0x020f00 <= addr < 0x021000:
            native_writes.append({k: int(v) for k, v in row.items()})

states = {}
with (REF / "frame_states.csv").open(newline="") as f:
    for row in csv.DictReader(f):
        if int(row["frame"]) in {240, 360, 600}:
            states[int(row["frame"])] = row

table = []
for frame, addr, word in words:
    events = list(history[frame, addr])
    last = events[-1] if events else None
    complete = frame < 260 or (590 <= frame < 610 and last is not None
                                and last["frame"] >= 590)
    table.append(dict(field=frame, address_hex=f"0x{addr:06x}",
        native_word_hex=word["native_word_hex"], MAME_word_hex=word["MAME_word_hex"],
        different_bytes=word["byte_differences"],
        retained_MAME_events=counts[frame, addr], latest_retained_MAME_writes=events,
        MAME_last_write_coverage_to_snapshot=complete,
        latest_observed_fullword_equals_snapshot=bool(last and last["mask_hex"] == "ffff"
            and last["data_hex"] == word["MAME_word_hex"]),
        active_vs_stale="Unqualified: architectural current A7 and accepted native last writer are absent."))

sting_path = ROOT / "research/stingray_game_divergence_20261011/p2_gameplay181/strict_work_differences.json"
sting = dict(path=str(sting_path), received_agent_facts={
    "119": ["020f6b:F8/00", "020f87:18/0F", "020f8a:06/03", "020f8b:02/82", "020f8f:0E/20"],
    "179": ["020f4a:F0/FF", "020f53:50/00", "020f5a:00/79", "020f5b:00/4A", "020f6b:96/00", "020f87:0A/0D", "020f8b:AB/A4"],
    "SP_lastwriter_coverage": "Native snapshot and accepted instruction/bus streams have no SR/SP; current cause remains open."},
    exact_shared_byte="0x020f6b", inference="Both reside in upper work RAM. Different values/profiles and absent A7/writer receipts do not establish a shared cause.")
if sting_path.exists():
    sting["source_pin"] = pin(sting_path)

pins = [pin(p) for p in [Path(__file__), JOIN / "canonical_v2_import_manifest.json",
    JOIN / "work_and_consumer_diagnosis.json", JOIN / "capture/bus.csv",
    JOIN / "capture/epoch_events.csv", JOIN / "capture/snapshot_state.csv",
    REF / "events.csv", REF / "frame_states.csv", ROOT / "sim/mame/capture.lua",
    ROOT / "roms/kyrosj/maincpu.bin", SRC / "sim/system_main.cpp",
    SRC / "rtl/alpha68kn_board.sv", SRC / "rtl/vendor/fx68k/fx68k.sv",
    MAME / "src/devices/cpu/m68000/m68000.cpp"]]
pins += [pin(JOIN / f"capture/frame_{frame:06d}.work.bin") for frame in [240,360,600]]
pins += [pin(REF / f"frame_{frame:06d}.work.bin") for frame in [240,360,600]]
result = dict(scope="Retained-source diagnosis only; no replay/build/RTL/acceptance changes.",
    strict_work_gate=False, actual_native_exit=0, actual_corrected_verifier_exit=1,
    work_different_bytes=8, words=table, MAME_snapshot_states=states,
    native_capped_upperRAM_writes=dict(count=len(native_writes), first=native_writes[:4], last=native_writes[-4:]),
    reset_A7_hex="0x020ff8", ROM_explicit_A7_setups=diag["explicit_A7_setup_sites"],
    architecture=dict(fx68k="excUnit regs68H/L[15]=USP,[16]=SSP; pswS selects A7.",
        MAME="m68000.cpp state_add USP m_da[15], SP m_da[16], SR m_sr.",
        upper_RAM_writer="Joined profile1 upper RAM writes use qualified CPU lane strobes; MCU profile2 disabled, native HS/pause inactive, HLE offsets outside range.",
        generated_header_inspection="Read-only WSL grep returned exit1: previously logged /tmp generated header has expired; exact current generated C++ symbol names are not qualified."),
    conclusion="No exact cause is supported. Existing MAME tap gives some last values, but neither current SP nor native accepted upperRAM writer ancestry is retained. Preserve strict failure.",
    Stingray_comparison=sting, source_pins=pins)
(OUT / "retained_diagnosis.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(dict(words=[{k: x[k] for k in ["field","address_hex","native_word_hex","MAME_word_hex","MAME_last_write_coverage_to_snapshot","latest_observed_fullword_equals_snapshot"]}
    | {"last":x["latest_retained_MAME_writes"][-1:] } for x in table], native_upper_writes=len(native_writes), strict_work_gate=False), indent=2))
