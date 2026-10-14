"""Read-only Kyros ROM/state analysis; never clocks a CPU or changes game state."""
import bisect
import csv
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "research/kyros_death_marker_localization_v2.json"
NOTE = ROOT / "research/kyros_death_marker_localization_v2.md"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sound_states(path):
    reg = [0] * 16
    selected = 0
    states = []
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            if row["kind"] != "write":
                continue
            port, value = int(row["address"]), int(row["data"])
            if port == 145:
                selected = value & 15
            elif port == 144:
                reg[selected] = value
                if selected in (7, 9):
                    states.append({"frame": int(row["frame"]), "tick": int(row["tick"]),
                                   "mixer": reg[7], "volume_b": reg[9],
                                   "noise_b_enabled_nonzero_volume":
                                   not (reg[7] & 16) and bool(reg[9] & 31)})
    return states


def snapshots(relative, events=None):
    directory = ROOT / relative
    states = sound_states(events) if events else []
    fields = [row["frame"] for row in states]
    records = []
    for path in sorted(directory.glob("frame_*.work.bin")):
        frame = int(path.name[6:12])
        data = path.read_bytes()
        assert len(data) == 4096, path
        record = {"frame": frame, "path": str(path), "sha256": sha(path),
                  "observed_byte_20009": data[9], "lives_bcd_20103": data[0x103],
                  "energy_20105": data[0x105], "energy_depleted_flag_20414": data[0x414],
                  "player_state_20408": data[0x408]}
        pos = bisect.bisect_right(fields, frame) - 1
        if events:
            record["last_ay2_b_register_state_at_snapshot"] = states[pos] if pos >= 0 else None
        record["energy_depleted_state"] = (
            record["energy_20105"] == 0 and
            record["energy_depleted_flag_20414"] == 1)
        records.append(record)
    transitions = []
    for before, after in zip(records, records[1:]):
        changes = {key: [before[key], after[key]] for key in
                   ("lives_bcd_20103", "energy_20105", "energy_depleted_flag_20414", "observed_byte_20009")
                   if before[key] != after[key]}
        if changes:
            transitions.append({"exclusive_lower_field": before["frame"],
                                "inclusive_upper_field": after["frame"], "changes": changes})
    return {"capture": str(directory), "snapshot_count": len(records),
            "records": records, "bounded_transitions": transitions,
            "sound_events": {"path": str(events), "sha256": sha(events)} if events else None,
            "exact_unsampled_transition_ticks_qualified": False}


def main():
    assert not OUT.exists() and not NOTE.exists(), "Preserve the original immutable analysis"
    rom_path = ROOT / "roms/kyros/maincpu.bin"
    asm_path = ROOT / "sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm"
    cache_receipt = ROOT / "research/kyros_rom_disassembly_candidates.json"
    pinned = json.loads(cache_receipt.read_text())
    assert sha(rom_path) == pinned["rom_sha256"]
    assert sha(asm_path) == pinned["disassembly_sha256"]
    rom = rom_path.read_bytes()
    addresses = {0x42c, 0x1af4, 0x1b8a, 0x1bea, 0x1bee, 0x1bf2, 0x20a2,
                 0x20b8, 0x20bc, 0x2108, 0x210c, 0x2110, 0x2114, 0x2116,
                 0x2af4, 0x2b1a, 0x2b22, 0x2b26, 0x2b5c, 0x2b6a,
                 0x4c78, 0x4c7c, 0x4c8a}
    instructions = []
    for number, line in enumerate(asm_path.read_text().splitlines(), 1):
        match = re.match(r"^([0-9a-f]{5}): ((?:[0-9a-f]{4} ?)+)\s+(.+)$", line)
        if not match or int(match[1], 16) not in addresses:
            continue
        address = int(match[1], 16)
        opcode = bytes.fromhex(match[2])
        assert rom[address:address + len(opcode)] == opcode, line
        instructions.append({"pc": address, "pc_hex": hex(address), "assembly_line": number,
                             "opcode_hex": opcode.hex(), "instruction": match[3].strip()})
    assert {x["pc"] for x in instructions} == addresses
    captures = {
        "mame_idle_death": snapshots("sim/captures/kyros/idle_death7200_v2"),
        "native_combat3301": snapshots("sim/captures/rtl/kyros_combat_hud3301",
                                         ROOT / "sim/captures/rtl/kyros_combat_hud3301/audio_events.csv"),
        "mame_combat": snapshots("sim/captures/kyros/combat3600_v2"),
        "native_idle_death": snapshots("sim/captures/rtl/kyros_idle_death3601",
                                         ROOT / "sim/captures/rtl/kyros_idle_death3601/audio_events.csv")}
    marker_comparisons = []
    oracle = {row["frame"]: row for row in captures["mame_combat"]["records"]}
    for row in captures["native_combat3301"]["records"]:
        if row["frame"] not in oracle:
            continue
        marker_comparisons.append({"frame": row["frame"], "equal": all(
            row[key] == oracle[row["frame"]][key] for key in
            ("observed_byte_20009", "lives_bcd_20103", "energy_20105", "energy_depleted_flag_20414"))})
    combat_rows = captures["native_combat3301"]["records"]
    combat_sound = sound_states(ROOT / "sim/captures/rtl/kyros_combat_hud3301/audio_events.csv")
    death_windows = []
    for before, after in zip(combat_rows, combat_rows[1:]):
        if before["energy_depleted_flag_20414"] != 0 or not after["energy_depleted_state"]:
            continue
        life_end = next((row for row in combat_rows if row["frame"] > after["frame"] and
                         row["lives_bcd_20103"] < after["lives_bcd_20103"]), None)
        if not life_end:
            continue
        # Use the nearest earlier actual punch-noise register state rather than
        # inventing effect activity at the sparse pre-depletion snapshot.
        active = [row for row in combat_sound if row["frame"] <= before["frame"] and
                  row["noise_b_enabled_nonzero_volume"]]
        first_disabled = next((row for row in combat_sound if active and row["tick"] > active[-1]["tick"] and
                               not row["noise_b_enabled_nonzero_volume"]), None)
        post_states = [row for row in combat_sound if after["frame"] < row["frame"] <= life_end["frame"]]
        pair_before = next((row for row in reversed(combat_rows) if row["frame"] <= before["frame"] and
                            row["frame"] in oracle), None)
        pair_after = next((row for row in combat_rows if row["frame"] >= after["frame"] and
                           row["frame"] in oracle and row["energy_depleted_state"]), None)
        death_windows.append({"native_depletion_exclusive_lower_field": before["frame"],
                              "native_depletion_inclusive_upper_field": after["frame"],
                              "life_before": after["lives_bcd_20103"], "life_after": life_end["lives_bcd_20103"],
                              "life_decrement_observed_by_field": life_end["frame"],
                              "last_pre_depletion_active_noise": active[-1] if active else None,
                              "first_disabled_state_after_last_active": first_disabled,
                              "noise_disabled_at_depletion_snapshot": not after["last_ay2_b_register_state_at_snapshot"]["noise_b_enabled_nonzero_volume"],
                              "noise_disabled_through_observed_life_decrement": all(not row["noise_b_enabled_nonzero_volume"] for row in post_states),
                              "post_depletion_state_rows": len(post_states),
                              "paired_source_marker_bounds": [pair_before["frame"], pair_after["frame"]] if pair_before and pair_after else None,
                              "limit": "Exact depletion write tick and direct channel output are unobserved; this is actual RAM-bounded source semantics plus accepted AY2 register states."})
    host = ROOT / "sim/system_main.cpp"
    result = {"scope": "Read-only pinned ROM plus retained real CPU RAM/sound evidence. No replay, writes or exact unsampled death edge.",
              "source_parent": "6d064dbde944e2f322464b221bf2546aa67519e2",
              "rom": {"path": str(rom_path), "sha256": sha(rom_path)},
              "assembly": {"path": str(asm_path), "sha256": sha(asm_path),
                           "original_receipt": str(cache_receipt), "instructions": instructions},
              "markers": {"lives": {"address": 0x20103, "width_bits": 8, "encoding": "packed BCD count; not the reserve-icon count", "evidence": "2108..2116 decrements via SBCD;20a2..20c4 splits decimal nibbles for display;1b8a calls decrement"},
                          "energy": {"address": 0x20105, "width_bits": 8, "evidence": "1af4 initializes50hex;2b22 subtracts damage;2b26 unsigned <=0 branches to2b5c;2b6a clears energy"},
                          "energy_depleted_flag": {"address": 0x20414, "width_bits": 8, "evidence": "2b5c stores1 on exhausted energy;4c78..4c8a tests zero energy and stores1", "limit": "Marks energy-depletion/death processing, not a completed animation or exact life decrement edge"}},
              "captures": captures, "native_vs_mame_combat_marker_comparisons": marker_comparisons,
              "native_depletion_to_life_decrement_windows": death_windows,
              "supersedes": "kyros_death_marker_localization.json; removes unjustified game-mode interpretation of20009 and arbitrary mode5 depletion restriction. Original snapshot/source bytes are unchanged.",
              "native_capture_format": {"host_path": str(host), "host_sha256": sha(host),
                                        "work_snapshot_bytes": "4096 big-endian address-order bytes; dump_ram puts high then low byte at lines284..291",
                                        "epoch_limit": "epoch predicate at253..254 excludes20102/20104/20414 accepted writes; no exact marker write timestamps"},
              "minimal_death_observer": "At accepted main write requests log tick/frame/address/masks/data for words20102,20104,20414, plus read-only completed-field bytes20009,20103,20105,20414. Preserve controls and production state. Pair these with existing AY2 accepted writes; no screenshot-only or guessed death marker.",
              "minimal_active_punch_reset_observer": "Use existing real --warm-reset-after machinery with unchanged legal punch711..724 input prefix; request reset after715 only after observed AY2-B mixerEF/volume2. Read existing channel B output and register state immediately before reset, through held64masterticks, and after release. Record exact reset assertion/release ticks, reset/cold_reset/download, CPU/chip counters, DAC and AY2-B sample. Require inactive channel during reset and no stale noise after release; allow legitimate later tone. Full ROM/CPU/SDRAM remain real and retained; no simulated score/sound commands or B-channel muting.",
              "full_B03_acceptance": False, "whole_game_acceptance": False,
              "limits": ["Snapshots bound state changes between fields; no exact unrecorded death tick.",
                         "Register enable/volume state is not direct isolated channel PCM output.",
                         "Native idle_death has no per-field work snapshots; final work.bin is taken after host asserts reset and cannot be a gameplay death marker.",
                         "Byte20009 is observed only; its cycling values do not justify a game-mode interpretation or filtering death states on value5.",
                         "Other profiles, direct audio alignment and existing graphics failures remain open."]}
    OUT.write_text(json.dumps(result, indent=2) + "\n")
    lines = ["# Kyros source-derived death markers", "", "Pinned program/official disassembly hashes and exact validated opcode bytes are in kyros_death_marker_localization.json.", "",
             "A6 is initialized to0x20000 at ROM0x42c. Byte0x20103 is packed BCD lives:0x2108..0x2116 uses SBCD and0x20a2..0x20c4 splits decimal digits for HUD display. Byte0x20105 is energy initialized to0x50 at0x1af4; damage subtraction0x2b22 branches on exhausted/underflow energy to0x2b5c, which sets byte0x20414=1 and clears energy at0x2b6a. This flag marks depletion/death processing; it does not identify the final animation or life-consumption tick.", ""]
    for name, group in captures.items():
        depleted = [row["frame"] for row in group["records"] if row["energy_depleted_state"]]
        life_changes = [row for row in group["bounded_transitions"] if "lives_bcd_20103" in row["changes"]]
        lines += [f"{name}: {group['snapshot_count']} snapshots; source-derived depleted-state fields {depleted}; packed lives transition bounds {life_changes}.", ""]
    lines += ["This v2 analysis supersedes the original receipt's unjustified game-mode interpretation of byte20009. The original remains preserved; game state is not filtered on byte20009=5.", "", "Actual native depletion/life-decrement noise windows:", json.dumps(death_windows, indent=2), ""]
    lines += [f"Native/MAME overlapping combat marker cases:{len(marker_comparisons)}, differences:{sum(not row['equal'] for row in marker_comparisons)}. These marker comparisons do not waive RGB differences.", "", result["minimal_death_observer"], "", result["minimal_active_punch_reset_observer"], "", "Full B03 and whole-game acceptance remain false."]
    NOTE.write_text("\n".join(lines) + "\n")
    checked = json.loads(OUT.read_text())
    assert not checked["full_B03_acceptance"] and not checked["whole_game_acceptance"]
    print(json.dumps({"output": str(OUT), "opcode_cases": len(instructions),
                      "snapshot_counts": {key: value["snapshot_count"] for key, value in captures.items()},
                      "native_combat_depleted_fields": [row["frame"] for row in captures["native_combat3301"]["records"] if row["energy_depleted_state"]],
                      "depletion_noise_windows": death_windows,
                      "native_combat_life_transitions": [row for row in captures["native_combat3301"]["bounded_transitions"] if "lives_bcd_20103" in row["changes"]],
                      "marker_comparison_cases": len(marker_comparisons),
                      "marker_comparison_failures": [row for row in marker_comparisons if not row["equal"]]}))


if __name__ == "__main__":
    main()
