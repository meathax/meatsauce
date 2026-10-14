# YM2203 SSG normalization correction

MAME0.289 uses YMFM for the YM2203's internal SSG. Its `ymfm_ssg.cpp:175` amplitude table is positive, from0 to16382 per channel. `ymfm_mame.h` submits these values to the sound stream with denominator32768. The Alpha68k N driver routes all YM2203 outputs at0.30. The separate AY8910 devices use legacy biased normalization. Their numerical ranges must be treated separately.

The earlier mixer applied the standalone AY bias to the YM2203 SSG as well. This added an incorrect -3686.4-sample quiet offset. `alpha68kn_mixer.sv` now scales the JT03 raw channel sum by `round(16382*0.30/255*65536) = 1263071`, with zero SSG bias. The standalone AY routes and DAC conversion keep their source-specific normalization. A40-bit Q16 sum saturates once into signed16 PCM at48 kHz.

| Interval, seconds | MAME mean | Earlier real-system mean | Corrected actual sound RTL mean |
| --- | ---: | ---: | ---: |
| 0.1–1.0 | -23347 | -27034 | -23348 |
| 10–11 | -11059 | -14746 | -11060 |

The remaining one-sample difference is retained. The older nominal mixer contracts included the wrong YM bias; their passes validate that older arithmetic only. The current independent floating oracle uses the YMFM peak/zero bias and the separate AY formula. Seven vectors,35 sample pulses, both clipping signs,48-kHz cadence and reset pass. See `research/mixer_ymfm_contract_manifest.json`.

## Actual RTL replay and limits

`sim/audio_replay_main.cpp` replays the real CPU run's recorded37908 sound writes through the actual JT03/JT49/audio/mixer RTL. The recorder observes board pulses after an edge; replay presents them to the consumer on the following edge. All7088 I/O and30820 DAC writes are applied. The1800-field duration produces1459814 samples with zero clipping, range -27444..14577. This write-only diagnostic does not replace actual CPU/game boot, readback, input or gameplay acceptance.

Evidence: `research/audio_ymfm_normalization_reference.json`, `audio_ymfm_prechange_stats.json`, `audio_ymfm1800_qualification.json`, `audio_replay_ymfm_inputs.sha256`, `audio_replay_ymfm1800_exit.json`; ignored WAV and per-second component statistics in `sim/captures/audio/kyros_ymfm1800/`. Replay ELF8700fe96f9f25cc41d0b4aaf5811f85c23ef79d54fafc24291a78e7bb0d0f68c.

`research/audio_ymfm_spectrum.json` compares four finite absolute-time Hann windows without a time offset. The32768-point FFT bin is1.46484375 Hz; its analytic1-kHz calibration error is0.0227 Hz. At2/3 seconds the AC-level ratios are1.0068/1.0058 and the six selected peaks differ by less than0.002 Hz. At29 seconds selected strong peaks agree within0.444 Hz, but the AC ratio is1.1178. At20 seconds the AC ratio is1.0927 and matching only the strongest12 peaks leaves ambiguous correspondences. These are diagnostics, not automatic pitch or waveform passes.

Per-source isolation is still needed to explain the late9–12% AC-level difference, distinguish donor amplitude/phase behavior from a frequency problem, and finish action/effect coverage. MAME0.289's inspected Lua sound interface exposes a boolean `hook` and no `set_output_gain`; do not assume that `hook` is a sample callback or invoke an unsupported gain setter. Inspect its actual sound-routing/capture API before the next observer.

The active full-core attract recording uses the earlier pinned executable. Its CPU/graphics evidence remains tied to that source manifest, and its audio must be labeled with the earlier mixer. All final game acceptance must use the current design. Quartus, resource/timing and physical audio remain unqualified under the user's hold.

## 2026-10-09 — source observer and SSG transfer

The previously pending per-device observer is complete: CPU-state rows and
mixed WAV are unchanged. The next defect was the internal SSG compression and
fixed-volume indexing. docs/YM_SSG_CURVE.md records its reproduced adaptation
and retained silent-import failure. Corrected replay completed1,800 fields: SSG ratios1.004409/0.981642/0.994365,
combined WAV ratios1.04128/1.01463/1.01715 at seconds15/20/29, with zero rail
samples. Current full-system Kyros/Japan and explicit effects remain pending;
no whole-audio acceptance is implied.
