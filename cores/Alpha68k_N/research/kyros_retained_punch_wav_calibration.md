# Retained Kyros punch PCM calibration

One read-only comparison reused the existing qualified native punch1081 and MAME component capture. It made no CPU replay, simulation build, state change, filter, or normalization. The exact accepted command sequence across fields712–736 agrees; two original PCM16/48kHz excerpts spanning that guarded effect interval are retained under sim/captures/diagnostics/kyros_retained_punch_wav.

The pre-command native baseline is -27444 for all480 inspected samples; MAME is -27443. Measured MAME postroute device means are AY1 -3686.4, AY2 -7372.8, DAC -16384, FM/SSG zero. Their sum -27443.2 floors to the actual native Q16 PCM baseline. This checks one combined nominal route/DC state; the reference AY2:AY1 DC ratio is2.0. It does not individually measure every dynamic native route.

Both short excerpts contain changing audio and zero endpoint saturation. A512-sample interior mixed-noise/FM window has dominant FFT bins1968.75Hz native and2062.5Hz MAME, one93.75Hz resolution bin apart. AC RMS is1468.98 versus1288.71 (+13.99%). This measured difference remains visible; no new loudness tolerance converts it into a balance pass. The mixed dominant frequency is not an isolated chip pitch or the AY LFSR update frequency, and short random-noise windows are phase-sensitive statistically.

All six finite checks passed with an actual verifier exit0. No waveform-bit identity is required by P5. Exact sample-epoch alignment beyond the retained common command/field interval is unproven; raw excerpts and statistics support finite comparison only.

The remaining smallest audio calibration gap is individual FM/SSG/AY pitch and dynamic route amplitudes: retained MAME sound_components.csv provides aggregate20ms statistics, while the original native punch capture has final mixed PCM only. Reuse existing source-valid isolated production-chip frequency/mixer receipts first. If those lack the necessary samples, capture only isolated production chip outputs using the already accepted commands; a further CPU playthrough is unnecessary. Hit/jump/pickup/game-over/restart semantics and broad P5/B03–B06 acceptance remain open.
