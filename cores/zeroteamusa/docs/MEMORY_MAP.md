# Memory integration status

The authoritative target map and ROM lane geometry are in
`docs/HARDWARE_NOTES.md` and `reference/rom_layout.json`.

The initial CPU seam implements target reset/program fetches and writable
work RAM below 0x20000, treating 0x400–0x7ff devices as recorded open bus.
Its memory waits are explicit. It does not model the target COP, CRTC,
sound/input registers or private DMA buffers and is not the complete board.

The imported `rtl/Raiden2/Raiden2_main_top.sv` and
`raiden2_addr_main.sv` still contain Raiden II layer/sprite/palette ranges.
Before using them for target acceptance, move source-RAM regions to the
Zero Team addresses, preserve private video DMA ownership, wire P3/P4 and
replace target bank controls. The external main-ROM bridge uses a toggle
request/acknowledge protocol; the harness must return stable data before
acknowledging, rather than treating `ready` as a generic constant.

Default storage remains donor SDRAM CPU/tile clients and DDR3
sprite/sample clients. Model their latencies and contention during the
integrated release check; the current CPU seam is not a DDR/SDRAM electrical
or full arbitration test.
