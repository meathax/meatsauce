# VRender0 control and DMA status

The implementation follows pinned MAME 0.289 `machine/vrender0.cpp` for the
architectural register contract. It uses actual RTL counters and stalled bus
transactions; MAME's instantaneous DMA is only an independent unit oracle.

## Control and interrupt controller

`rtl/soc/vr0_control.sv` provides SYSID `0x00000a00`, CFGR `0x00000041`,
INTVEC `0x0c04`, INTEN `0x0c08` and INTST `0x0c0c` (SoC byte offsets).
Only enabled event sources latch status. Vector selection uses the lowest pending
source, prefixed by the three-bit vector group. Writing INTVEC's low byte clears
one source; its next byte selects the vector group. Disabling a source clears its
pending status. INTST writes have no effect in the reference and RTL. A new event
survives a simultaneous acknowledge; this explicit hardware ordering avoids lost
interrupts and is not an assertion about MAME's sequential callback scheduling.

Four timer control/reload pairs start at `0x1400`, stride eight bytes. Period in
system clocks is `2 * (prescaler + 1) * (reload + 1)`, matching the reference's
SoC-clock calculation. Enable transitions start/stop the timer; changing a running
reload/prescaler affects the next periodic reload. One-shot completion clears
enable. Sources are 0, 1, 9 and 10. The readable reload remains the programmed
value, as in MAME; it is not a free-running count readback. Timer count accesses
use the low halfword; the unmapped upper half reads zero.

Observed PLL, system/local-memory and peripheral-select configuration writes are
retained for diagnostics. FPGA clocks and memory wiring come from the fixed board
contract. MAME leaves these addresses unmapped; reads return zero (probed on the pinned
executable with `scripts/mame/control_probe.lua`, as are the timer-count upper half and
watchdog/PLL readback). This policy
is explicit and does not establish the undocumented physical PLL/controller
semantics. Watchdog noprw addresses follow the reference; a functional watchdog
is not claimed. GPIO, RTC, UARTs, CRTC and unrecognized active devices remain
separate pending work and return visible errors in this probe.

## DMA

`rtl/soc/vr0_dma.sv` has two four-register descriptors at `0x800` and `0x810`:
control/source/destination/count. A rising control bit 10 starts a descriptor.
Width 00 is byte, 01 halfword, and 1x word. Source hold/direction use bits 5/4;
destination hold/direction use bits 3/2. Internal addresses advance while the
programmed descriptor addresses remain readable, matching MAME's end-state.
Completion clears enable/count and pulses source 7 or 8 through the interrupt
controller. Zero-count commands complete without fabricating a memory transfer.

Read/write operations use the same aligned board bus as the CPU, including
unaligned boundary splitting. Channels queue and execute in channel priority;
CPU/DMA memory ownership is handled by the fair shared-bus arbiter. Real memory
responses and backpressure determine completion time. Bus faults stop visibly.
Repeat modes (control bits 7:6 nonzero) are unresolved in MAME and explicitly
rejected here. Re-triggering an actively executing channel is likewise rejected.
Descriptor edits during an active transfer do not change its captured parameters;
physical abort/reload behavior must be resolved if exercised by firmware.

## Evidence and limits

`docs/simulation_control.json`: 7,009 IRQ/timer/configuration checks.
`docs/simulation_dma.json`: 1,024 transfer cases against the mechanically extracted
MAME function, including all widths, holds/directions, alignments, queued channels,
byte strobes, variable latency and errors. `docs/simulation_arbiter.json`: stalled
selection and 128 contended requests with response ownership/error routing.

`docs/simulation_boot_probe.json` is a CPU bring-up diagnostic. The independent
CPU oracle reads the values observed on the actual RTL CPU bus, checks read
address/order, then compares architecture and exact CPU writes. It does not drive
the DUT, emulate its processor, make DMA instantaneous or prove chip/board timing.
The hardware CPU cold-boots with state loading disabled. Chips are checked by
their own comparisons; final full-board acceptance still needs actual frames,
sound, normal gameplay and deadlines with realistic physical memory backends.
