# Sound hardware integration checkpoint

Source base: 7c269ba; user Quartus hold: 82bfaf1. This is P5 implementation
progress, not complete game-audio or physical sound acceptance.

The staged JT03 source closure uses jt12 dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257
and its nested jt49 7f6abfd08a2af9a92dbd5b32c71ea773248a77e2 unchanged.
The two external AY chips use jt49 47301ed51374d6d41db4db846b7643fecf75e417
in the separate a68n_ay49 namespace. Original sources, license notices and full
GPL licenses remain under rtl/vendor/. audio_sources.json binds every original
and staged file hash; scripts/stage_audio_sources.py reproduces the closure.

External AY configuration: SEL=1, CLKDIV=3, MUTE_NULL_PERIOD=0. Period zero
therefore behaves as one. The external exponential lookup quantizes the donor
32-step envelope to AY's 16 levels without changing the complete cycle time.
Separate fixed/envelope curves use MAME 0.289's active AY resistor model with
the default 1000-ohm load, normalized to eight-bit donor channel amplitudes.
The envelope restart latch/edge history explicitly reset. JT03's own YM SSG
and version remain intact. This does not establish physical analog accuracy.

alpha68kn_soundchips uses one 48 MHz master and a /24 enable for all three
2 MHz chips. It implements YM address/data at 10/11 and AY data/address at
80/81 and 90/91, independent register latches and device readback. Only YM
chip-select follows YM queries. Unconnected chip I/O inputs are tied FF.
alpha68kn_audio connects the bank to alpha68kn_mixer. The mixer has wide Q16
terms, pipelined addition, exactly 48 kHz sample enables and one final signed
saturation with a clipped-sample counter. Nominal MAME routes: FM/internal SSG
and AY1 .30, AY2 .60 for Kyros/Japan or .45 for Stingray, DAC .50.
Legacy PSG conversion includes MAME's half-scale and negative offset; unsigned
DAC maps code 128 to zero. No analog filter or MAME frontend adaptive limiter
has been invented here. Donor level quantization and real-game gain/clipping
still require calibration against captured audio.

Verified isolated chip contracts: register masks/independence; all 16 fixed
levels; tone period 0 and 1 both 384 master clocks per waveform, period 37
14208; 16-level envelope changes every 192 clocks for period zero and 1152 for
period three; YM timer-A status/IRQ/clear; warm reset. Native donor build and
run exited 0. Evidence: research/soundchips_build_exit.json,
research/soundchips_contracts.json, research/soundchips_contracts.log,
research/soundchips_inputs.sha256. Six independent floating-reference mixer
vectors pass within one PCM LSB, including both saturation directions,
profile gains, 48 kHz cadence and reset. Complete audio-top lint and mixer
build/run exited 0: research/mixer_build_exit.json,
research/mixer_contracts.json/log, research/mixer_inputs.sha256.

These modules are not yet connected to the real Z80 board or active hardware
QIP. Next: real board I/O readback, connect audio to the shared system, capture
actual game register events/WAV and calibrate routes/clipping; retain the
existing live-graphics comparison. No P5 catalogue item is closed merely by
these isolated contracts. Quartus remains forbidden until explicitly
authorized again, so full-design fitting/timing remains pending.

## Real CPU integration (2026-10-09)

alpha68kn_system now connects board I/O writes, live Z80 read queries and
chip read data to alpha68kn_audio. alpha68kn_board qualifies I/O reads before
its synchronous program-ROM/RAM mux; a port read no longer aliases a low ROM
address. The existing zbus_done transaction latch ensures one write pulse.
DAC writes have a separate observation pulse, including repeated values.
The native shared-system harness records actual I/O/DAC events and captures
48 kHz raw PCM16. Its final audio.json exposes write counts and clipping.
The 1800-field Kyros run is pending; this connection and a successful build
do not establish music/effect fidelity, reset qualification or B03-B06 closure.
The inactive audio QIP and unfinished framework wrapper still require P8
integration. Quartus use is explicitly on hold.
