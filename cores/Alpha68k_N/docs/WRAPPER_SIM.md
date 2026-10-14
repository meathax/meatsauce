# Actual wrapper transport and boot simulation

sim/build_wrapper.sh builds Alpha68k_N.sv with the real hps_io, fx68k, T80,
renderer, palette, sound chips/mixer and SDRAM controller. sim/wrapper_main.cpp
sends the actual HPS user/file commands; it does not drive private ioctl
registers, replace CPUs or inject game state. Every accepted ROM word is
audited against its packed address/data. Joystick/start/coin mapping and
orientation status are exercised through hps_io before boot.

ALPHA_EMU_SIM exposes ideal 48 MHz PLL outputs, its forwarded half-cycle SDRAM
clock and diagnostic outputs. The host drives only HPS-owned bus slices via
SIM_HPS_HOST; hps_io supplies response bits. These ports/drivers are absent
from the production interface. The pinned production PLL and sys/ stay
unchanged. The temporary video_mixer net-scope adapter is explicit; see
FRAMEWORK_BOUNDARY.md. Reference-clock/lock dynamics, physical setup/hold,
audio-domain crossing and DDR bandwidth are not qualified by this test.

Three initial failures are retained. Sampling SDRAM's initial zero-valued
pins before reset edges produced an invalid mode command; the driver now
uses the same two reset-settling edges as the established system harness.
Driving HPS_BUS directly from C++ failed because generated response logic
overwrote the input pins (mask 0x000000310000ffff); independent external pin
drivers correct the model without bypassing hps_io. The first VGA field also
exceeded the initially allocated visible-image buffer. Captures now retain
all actual samples: field 0 has 57,602 samples, rather than 57,344, and its
172,806-byte VGA capture is explicitly unqualified. Nothing is cropped or
padded to conceal that startup result. The existing four-field framework
settling window is used before strict core/VGA equivalence checks.

The corrected run completed 96 fields, exit 0, ELF SHA-256
88352a15f9a1efd81d8152cf62e078f2b0ad5cf58935046e7760de1ad82ececc.
All 327,680 ROM words were audited; FIFO backpressure consumed 2,006,830
master cycles. There are zero unmapped accesses, renderer deadlines,
overflows or duplicate core pixels. Every field 4..95 has 57,344 core/VGA
pixels and exact paired RGB. Core fields 0/30/90 and qualified VGA fields
30/90 also match canonical MAME displayed images byte-for-byte. At field 95
the real 68000 has completed 2,155,467 transactions.

Evidence: research/wrapper96_qualification.json, wrapper96_settle_exit.json,
wrapper96_settle_inputs.sha256 and wrapper96_settle_scope_adapter.json;
captures/frames/result under sim/captures/rtl/kyros_wrapper96_settle/.
Earlier failures are in wrapper96_exit.json, wrapper96_reset_exit.json,
wrapper96_host_exit.json and the corresponding diagnosis files. Both
production-interface elaboration modes pass in wrapper_production_lint.json.

The separate rotation fixture verifies all 57,344 clockwise pixel addresses
in a 224x256 framebuffer, stride 896, with zero missing/different pixels or
out-of-bounds writes. Disabling rotation stops framebuffer writes. Its DDR
endpoint is always ready and its game field repeats; this is an address/data
contract, not live gameplay or physical DDR qualification. Evidence:
research/framework_rotation_{build,run,result}.json and its source manifest.

This is a finite boot/boundary result. Later gameplay, the newly observed
frame-900 difference, DIP/CRT/pause/hiscore features, other profiles and
complete resource/timing/hardware gates remain open. Quartus is disabled.


## DIP bank transport (2026-10-09)

The wrapper's `DIP;` entry exposes HPS settings; index254/address0 supplies the low byte to the real board, initially0x8E. Bank/address/byte isolation, restore, controls and orientation pass through actual HPS in `--host-only` mode. The test checks that DIP transfer leaves the ROM gate and CPUs held in reset.

A subsequent31-field real wrapper boot audits327680 ROM words and passes core/VGA pairing for fields4–30. Core0/30 and VGA30 match canonical MAME with zero differing pixels. Field0 VGA still retains its extra258 samples and is unqualified. Evidence: `research/wrapper_dip31_qualification.json`; source/adapter pins: `research/wrapper_dip_inputs.sha256`, `research/wrapper_dip_scope_adapter.json`; ELF343dd175ec068226223361673fd71332a403c5d49944ac51e9a9184b4bfa1704. This does not qualify all DIP settings, generated MRA labels, physical PLL/DDR, or Quartus results.
