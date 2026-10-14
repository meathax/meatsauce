# Sheriff audio comparison scope

The retained pre-conversion finite P1 waveform remains a negative. Its report is
`docs/evidence/sheriff_current_audio_negative.json`: native 937008 samples,
MAME 936961, first difference at sample 0, common-prefix RMS error
351.31779211721164 and peak error 6444. Both producers finished successfully.
Neither recording has been shifted, padded or replaced.

These streams have different recording contracts. The native bare-board
harness records the board output on `audio_ce` after the rising-edge evaluation
(`sim/board_harness.cpp:103`). The SN divider resets to zero and emits one
sample every 1050 board clocks (`rtl/sheriff_sn76477.sv:15`, `:53`, `:58`),
giving 48 kHz at 50.4 MHz. Its first post-reset sample is emitted on harness
tick 1049. This tick is derived from the RTL/harness ordering; it is not a
new instrumented capture of the sound-device or WAV epoch.

MAME 0.289 creates the one-bit DAC stream at 1536000 Hz
(`src/devices/sound/dac.cpp:97`) and routes it at gain 0.15; the SN route gain
is 0.35 (`src/mame/nintendo/n8080_a.cpp:96`, `:108`). Its output passes through
the sound-stream resampler. The default resampler is **LOFI**
(`src/emu/sound.cpp:2856`), not HQ. The LOFI implementation averages source
groups when downsampling and uses four-sample cubic interpolation with retained
history (`src/emu/resampler.cpp:402-462`). Its coefficients can produce an
overshoot around a step. The optional HQ Hann-windowed sinc implementation
does not establish which resampler the recorded session used.

The native initial value 4915 and the MAME startup sequence
`0, 0, -90, 4523, 5013` therefore cannot by themselves identify a DAC polarity
or gain defect. Recording epochs, runtime stream rates, selected resampler and
startup history must be bound to the same sound-pin stimulus before a waveform
comparison can qualify the mix. The source inspection above explains an
applicable mechanism; it does not prove the cause of every observed difference.

The focused source-derived calculation now predicts all first32 MAME WAV
samples exactly. `tools/qualify_dac_startup_resampler.py` uses a DAC-high step
at source sample0, zero history, fixed1536000/48000Hz rates, gain0.15, divide33
and the documented LOFI coefficient/phase equations, including float32
rounding. None of these parameters is fitted to the WAV; there is no sample
offset or padding. Native first32 samples are constant4915 as expected before
that output resampler. Actual exit0 and source/PCM hashes are retained in
`docs/evidence/sheriff_dac_startup_resampler.json`. This qualifies the startup
operator mechanism and explains this transient within that scope; full
event/pin timing, mixed-waveform equivalence and the original length difference
remain open. The original raw-versus-WAV negative remains unchanged.

The current1201-field sound-pin capture preserves the entire frozen I/O,
state and WAV files byte for byte. All1331 output-latch events within the
declared1200-field comparison match counts and connected values. P2's external
ROM-mux bits remain outside the latch comparison. Native event times differ by
0..1167 board clocks; these measured deltas are not corrected by a fitted shift.
See `docs/evidence/sheriff_current_sound_pins.json`.

The full DAC output operator is now qualified before the native SN onset:
all780617 samples match the reference WAV exactly. MAME renders through the
current sample on its fixed50Hz graph-update timer; LOFI initializes its phase
from the absolute destination sample on each render call. The source-derived
baseline therefore starts with961 samples and subsequent960-sample blocks.
Carrying the rounded phase through a whole recording was an analytical error.
Exact integer seconds/attoseconds are also necessary: the event displayed as
9.957375000000 seconds actually occurs at9 seconds plus957374999999996830
attoseconds. Decimal12-place formatting moved this event across a source-sample
boundary. The private precision observer preserves all original sound columns,
I/O, states and WAV; it changes neither canonical Lua nor the game.

`docs/evidence/sheriff_dac_waveform_origin.json` binds the actual exit0 capture,
source hashes, exact timestamp arithmetic and original-index diagnostics.
Its analytical native-DAC projection still differs from the reference DAC
operator (RMS29.3501121456 over936961 samples); adding the original native SN
residual gives RMS100.9508866406. These projections explain comparison
mechanisms and never replace the native waveform or pass the mixed-sound gate.
The original raw negative and end-length difference remain unchanged. The
before-native-SN scope is not an independently captured MAME SN-device epoch;
the render cadence is source-derived, not a live render-call trace.

Next, isolate the remaining native event timing and SN contribution using
these frozen captures. Do not alter synthesizable sound timing or add a fixed
delay solely to match an unqualified device/recording epoch. Existing component
tests retain their narrower scopes; they do not pass the release gate.

The first SN PCM residual discrepancy larger than1LSB occurs at sample781185:
native-5231, reference-5079. Both inferred SN contributions first become nonzero
at780617. The frozen enabling command selects sample780386 under the respective
native/MAME stream contracts, so the larger difference is after800 charge
updates. Source-derived binary64 accumulation gives3.6999999999999758V and
gain index36; the production Q32 increment19864224 gives3.700000047683716V and
index37. The current negative gain entries are-5080 and-5231 respectively.
This shows an applicable numerical gain-boundary mechanism without a measured
live capacitor-state claim. `docs/evidence/sheriff_sn_gain_boundary.json` binds
the commands, equations and source hashes. It does not explain all later
waveform differences or authorize an arbitrary bias/delay in the sound engine.

The gain ROM conversion has since been corrected separately. Its old generator
rounded a32767-scaled value; MAME normalizes device voltage, stores a float,
multiplies by the float0.35 route gain, then truncates32768-scaled PCM. The
generator and independent floating component reference now preserve those
operations (`sn76477.cpp:608`, `:1971-1996`, `sound.cpp:1016`). Thirty-eight
of90 gain words change, without added state or clocks. The native96000-sample
capacitor/mode corpus completes with actual exit0, zero PCM error and zero
noise/VCO comparator differences. Evidence:
`docs/evidence/sheriff_sn_pcm_quantization.json`; local recovery:
`_checks/sn-pcm-quantization-20261010/`.

Earlier complete-board and wrapper captures retain their recorded source
identities and original negatives. They predate this ROM-word correction and
do not qualify the new integrated source. Q32 capacitor-boundary behavior,
DAC output-operator differences, final mix quantization and later waveform
divergences remain open. No fixed delay or capacitor bias was introduced.
## Receipt-backed SN gameplay component replay (2026-10-10)

`docs/evidence/sheriff_sn_gameplay_replay.json` binds the completed native
dual-chip replay to actual exit 0, unchanged source hashes, the ELF and frozen
real-8080 output writes. All 937,008 old-chip samples reproduce the original
full-board SN contribution exactly. Old and corrected chips have identical
capacitor states on every board clock; the corrected gain conversion changes
25,485 output samples. Against the reference WAV minus the independently
qualified DAC projection, 2,286 common-prefix samples still differ, RMS
96.58559198 LSB, peak 6,444 LSB. This is a component replay, not fresh current
full-game execution or a whole-sound pass.

The first residual difference is sample 781,185: native AD voltage
3.700000047683716 V selects gain index 37, producing -5,231. Source-calculated
MAME binary64 accumulation selects index 36, producing -5,079. The first
difference larger than 1,000 LSB is sample 811,952 in the second mono1 burst.
The 1,000-LSB threshold locates a diagnostic window; it is not an acceptance
tolerance and does not exclude earlier differences.

`docs/evidence/sheriff_sn_control_sampling.json` predicts matching first starts
(sample 780,386), then native/reference expiries 809,135/809,136. The second
start is 811,592/811,593 and expiry 840,342/840,343. These positions derive from
registered native latch/monostable edges and MAME's old-prefix stream-update
rule. Exact private MAME SN timer/stream state is not independently captured.
Test the predicted phase mechanism using source equations before proposing a
control delay or arithmetic change. No sample shift, fitted bias or RTL timing
adjustment is justified by this diagnostic alone.

Recovery: `_checks/sn-gameplay-replay-20261010/terminal-v3.json` and
`source-binding-v3.json`, with native outputs in `run-v3/`. The original lost
OS receipt and the v2 WSL connection failure remain retained separately. The
successful v3 outputs are byte-identical to the original completed data; do
not repeat the unchanged replay.

### Frozen-waveform mechanism qualification

`tools/diagnose_sn_control_waveform.py` tests the phase prediction without
moving samples, fitting parameters or changing RTL. The first-two-burst case
checks 840,407 samples: the Q32 shadow equals the actual current native chip
exactly; native-timed binary64 differs from that chip at only sample 781,185
(152 LSB). Applying source-derived reference trigger/expiry positions and
the qualified exact DAC/float-mixer operator matches every original WAV
sample. See `docs/evidence/sheriff_sn_control_waveform.json`.

The justified extension `--all-mono1` covers all five separated mono1 bursts
and all 936,961 available reference samples. Q32 shadow versus actual native
SN remains exactly zero. Native-timed binary64 differs from the chip in only
two samples (peak 152 LSB); with native control positions the projected
floating mix differs from the reference at 657 samples (RMS 96.58539304 LSB,
peak 6,444). With independently source-derived reference positions, the
projection matches all reference PCM samples exactly, including the final
float mix before conversion. See
`docs/evidence/sheriff_sn_control_waveform_all_mono1.json` and recovery
`_checks/sn-control-waveform-all-mono1-20261010/`.

This closes the analytical explanation of this finite recording: control
sampling produces its large waveform differences; Q32/binary64 gain-index
selection produces two isolated chip-level differences. It does not change
the retained native/reference negative or establish that reference stream
timing is the physical board timing. Mono0/overlap and other sound classes,
current integrated lifecycle, physical audio and timing/resource gates remain
open. Keep native waveform/sample indices and hardware unchanged until
physical evidence supports a production change. Reuse these completed cases.

## Current real-board gain integration closure (2026-10-10)

The corrected gain constants were rebuilt with the actual board, VM80A and8035 kernel and run from cold ROM download through1201 fields with ordinary frozen inputs. Actual native/workflow exit0. All937008 native audio samples equal the qualified current SN component contribution plus the unchanged DAC reconstructed from the prior board/old SN pair;25485 samples change exactly as predicted. Startup/I/O/memory-write/sound journals and25 RGB/25 RAM snapshots remain byte-identical. The current and staged source closure, model/runner and every report artifact hash verify independently. See docs/evidence/sheriff_current_gain_integration.json and _checks/current-gain-integration-20261010/independent-artifact-verification.json.

This is a saved same-side current-board integration regression, not admitted live MAME equivalence or whole audio acceptance. It covers the five mono1 bursts in the finite P1 scenario. Preserve the original raw-versus-WAV negative, Q32 boundary differences, hardware enable/retrigger uncertainty, mixed-control/current-wrapper sound and later graphics/lifecycle/resource gates. Do not repeat this unchanged completed run.


### Connected mixed delivery regression (2026-10-10)

The frozen qualified cocktail prefix now has a fresh actual connected audio-subsystem run with the production controller, real8035 ROM and corrected/old SN models. All1439875 PCM samples match the old actual-board output and predicted corrected gain plus actual DAC;109106 samples change as predicted. All1768 PC/P1/P2/DAC transitions match. Native/workflow exits0, independently verified source/fixture/snapshot/model/receipt hashes. Mono0 cancellation at1455137495 and mono1 overlap at1481613520 preserve enable high; both timers expire by1511800600. Evidence `docs/evidence/sheriff_mixed_audio_connected.json`; recovery `_checks/agent-audio-current-mixed-20261010/`. This reuses frozen actual8080 latch writes; it is not fresh mainCPU execution or current full-wrapper sound acceptance. Do not repeat it unchanged.

Retain the original132 source-ordered versus106 atomic starts, waveform negatives and original mixed component OS receipt UNKNOWN. The primary SN74123 propagation audit in `docs/AUDIO_CONTROL_TIMING.md` supplies conditional typical/max values only; missing minimums, exact wiring/load and SN enable response prevent a guaranteed ordering or physical retrigger conclusion. No fitted disable/re-enable pulse or production timing change is justified. Whole-audio classes/current-wrapper and named analog/noise limitations remain required.

### Connected active MCU/DAC pause preservation (2026-10-10)

The focused real8035/74123/SN fixture completes 31,000,000 logical clocks with actual native/workflow exit0. Nine pause windows add74,572 physical clocks across idle, mono1, retrigger, mono0 cancellation, overlap, active persistent MCU IRQ and expiry. Both production audio lanes preserve18 exposed state fields and sample_ce exactly after every resumed edge; all29,523 sample events match, including24,646 nonzero SN samples,295 MCU port transitions and293 DAC edges. Paused clocks emit no sample event and preserve PCM, capacitors, noise RNG, divider, timers, crystal accumulator and MCU ports/address. Source-bound evidence is docs/evidence/sheriff_audio_pause_connected.json; local recovery _checks/audio-pause-work-20261010/. The prior eight-case idle-MCU pass is retained in idle-baseline/.

Reproduction: Ubuntu WSL python3 tools/qualify_audio_pause_connected.py <absolute repository Linux path> <unique label>. The harness uses synthetic sound-latch commands and real parent sound ROM. This qualifies connected pause/resume preservation and native cancellation/retrigger/overlap semantics, not gameplay sound classes, current fullwrapper mixing or physical132 source-ordered versus106 atomic retrigger applicability. Keep whole_audio_gate_pass=false and reuse this completed check unchanged.
