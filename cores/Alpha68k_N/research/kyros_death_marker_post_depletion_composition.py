"""Qualify one retained CPU depletion window; no replay or game-state mutation."""
import json
import pathlib
import re

from kyros_death_marker_analysis import ROOT, sha, sound_states

out = ROOT / "research/kyros_death_marker_post_depletion_composition.json"
note = out.with_suffix(".md")
assert not out.exists() and not note.exists(), "Preserve immutable qualification"
marker_path = ROOT / "research/kyros_death_marker_localization_v2.json"
marker = json.loads(marker_path.read_text())
terminal_path = ROOT / "research/kyros_combat_hud3301_exit.json"
terminal = json.loads(terminal_path.read_text())
comparison_path = ROOT / "research/kyros_combat_hud3301_sound_interleaving.json"
comparison = json.loads(comparison_path.read_text())
contract_path = ROOT / "research/kyros_punch_noise_chip_contract_exit.json"
contract = json.loads(contract_path.read_text())
manifest_path = ROOT / "research/kyros_combat_hud3301_inputs.sha256"
manifest = dict((line.split(None, 1)[1].strip(), line.split(None, 1)[0])
                for line in manifest_path.read_text().splitlines())
pin_mismatches = []
shared_pins = {}
for path, digest in contract["source_pins"].items():
    if not path.endswith((".v", ".sv")):
        continue
    shared_pins[path] = digest
    if manifest.get(path) != digest or sha(ROOT / path) != digest:
        pin_mismatches.append(path)
ay_path = ROOT / "rtl/vendor/ay49/hdl/a68n_ay49.v"
mask_lines = [{"line": index, "text": text} for index, text in
              enumerate(ay_path.read_text().splitlines(), 1)
              if "use_noB" in text or "Bmix <=" in text]
assert any("regarray[7][4]" in re.sub(r"\s", "", row["text"]) for row in mask_lines)
assert any("(noise|use_noB)" in row["text"] for row in mask_lines)
rows = {row["frame"]: row for row in marker["captures"]["native_combat3301"]["records"]}
before, after, final = rows[1260], rows[1290], rows[1380]
events_path = ROOT / "sim/captures/rtl/kyros_combat_hud3301/audio_events.csv"
events = sound_states(events_path)
post_states = [row for row in events if 1290 < row["frame"] <= 1380]
operand_hashes = {}
for row in (before, after, final):
    path = pathlib.Path(row["path"])
    data = path.read_bytes()
    assert len(data) == 4096 and sha(path) == row["sha256"]
    assert [data[0x103], data[0x105], data[0x414]] == [
        row["lives_bcd_20103"], row["energy_20105"], row["energy_depleted_flag_20414"]]
    operand_hashes[str(row["frame"])] = row["sha256"]
checks = {
    "actual3301_terminal_zero": terminal["exit_code"] == 0 and terminal["frames"] == 3301,
    "pinned_rom_unchanged": sha(pathlib.Path(marker["rom"]["path"])) == marker["rom"]["sha256"],
    "pinned_disassembly_unchanged": sha(pathlib.Path(marker["assembly"]["path"])) == marker["assembly"]["sha256"],
    "all61_marker_cases_match": len(marker["native_vs_mame_combat_marker_comparisons"]) == 61 and
        all(row["equal"] for row in marker["native_vs_mame_combat_marker_comparisons"]),
    "sound_operand_unchanged": sha(events_path) == marker["captures"]["native_combat3301"]["sound_events"]["sha256"],
    "all7732_ay2_writes_and_labels_match": comparison["chips"]["AY2"]["rtl_writes"] == 7732 and
        comparison["chips"]["AY2"]["ordered_port_writes_equal"] and
        comparison["chips"]["AY2"]["decoded_register_data_equal"] and
        comparison["chips"]["AY2"]["field_label_differences"] == 0,
    "actual1260_not_depleted": before["energy_20105"] == 2 and before["energy_depleted_flag_20414"] == 0,
    "actual1260_has_active_noise": before["last_ay2_b_register_state_at_snapshot"]["noise_b_enabled_nonzero_volume"],
    "actual1290_source_depletion_marker": after["energy_20105"] == 0 and after["energy_depleted_flag_20414"] == 1,
    "actual1290_noise_disabled": not after["last_ay2_b_register_state_at_snapshot"]["noise_b_enabled_nonzero_volume"],
    "noise_disabled_through1380": bool(post_states) and all(not row["noise_b_enabled_nonzero_volume"] for row in post_states),
    "actual_life_decrement3_to2": before["lives_bcd_20103"] == 3 and after["lives_bcd_20103"] == 3 and final["lives_bcd_20103"] == 2,
    "same_compiled_current_production_sound_rtl": bool(shared_pins) and not pin_mismatches,
    "qualified_unchanged_chip_contract": contract["exit_code"] == 0 and contract["chip_contract_pass"] and
        all(contract["checks"].values()),
}
result = {
    "scope": "Finite actual CPU RAM-bounded energy depletion/life-consumption window, exact accepted AY2 register states and unchanged production noise masking. No direct CPU-channel PCM or exact unsampled death edge.",
    "checks": checks, "finite_post_depletion_noise_mask_composition_pass": all(checks.values()),
    "full_B03_acceptance": False, "whole_game_acceptance": False,
    "native_depletion_bound": {"exclusive_lower_field": 1260, "inclusive_upper_field": 1290},
    "actual_before_snapshot": before, "actual_after_snapshot": after, "actual_life_decrement_snapshot": final,
    "post_depletion_ay2_mixer_or_volume_rows": len(post_states),
    "compiled_shared_source_pins": shared_pins, "source_pin_mismatches": pin_mismatches,
    "production_mask_source": {"path": str(ay_path), "sha256": sha(ay_path), "excerpts": mask_lines,
                               "meaning": "Mixer bit4 forces the B-channel noise factor high, so the noise-generator bit cannot modulate B. Nonzero legitimate tone is allowed; no zero-channel PCM claim."},
    "receipt_sha256": {str(path.relative_to(ROOT)): sha(path) for path in
                       (marker_path, terminal_path, comparison_path, contract_path, manifest_path)},
    "snapshot_sha256": operand_hashes,
    "limits": ["The first existing depletion window is qualified only at/after the observed1290 marker; exact depletion write tick is absent.",
               "Source ROM proves byte20103 packed BCD lives,20105 energy,20414 energy-depletion flag. Byte20009 is not interpreted as game mode.",
               "Second depletion window has later noise-enabled writes; retain this observation. Whole-tail noise silence is not a general requirement and that activity is not diagnosed as stale noise.",
               "No direct isolated PCM from the CPU host, matched PCM phase, Japan or full B03 pass.",
               "Existing global sound ordering/YM field-label differences and graphics failures are retained."]}
out.write_text(json.dumps(result, indent=2) + "\n")
note.write_text("# Finite Kyros post-depletion noise masking\n\n"
                "The real CPU snapshot1260 has energy2, depletionflag0 and active AY2-B noise (latest write1259: mixerEF,volume6). Snapshot1290 has energy0, depletionflag1 and noise disabled (latest write1289: mixerFC,volume7). Accepted register states keep noise disabled through1380, where packed lives fall3to2. All61 overlapping MAME marker cases and all7732 AY2 write sequences/field labels match.\n\n"
                "The same compiled/current production AY source and passed chip contract support masking composition: mixer bit4 excludes the noise generator from channelB. This allows legitimate nonzero tone. Exact unsampled depletion ticks and direct CPU-channel PCM remain unobserved. Full B03 and whole-game acceptance stay false.\n")
assert all(checks.values()), {key: value for key, value in checks.items() if not value}
print(json.dumps({"output": str(out), "checks": len(checks), "finite_pass": result["finite_post_depletion_noise_mask_composition_pass"],
                  "shared_rtl_pins": len(shared_pins), "post_state_rows": len(post_states), "full_B03_acceptance": False}))
