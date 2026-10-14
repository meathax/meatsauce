# Planned state/checkpoint inventory

Design state accessibility before wiring RAM. This inventory is a requirement, not an implemented savestate feature.

| Block | State to expose to the simulation/checkpoint port |
|---|---|
| 8080 | Registers/flags/PC/SP, instruction/bus phase, interrupt enable/pending/acknowledge, HOLD/READY state |
| Main bus/memory | Full 16 KiB RAM, loaded ROM identity, pending read/write and loader arbitration |
| Raster/color | H/V counters, pixel subphase, bitmap pipeline, color mode/data, flip and PROM identity |
| Shift/input/IRQ | Shift word/count, sampled controls/DIPs, sound command latches, IRQ vector/pending/INTE |
| MCS-48 | CPU/PSW/timer/interrupt state, 64-byte internal RAM, external ROM identity, P1/P2/T0/T1 and bus latches |
| Analog model | Monostable counters, SLF/VCO/noise/filter/envelope accumulators, DAC and PCM mixer/filter state |
| MiSTer features | Profile/reset/load state, pause ownership and hiscore RAM-borrow state |
| Later boards | HeliFire line/LFSR/color/envelope state; Othello framebuffer/HOLD/input/counter; Block Fever 8085/tile/ball/ADC/discrete state |

Version each checkpoint with source/ROM identity and frame/cycle position. Reuse a borrowable RAM port for debugging and high scores. Do not add a release savestate menu until all required state can be restored coherently.
# Implemented state inventory (2026-10-09)

`n8080_board`: 16 KiB main ROM, 16 KiB CPU/bitmap RAM, 1 KiB sound ROM (not yet connected), 1 KiB color PROM; registered memory read pipelines; raster H/V/pixel phase and output coordinates/sync/blank; shift-data/count; color-mode/data/flip; IRQ/vector; sound command latches. Its paused debug port borrows the video RAM read port. ROM data is restored by download; warm reset preserves RAM.

`n8080_cpu`: 25-master-clock T-state phase, latched 8080 status and SYNC/DBIN/WR edge history. The unchanged vm80a kernel holds architectural and internal microcycle state. No full hardware save/restore claim is made.

`n8080_mcs48` (qualified standalone; board integration pending): 1 KiB program ROM, 64-byte internal RAM, synchronous read pipelines, fractional crystal accumulator, previous sound pins, two 25-bit retriggerable monostable durations. BSD T48 retains CPU/timer/port/IRQ state. All game registers use the same master clock, including the kernel's XTAL and core clock inputs; separate enables preserve the /3 and five-state cycle division.
