# Target sound provenance

`ZeroTeam_audio.sv` adapts the normal Seibu sound latch and interrupt logic
from `rtl/Raiden/Raiden_audio_z80.sv` in
[rmonic79/Arcade-Raiden_MiSTer](https://github.com/rmonic79/Arcade-Raiden_MiSTer),
commit `28cd62a632f8a5c12dfc81e0882b9869ac57940d`. Original author:
Umberto Parisi; GPL-3.0-or-later. The original notice is retained.

Changes on 2026-10-04: Zero Team's plain raw 64 KiB sound ROM, bank write at
`401a`, exact OKI address `6000`, 96 MHz clock-enable ratios, real Verilog
TV80 in place of the VHDL T80, target mono FM/ADPCM mix, and a single pulse
per completed FM sample. The donor's optional savestate/replay/backdoor and
OSD gain machinery is excluded; sound savestates are not implemented.
`scripts/stage_zero_audio.py` records the donor extraction and adaptation.

The authoritative target map, ROM_CONTINUE/ROM_COPY arrangement, chip clocks,
pin 7 and mixer routes come from the staged MAME 0.289 `raiden2.cpp` and
`src/mame/shared/seibusound.cpp`. No program or sound ROM is patched.

JTOPL2 is copied from that same pinned Raiden donor into `rtl/sound/jtopl/`;
all original Jose Tejada GPL notices remain. JT6295 is the already-imported
Raiden II copy, with coefficient paths made explicit for the project root.
The five TV80 sources and their original permissive copyright/license
notices are retained in `rtl/tv80/`; their source hash inventory is recorded
by the audio evidence generator alongside the pinned donor manifest.

The production module is used directly in the live Verilator board.
It is also used by the MiSTer platform wrapper; final integration acceptance
is tracked in progress.md.

The target clock dividers are initialized at FPGA power-up and continue through
sound reset. Reset overrides the pause clock gate so JTOPL2 receives its required
enabled reset clocks (at least six, per jtopl2.v). The prior reset-held divider
phase suppressed these clocks and produced spurious sound before any note was
keyed on. The original-ROM quiet-start regression is recorded in
docs/evidence/audio-reset-clock.json. No donor synthesizer logic was changed.

2026-10-08 audio quality changes (Zero Team additions, no donor synthesizer logic changed):
- Mix now follows the MAME 0.289 zeroteam routes: FM unity, OKI 0.40. JT6295 with
  INTERPOL=1 outputs 2x a MAME ADPCM unit (measured), so the OKI weight is 205/64.
  The earlier 1/2 FM + 1x OKI mix was 6 dB low and ~10 dB short on OKI.
- Pipelined soft limiter (unity to 24576, slopes 1/2 then 1/8, full scale at 53248)
  replaces the hard clip.
- `ZeroTeam_resample48` (same file) converts the 49.716 kHz mix to exactly 48 kHz with
  an 8-tap Lanczos-4 interpolator (table from scripts/gen_resample_table.py); the
  platform's AUDIO_L/R now use `out_l/out_r`. `audio_l/r/audio_sample` keep the native rate.
- Evidence: sim/results/audio-replay-mix3 vs MAME reference.wav (rms within 3%, 20 Hz-6.4 kHz
  bands within ~1.5 dB); `sim/run_audio48.sh` + `scripts/check_audio48.py` (SNR 45.5 dB).

2026-10-09 sound-effect crackle fixes (Zero Team additions, no donor synthesizer logic changed):
- Root cause: JT6295 latches ADPCM bytes from its ROM bus without a rom_ok wait
  (~750 clocks after each address change at 96 MHz). On hardware the OKI ROM is
  SDRAM port 3, which `sdram.sv` mode 1 served strictly last, behind video and
  both CPU ports. With main V30 + COP missing back-to-back the port starved, so
  stale bytes were decoded as ADPCM nibbles: pops/crackle on sound effects. The
  sound sims fed the OKI ROM with zero latency and could not see it.
  `sim/contention_main.cpp` now drives port 3 with the JT6295 slot pattern and
  counts late bytes: before 1154/1154 late (video+CPU+COP), 624-clock worst
  case with CPU only; after 0/1154, worst 46 clocks; sprite/tile deadlines and
  frames unchanged. Fix: port 3 now ranks right after video in mode 1.
- The OKI output (4x FIR, ~31 kHz steps) was sample-and-held on the 49.7 kHz FM
  grid, folding images to 15-20 kHz (grit). It is now linearly interpolated
  over a fixed 3004-clock span, latched 384 clocks after each OKI step (FIR
  result lands after 279). Modelled error vs ideal: -18 dB -> -31 dB.

2026-10-09 OKI wraparound clicks (the remaining crackle after rc3):
- Root cause: the JT6295 copy shared by every Seibu donor (rmonic Raiden/Raiden II etc.)
  changed `jt6295_acc.v` to feed the 4x FIR `{sum,2'b0}` (x4) instead of upstream x2,
  but still output `fir_dout[13:0]`. The FIR gain became 2x and the 14-bit truncation
  wrapped whenever |4-voice sum| passed ~3250, flipping loud overlapping effects to the
  opposite rail. Restored upstream x2 and saturate to 14 bits; OKI mix weight 205/64 ->
  410/64 (same level). Also restored upstream `jt6295_adpcm.v` 14-bit predictor clamp
  (jotego/jt6295 7d76b0b): the donor's 13-bit clamp saturated to the wrong rail when
  |predictor +- qn| >= 4096 (5578 of 3.2M decoder input cases; rare in recorded play).
- Evidence: `scripts/oki_overflow_audit.py` (JT6295-exact model of recorded OKI writes):
  combat-4p 155, combat-2p/mix3 111 wrapped FIR outputs in ~33 s; upstream x2: 0.
  RTL replay of mame-play-1800-combat-4p-audio-pins, HEAD vs fix: bit-identical except
  23 bursts (281 samples) where HEAD jumps ~50k counts (e.g. -19052 -> +24996 while the
  fixed output continues to -28112). Median |diff| 0, p99.9 7.
- "Muffled": the OKI runs at 7.75 kHz (PIN7 high, MAME-confirmed), so its content stops
  at 3.87 kHz on the PCB too. The core's FIR is flat to 3 kHz; MAME 0.289's default lofi
  resampler is duller (-3.1 dB at 3 kHz). MiSTer's default audio IIR is flat to 12 kHz.
