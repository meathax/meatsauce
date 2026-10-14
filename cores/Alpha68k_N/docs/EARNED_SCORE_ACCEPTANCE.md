# Actual CPU-earned score through real HPS

Current completed result, 2026-10-10: the v5 real CPU/HPS wrapper replay
completed901 fields and exited0. Actual gameplay earned raw8192
(BCD00002000, 2000 points); the real donor uploaded178 bytes, the real CPU
reset cleared best, and HPS restored all178 bytes exactly. No synthetic
RAM writes occurred. Saved and restored SHA256:
24b3c8eec5546dd618d0c7bbb28efd145bcfd6495d838d26c6f9ca266755a783.
The reset probe observed clearance after2446 bounded steps; actual donor
restore completed after9668523 steps. These are measured host step counts,
not a physical latency claim.

Evidence: research/kyros_earned_wrapper901_v5_exit.json,
research/kyros_earned_wrapper901_v5_feature_terminal.json and the retained
sim/captures/rtl/kyros_earned_wrapper901_v5/earned_score.json, earned.nvm,
reset_probe.csv and restore_probe.csv. Completed simulations and their
large captures remain in the former working folder through local staging;
retain their original source/command paths rather than rewriting provenance.

The score protocol passed, while the broader feature receipt remains false:
16 of17 checks pass; all_canonical_images_available is false because actual
wrapper images119 and179 were not captured. Field60 retains20835 atomic
pixel differences and field900 retains8. finite_feature_pass,
canonical_graphics_pass and full_acceptance_pass remain false. Fill the
two image gaps using a separate provenance-qualified short actual wrapper
prefix; do not silently copy neighboring images or rerun901 fields solely
for two snapshots. Remaining original graphics, other profiles, complete
gameplay, resource/timing and hardware gates stay open. Ideal framework
PLL/peripheral interfaces do not qualify physical output.

Historical attempts below retain their original failures and recovery:
Historical v2 terminal: completed901 actual gameplay fields but exited1 after
its reset/readiness wait. It saved178 bytes through the real donor/HPS;
the final4 saved bytes are00002000. The pinned host checks nonzero CPU-earned
best, frozen extraction, and saved==actual RAM before writing earned.nvm.
No synthetic RAM writes or score fallback occurred. Full score protocol is
not qualified. `research/kyros_earned_wrapper901_v2_feature_terminal.json`
retains the failed exit, all901 applied ports/current source pins and graphics:
field60 atomic differences20835, field900 differences8; extra oracle119/179
images were not captured by this wrapper. No broad graphics waiver.

The decisive short official-MAME probe follows the same901 legal input
records, earns raw8192 (BCD2000), then invokes actual soft reset. All1041
fields and six integrity/input checks pass. Score clears at reset+57 fields;
required first/last markers coincide with zero best at reset+69. The v2
1000*20000-tick limit is only24.660669 fields. Evidence:
`research/kyros_earned_reset1041_verification.json`, job/exit and complete
reset_probe.csv. This disproves score-retention as the observed MAME behavior
and establishes an undersized test wait; it is not a native reset pass.
The shipped hiscore.dat confirms20e00,ae,01,02; its final marker is a narrow
initialization window, not a constant gameplay value. No config/RTL patch.

`prepare_earned_wrapper_v3.py` preserves v2 and derives only a6000-step
bounded wait (147.964 fields) plus read-only reset_probe.csv. Separate v3
host/builder/runner, source pins, manifest, executable and job prevent
overwriting evidence. The earliest earned MAME score is895, so901 remains
the useful stable prefix; reducing it does not materially save work.
One repaired actual-wrapper replay is needed; no repeated cocktail run.
It is launched as `kyros_earned_wrapper901_v3`; private build exits0,
real simulation PID11163 (worker10925). Original job, launcher and private
source pins are under `research/kyros_earned_wrapper901_v3_*` and
`research/kyros_earned_wrapper_source_v3.json`. Do not restart on observation
timeout or infer protocol success from build/early fields.
Qualification command after its actual terminal:
`python scripts/verify_kyros_feature_terminal.py earned --earned-version v3`.
Require real nonzero earned save, observed CPU-cleared zero/readiness and
exact178-byte restore. Original graphics/fidelity, all-profile, resource,
timing and hardware gates remain open even if that finite protocol passes.

The completed combined RTL combat run produces best-score bytes00002000
at900 and00005000 at3300 in20020..20023, agreeing with the corresponding
MAME RAM. Those are actual CPU-earned BCD values, not score seeds. The
existing synthetic178-byte wrapper fixture proves transfer mechanics but
does not qualify earned-gameplay save/reload.

`prepare_earned_wrapper.py` derives a private host harness from the pinned
canonical wrapper without changing production RTL or the original harness.
It drives the canonical combat3600_v2 observed ports through actual HPS
joystick commands for901 fields. Upper unused IN2 bits are discarded just
as in the qualified combined-system parser. Every HPS command checks actual
controls/coins/DIPs; observed applications are logged. Actual core/framework
pixels and bus/deadline checks retain the existing four-field framework
settling convention, with complete unmodified startup images preserved.

After genuine gameplay, the test pauses through HPS and reads CPU RAM only
with acknowledged pause. It rejects a zero best score rather than inserting
one. It configures the real Hiscores donor, requests OSD extraction, uploads
the178 bytes through actual HPS and compares them with paused CPU RAM. The
saved file is `earned.nvm`. It then runs a real ROM reset, requiring actual
cleared best-score bytes and valid initial signatures before downloading
the saved data through HPS. It requires every restored byte and the earned
best score to agree, then releases the real CPU. No SIM_TEST_HS_WRITE or
synthetic game RAM/register/PC writes occur.

Source/builder pins: `research/kyros_earned_wrapper_source.json`. Generated
private host/build recipe are ignored under
`sim/captures/diagnostics/earned_wrapper/`. The original prebuild launch
failed because Windows backslashes in JSON were interpreted literally by
Ubuntu pathlib. No compilation occurred in that attempt. Its absent exact
WSL handle, unknown exit code, worker/source snapshots and recovery are
retained in `research/kyros_earned_wrapper901_prebuild_failure.json` and
`research/kyros_earned_wrapper_source_v1.json`. Portable paths now use `/`;
the corrected launch has a distinct v2 namespace.

The v2 private Verilator build completed exit0 in48.159 seconds. It compiles
current real RTL/framework/HPS with the existing explicit framework scope
adapter and ideal peripheral/PLL interfaces; no Quartus stage is involved.
Its immutable executable hash is30d0db6c...ac5a585. Actual HPS ROM download
released327680 paired words. The901-field CPU replay is live; its recorded
Linux simulation PID is7814. Field0 retains57602 framework samples while
raw core coverage is57344, and the next observed fields have57344 samples;
this is not a new startup-image or physical-output pass.

Follow `research/kyros_earned_wrapper901_v2_job.json`, `_build_exit.json`,
`_run.log`, `_worker.log` and the eventual `_exit.json`. A process observation
failure does not authorize restart. Qualification requires exit0 plus the
actual `earned_score.json`, full gameplay/port/metric evidence and hashed
saved NVRAM. Build/launch/early CPU activity alone do not qualify score save,
reset or reload. Complete game, all-profile and fitted/hardware gates remain
open. Keep any genuine failure and repair its responsible layer.

At the real HPS-driven gameplay checkpoint240, all57344 raw core pixels
match the canonical MAME image and the settled framework VGA exactly.
The first240 applied port records are complete. This finite current-wrapper
CPU/input/video case is hash-bound in
`research/kyros_earned_wrapper901_v2_gameplay240.json`. It does not qualify
the still-pending earned-score save, reset-clearing or reload operations.

## 2026-10-10 — Separate actual prefix closes earned snapshot coverage

The completed actual CPU/HPS v5 replay earned BCD00002000 (2000 points), uploaded178 bytes, observed the real reset CPU clear the best score, and restored all178 bytes exactly through the real donor. Its original acceptance receipt remains unchanged and retains false finite_feature_pass, canonical_graphics_pass and full_acceptance_pass.

The distinct kyros_earned_prefix181 executable subsequently completed181 actual RTL fields with exit0. All14 fidelity checks passed: all181 applied input ticks and frame statistics match v5, and all14 overlapping RGB artifacts match byte for byte. Its separately captured fields119 and179 match the same canonical MAME displayed RGB reference exactly across57344 pixels each; framework VGA equals actual core RGB. No files were copied into the v5 capture.

The explicit aggregate research/kyros_earned_v5_prefix181_aggregate.json records both executable and private host hashes, both actual terminals, original ROM/input/build pins, canonical newline mapping and separate image provenance. finite_earned_protocol_and_capture_coverage_pass is true. canonical_graphics_pass, full_feature_acceptance and whole_game_acceptance remain false: original field60 still differs by20835 pixels and field900 by8. This scoped coverage result does not qualify arbitrary frames, audio completeness, extended Japan gameplay, Super Stingray, fitted resources/timing or physical MiSTer outputs.
