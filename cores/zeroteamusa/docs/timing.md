# Zero Team timing qualification

Work stopped at the user's request on 2026-10-06. Timing closure is **not
established**. The latest completed all-corner audit,
`sim/results/timing/audit-41ad1ef585b3468781011c34b4b0fa17`, has setup failures
at all four slow models; the worst is -0.651 ns from the CPU `addr_lat[14]`
to `rdata_q[1]`. The subsequent parallel address-decoder change passed all
134,217,728 equivalence comparisons, but has not been synthesized, fitted
or audited. No RBF was built. Resume with a fresh map/fit/STA qualification
before treating this source as timing closed.

The development workflow runs Quartus 17.0.2 analysis/synthesis, fitting and
TimeQuest. It never invokes the assembler or RBF conversion. An RBF build
requires a separate explicit user request.

```powershell
./scripts/check_timing.ps1 -Stage All
./sim/test_timing_results.ps1
python sim/run_timing_audio_phase.py
wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\zero --exec bash sim/run_irq_phase.sh
wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\zero --exec bash sim/run_sdram_pin_checks.sh
```

`-Stage Sta` reuses a completed fit only when its hardware source identity
matches. Constraints and the audit scripts are included in the run snapshot;
changing inputs during a run invalidates its result. Optional SDC overlays are
checked for a valid filename and actually loaded before their results count.

## Acceptance and evidence

The compact committed result is `docs/evidence/timing-closure.json`. Native
reports remain under the audit directory recorded there, inside the ignored
`sim/results/timing` tree. Reproduce them with the commands above.

TimeQuest enumerates all available device conditions, recreates the timing
netlist independently for each, and checks setup, hold, recovery, removal and
minimum pulse width. The current device has eight conditions: slow and fast
models at -40, 0, 85 and 100 degrees C, all at 1100 mV. A missing model,
analysis, finite slack, constraint report or coverage summary fails validation.
A failed fit still reports every condition before rejection. A passing run
requires all 40 analysis results and zero unconstrained setup/hold clocks,
input/output ports and port paths.

Constraint review also rejects loops, latches, invalid PLL/generated clocks,
missing uncertainty, inconsistent/partial multicycles and partial I/O delays.
The workflow rejects TimeQuest's fallback to zero source latency when a
generated clock has no physical path from its declared source to its target.
Unclocked synthetic HPS model nodes are explicitly inventoried by their hard-IP
names; an unclocked fabric register fails validation. The framework's HDMI
clock mux intentionally feeds registers from both direct-video and scaler
clocks. Both forwarded-clock paths receive independent setup and hold reports.
This review does not convert hard-IP model placeholders into fabric clocks.

## Clock and interface contracts

The game fabric remains 96 MHz. The existing core PLL now supplies a second
96 MHz output at 1302 ps (45 degrees). Its inverted DDIO output forwards
SDRAM rising edges at 225 degrees relative to fabric. Commands and input
capture use the core rising edge; both internal handoffs get a full cycle.
The memory remains CL3, single-beat reads and masked single-beat writes.
Completion gains one register stage. Its saved request tag is forwarded into
the grant logic, preventing a held request from being granted again before
its acknowledgement register updates. The controller retains its eight-cycle
command cadence; completion latency increases by one 96 MHz cycle. The
four-port pin test checks this cadence, completion data and absence of
duplicate transactions after all requests retire.

All 16 read inputs use setup two/hold zero to select the actual single-beat
launch and disable edges. READ+2 launches the CL3 first beat; capture occurs
1.375 periods later, after the following SDRAM edge, and READY commits it on
the following fabric rising edge. Setup retains the full tAC/pad budget; hold
checks the following edge's tOH/tHZ, 0.375 periods before capture. Subtracting
a hold cycle would incorrectly relax this check. The
internal full-cycle handoffs have no exception.

The hiscore read-wait comparison uses equality tests for the zero/one-cycle
cases instead of a wide subtraction in its counter feedback path. This
preserves unsigned wrap and dynamic hold values. The actual RTL predicate
passes 1,441,792 equivalence checks across every 16-bit hold value, both
read-pipeline settings, timer boundaries and random 32-bit timer values.
Sprite X coordinates combine the disjoint tile/column offset fields before
adding the signed origin, removing one serial carry chain without changing
cycles or pixel placement. The production expression passes 1,048,576
comparisons over all 11-bit origins, tiles, pixel columns and flip settings.

The OPL history shifts and sine ROM address registers share the operator
enable. A production-generator/divider test with pauses and reset clocks
measures minimum spacings of 26 sound clocks and 107 operator clocks. Their
named shift-to-ROM paths use a conservative two-cycle setup/one-cycle hold
constraint; MMIO configuration flags retain full-cycle timing.
The OPL gain stage bypasses its general multiply/clamp at exact unity gain,
which all nine core channel gains select. Every signed 13-bit sample, rhythm
state, eight-bit gain, and normal/rhythm/default slot selector was checked
against the original arithmetic: 33,554,432 comparisons. Slot, rhythm/MMIO
flags and the gain-register output to the accumulator retain full-cycle timing;
this optimization adds no latency and preserves configurable gain behavior.

The CPU address decoder uses parallel aligned-window predicates instead
of a serial priority chain. Decoder outputs were compared to the original
RTL at `fd97f89` for all 134,217,728 input combinations, including every byte
address, bus enable, board mode and bank setting. This preserves decode
holes, exclusive sprite-buffer selection and bus latency.
The high-score wait timer uses parallel byte borrows for its 32-bit decrement,
preserving wrap and all delays while shortening carry propagation. The actual
function passes 1,835,008 comparisons covering byte borrow boundaries and
random 32-bit values.

The core and scaler clocks use 0.350/0.300 ns setup uncertainty for internal
same-clock paths, exceeding their native 0.290/0.200 ns values. Placement
seed 2 targets this additional setup margin at unchanged clock speeds.
External interface bounds retain their independently derived uncertainties.

The hold predecessor is cached in the same configuration write as the hold
value, removing its subtraction from the feedback path. The four-entry
configuration tables use explicit word registers with their existing
registered read behavior; the score-data buffer retains automatic storage
inference. A 65,536-cycle test covers both ports, every address pair and
read/write combination, same-address writes and cross-port old-data reads.

The pin-window tests exercise
this first-beat relationship and reject a different CAS/burst mode. They
include delayed returns and require a zero-pad model to fail its valid-window
assertion; a zero-delay model cannot qualify physical SDRAM capture.
SDRAM pin contracts are tAC/board delay <=6.0 ns, earliest return
>=2.5 ns, output setup 2.0 ns and hold 1.3 ns. These are the qualification
bounds for the installed memory/board, not a guarantee for every SDRAM module.

The HDMI data/control drivers use maximum supported current; the forwarded
clock uses 4 mA plus a 150 ps programmable buffer delay on both edges to
balance setup and hold at the receiver. Both scaler and direct-video forwarding
include the physical DDIO inversion. The ADV7513 Rev B data sheet requires
1.8 ns setup and 1.3 ns hold; constraints add 0.5 ns board skew, requiring
2.3 ns setup and 1.8 ns hold. The audit covers the declared PLL frequencies,
including the framework's 148.5 MHz scaler clock. Runtime HDMI modes above
that rate require separate qualification.

Source: https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf

IO-expander I2C and audio pin routes have paired 20 ns maximum/zero minimum
bounds, with actual data delays reported separately. IO_SDA hold is excluded
only at the asynchronous external input; internal sampler-to-consumer paths
remain timed. The production audio CE generator and I2S RTL are tested across
48/96 kHz operation, rate changes and reset. The one-audio-cycle route budget
is conservative against their measured bit-clock phase spacing. The generated
bit clock is declared at its originating register, so forwarded copies cannot
conceal an unclocked register.

HPS/software-polled HDMI interrupt and I2C inputs, LED outputs, and analog DAC
pins have explicit protocol-appropriate exceptions. SD SPI pins are disabled
by this target. Independent root clock domains follow the framework's
asynchronous groups; the SDRAM source, capture and forwarded clocks stay in
the same related group. PLL and reset recovery/removal/pulse checks remain
part of every condition.

## Enable-domain exceptions

The existing exceptions select specific enabled state, rather than relaxing
all CPU paths. V30 EU, BIU and packed microcode registers share the CPU CE;
setup five/hold four is conservative against the measured minimum six-clock
CE gap. IRQ half-phase capture is CE+2 and has at least four fabric clocks
before the next CPU CE. Bus/status phase boundaries retain their separate
explicit scopes. The production phase test covers resets, stalls, pause and
rapid IRQ changes. COP and TV80 same-enable boundaries use setup two/hold one;
ungated inputs, reset and interrupt paths do not inherit those exceptions.

Physical synthesis register duplication is enabled to reduce control fanout.
Retiming is disabled to preserve
the named enable-domain boundaries. Combinational optimization is enabled.
Otherwise fitter-created shadow registers can escape an explicit CE scope
and leave real single-cycle checks on a multicycle microcode operation.
Generated endpoints are not broadly relaxed to hide that failure.

Sprite tile-code arithmetic uses carry-save reduction followed by one
carry-propagating addition. ROM address fields are concatenated because their
bits do not overlap. Both changes preserve every value and clock cycle. The
actual RTL passes 268,435,456 equivalence checks over every 16-bit code and
all 4-bit tile-coordinate/height values, including address packing.
Raster targeting shares one low-byte increment between both flip modes.
The upper-bit rule preserves the original row-255 special case and the full
nine-bit raster range. All 1,024 row/flip combinations match the original
expression, with no added rendering cycle.

The memory bounds use the ISSI IS42S16320B -6/-7 CL3 specification: access
<=5.4 ns, output hold/high-impedance transition >=2.7 ns, input setup 1.5 ns
and hold 0.8 ns. The pin constraints include additional board allowances.
The 2.5 ns earliest-return contract allows 0.2 ns skew against that hold bound.
Source: https://www.issi.com/WW/pdf/42S16320B-86400B.pdf
