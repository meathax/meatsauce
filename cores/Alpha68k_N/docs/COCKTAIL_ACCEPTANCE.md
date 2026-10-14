# Kyros legal two-player cocktail acceptance

Source parent101d6d0. This scenario covers the remaining real-CPU player2,
cocktail and non-default coinage requirement. It does not replace the
existing broad boot/attract/combat/death evidence or qualify unsampled play.

`make_cocktail_capture.py` derives an observer from the pinned canonical
MAME recorder. Legal DIPs are Cabinet=Cocktail, Difficulty=Hard and
Coinage=A1C/2C B2C/1C (IN1=0x46), with the default three lives. One A coin is
pressed120..125; Start2 is pressed160..165. Player1 remains idle and dies
naturally. Only Player2's high-byte movement/fire/kick ports are driven
from600. No RAM, register, PC or game-state writes occur.

The original3601 observer had a cleanup scope error: finish() referred to
global flip_trace because its local declaration appeared later. The failed
Lua source and capture are retained. Both recorded Windows process handles
were subsequently absent; no terminal exit code was recovered. Do not infer
success from its complete-looking assets. Recovery and the archived runner
hash are in `research/kyros_cocktail3601_oracle_recovery.json`.

The corrected v2 declares the trace file before finish(). Its separate1801
capture completes, exit0, all eight oracle checks pass in38.620 seconds.
Actual150 shows CREDITS2 after one A coin. Actual1200 shows Player2's
upside-down cocktail presentation. The actual MCU flip-write observer first
records flip1 at1132 and retains669 flipped fields through1800. Primary
evidence: `research/kyros_cocktail1801_v2_oracle_verification.json`, job/exit
receipts, `research/kyros_cocktail_source_v2.json` and ignored
`sim/captures/kyros/cocktail1801_v2/`. Full canonical PNG-normalized RGB,
checkpoint RAM, all observed ports, MCU/sound writes and WAV are hash-bound.

`run_cocktail_native.py` launches the actual combined RTL in explicit Ubuntu
WSL, using private ELF864ebb2c...03fffa from the completed combat3301 run.
It requires that run's passed qualification, validates all70 current source
pins, the executable, runtime micro/nanoroms, download image and exact oracle
port hash. It runs real68000/Z80, MCU HLE, sound, SDRAM and video; no rebuild
or game-state injection. PCM/chip observations are enabled for this finite
gameplay scenario. Native job, worker and process handles are in
`research/kyros_cocktail1801_v2_native_{launcher,job}.json`.

Native terminal and feature/graphics acceptance are pending. Follow the
recorded Linux PID and `_native_exit.json`; an observation timeout does not
authorize restart. Once terminal, reuse the existing complete-run verifier:

While the same real CPU run was live through200, its field150 was captured
and matched all57344 canonical MAME pixels exactly, including CREDITS2 after
one A coin. `research/kyros_cocktail1801_v2_native_credit150.json` binds this
finite native coinage case to executable/source/input/complete-RGB hashes.
This does not qualify the still-pending player2 turn or terminal run.

```text
python -X utf8 scripts/verify_long_gameplay_capture.py sim/captures/kyros/cocktail1801_v2 sim/captures/rtl/kyros_cocktail1801_v2 research/kyros_cocktail1801_v2_native_exit.json 1801 research/kyros_cocktail1801_v2_native_graphics_verification.json
```

Also inspect exact applied ports, accepted8005a flip writes and checkpoint
RAM/graphics around the real player transition. Retain any original atomic
graphics differences and diagnose their actual timing rather than masking
or shifting frames. MAME's pass is an oracle qualification, not a native
CPU/feature pass. No Quartus, resource/timing or hardware qualification is
claimed by this scenario.

The native run has now reached real Player2. At1140 all57344 RGB pixels,
all8192 sprite RAM bytes and all4096 work RAM bytes equal MAME exactly.
`research/kyros_cocktail1801_v2_native_player2_1140.json` binds the complete
checkpoint to the executable, source and legal input hashes. It qualifies
finite player-turn/cocktail behavior; continued Player2 actions and terminal
acceptance remain pending.

The earlier requested accepted-flip timestamp inspection found a diagnostic
limit: bus.csv is capped after early samples; epoch_events retains IRQ,
backdrop and selected HUD writes, excluding late MCU writes. It does not
contain the player2 flip transaction. Do not treat that absence as a missing
hardware flip or invent a timestamp. Preserve this observation gap alongside
the actual complete-image/RAM equality. Any later causal timing claim needs
an uncapped appropriate trace; this journal cannot provide it retrospectively.

The original owned process completed1801 fields with exit0 in3746.866 seconds.
`research/kyros_cocktail1801_v2_native_feature_terminal.json` qualifies the
complete field/input sequence, all source/executable pins,57344 unique pixels
per field, no unmapped accesses/deadlines/overflows, continued high-byte Player2
actions and the full1140 RGB/RAM checkpoint. All64 canonical images exist;
62 match exactly. Field60 retains20745 atomic-image differences and900 retains4.
These are not waived or masked: finite_feature_pass=true, full_acceptance_pass=false.
The earlier timed-field60 and HUD evidence remain separate; this run does not
establish a new timed interpretation. Both original terminal and image hashes
are retained. Do not restart this completed run.
