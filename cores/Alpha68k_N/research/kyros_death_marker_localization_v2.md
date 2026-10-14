# Kyros source-derived death markers

Pinned program/official disassembly hashes and exact validated opcode bytes are in kyros_death_marker_localization.json.

A6 is initialized to0x20000 at ROM0x42c. Byte0x20103 is packed BCD lives:0x2108..0x2116 uses SBCD and0x20a2..0x20c4 splits decimal digits for HUD display. Byte0x20105 is energy initialized to0x50 at0x1af4; damage subtraction0x2b22 branches on exhausted/underflow energy to0x2b5c, which sets byte0x20414=1 and clears energy at0x2b6a. This flag marks depletion/death processing; it does not identify the final animation or life-consumption tick.

mame_idle_death: 38 snapshots; source-derived depleted-state fields [1920, 2880, 3120, 3360, 3600, 3840, 4080]; packed lives transition bounds [{'exclusive_lower_field': 119, 'inclusive_upper_field': 179, 'changes': {'lives_bcd_20103': [0, 3], 'observed_byte_20009': [4, 0]}}, {'exclusive_lower_field': 960, 'inclusive_upper_field': 1200, 'changes': {'lives_bcd_20103': [3, 2], 'energy_20105': [48, 0]}}, {'exclusive_lower_field': 1920, 'inclusive_upper_field': 2160, 'changes': {'lives_bcd_20103': [2, 1], 'energy_20105': [0, 80], 'energy_depleted_flag_20414': [1, 0]}}, {'exclusive_lower_field': 2640, 'inclusive_upper_field': 2880, 'changes': {'lives_bcd_20103': [1, 0], 'energy_20105': [10, 0], 'energy_depleted_flag_20414': [0, 1]}}, {'exclusive_lower_field': 4080, 'inclusive_upper_field': 4320, 'changes': {'lives_bcd_20103': [0, 3], 'energy_20105': [0, 80], 'energy_depleted_flag_20414': [1, 0], 'observed_byte_20009': [1, 7]}}].

native_combat3301: 130 snapshots; source-derived depleted-state fields [1290, 1320, 1350, 2460, 2490, 2520, 2550]; packed lives transition bounds [{'exclusive_lower_field': 150, 'inclusive_upper_field': 179, 'changes': {'lives_bcd_20103': [0, 3], 'observed_byte_20009': [3, 0]}}, {'exclusive_lower_field': 1350, 'inclusive_upper_field': 1380, 'changes': {'lives_bcd_20103': [3, 2], 'energy_depleted_flag_20414': [1, 0], 'observed_byte_20009': [7, 5]}}, {'exclusive_lower_field': 2550, 'inclusive_upper_field': 2580, 'changes': {'lives_bcd_20103': [2, 1], 'energy_depleted_flag_20414': [1, 0], 'observed_byte_20009': [7, 5]}}].

mame_combat: 66 snapshots; source-derived depleted-state fields [1320, 2460, 2520]; packed lives transition bounds [{'exclusive_lower_field': 120, 'inclusive_upper_field': 179, 'changes': {'lives_bcd_20103': [0, 3], 'observed_byte_20009': [5, 0]}}, {'exclusive_lower_field': 1320, 'inclusive_upper_field': 1380, 'changes': {'lives_bcd_20103': [3, 2], 'energy_depleted_flag_20414': [1, 0], 'observed_byte_20009': [1, 5]}}, {'exclusive_lower_field': 2520, 'inclusive_upper_field': 2580, 'changes': {'lives_bcd_20103': [2, 1], 'energy_depleted_flag_20414': [1, 0], 'observed_byte_20009': [1, 5]}}].

native_idle_death: 0 snapshots; source-derived depleted-state fields []; packed lives transition bounds [].

This v2 analysis supersedes the original receipt's unjustified game-mode interpretation of byte20009. The original remains preserved; game state is not filtered on byte20009=5.

Actual native depletion/life-decrement noise windows:
[
  {
    "native_depletion_exclusive_lower_field": 1260,
    "native_depletion_inclusive_upper_field": 1290,
    "life_before": 3,
    "life_after": 2,
    "life_decrement_observed_by_field": 1380,
    "last_pre_depletion_active_noise": {
      "frame": 1259,
      "tick": 1021088090,
      "mixer": 239,
      "volume_b": 6,
      "noise_b_enabled_nonzero_volume": true
    },
    "first_disabled_state_after_last_active": {
      "frame": 1262,
      "tick": 1023605054,
      "mixer": 252,
      "volume_b": 8,
      "noise_b_enabled_nonzero_volume": false
    },
    "noise_disabled_at_depletion_snapshot": true,
    "noise_disabled_through_observed_life_decrement": true,
    "post_depletion_state_rows": 58,
    "paired_source_marker_bounds": [
      1260,
      1320
    ],
    "limit": "Exact depletion write tick and direct channel output are unobserved; this is actual RAM-bounded source semantics plus accepted AY2 register states."
  },
  {
    "native_depletion_exclusive_lower_field": 2430,
    "native_depletion_inclusive_upper_field": 2460,
    "life_before": 2,
    "life_after": 1,
    "life_decrement_observed_by_field": 2580,
    "last_pre_depletion_active_noise": {
      "frame": 2430,
      "tick": 1970793482,
      "mixer": 238,
      "volume_b": 15,
      "noise_b_enabled_nonzero_volume": true
    },
    "first_disabled_state_after_last_active": {
      "frame": 2430,
      "tick": 1970861078,
      "mixer": 252,
      "volume_b": 15,
      "noise_b_enabled_nonzero_volume": false
    },
    "noise_disabled_at_depletion_snapshot": true,
    "noise_disabled_through_observed_life_decrement": false,
    "post_depletion_state_rows": 26,
    "paired_source_marker_bounds": [
      2400,
      2460
    ],
    "limit": "Exact depletion write tick and direct channel output are unobserved; this is actual RAM-bounded source semantics plus accepted AY2 register states."
  }
]

Native/MAME overlapping combat marker cases:61, differences:0. These marker comparisons do not waive RGB differences.

At accepted main write requests log tick/frame/address/masks/data for words20102,20104,20414, plus read-only completed-field bytes20009,20103,20105,20414. Preserve controls and production state. Pair these with existing AY2 accepted writes; no screenshot-only or guessed death marker.

Use existing real --warm-reset-after machinery with unchanged legal punch711..724 input prefix; request reset after715 only after observed AY2-B mixerEF/volume2. Read existing channel B output and register state immediately before reset, through held64masterticks, and after release. Record exact reset assertion/release ticks, reset/cold_reset/download, CPU/chip counters, DAC and AY2-B sample. Require inactive channel during reset and no stale noise after release; allow legitimate later tone. Full ROM/CPU/SDRAM remain real and retained; no simulated score/sound commands or B-channel muting.

Full B03 and whole-game acceptance remain false.
