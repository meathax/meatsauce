# Loader and clock integration — development baseline

The active `Alpha68k_N.sv` now instantiates the real 68000/Z80 board and the
pinned JTFRAME SDRAM controller rather than the Template demonstration core.
This is an incomplete core: it displays the palette background only and exposes
the software DAC only. The renderer, YM/AY chips, Stingray firmware, full MiSTer
features and final timing/resource qualification remain in the plan.

## Clocks and reset

`rtl/alpha68kn_pll.sv` produces one 48 MHz master for game logic, CPUs, HPS I/O
and the SDRAM controller. Its second 48 MHz output, shifted 10416 ps, forwards
the SDRAM device clock only. The controller also uses the opposite edge of the
same master internally; this is an interface timing path that STA must review.
The standard framework's clocks are retained without changing `sys/`.

PLL lock and external reset each enter a three-register synchronizer.
A 10000-cycle power-up delay precedes the controller's own 5000-cycle
initialization delay. Cold reset initializes SDRAM; game/user reset does not.
A free-running 3072-cycle counter triggers distributed refresh during download,
CPU reset and gameplay. The phase choice and external device setup/hold are
development settings, **not yet an electrically qualified SDRAM interface**.

## Download and byte order

`rom_layout.json` remains the logical contract. The header is `A68N`, version
1. The wrapper checks those words, the Kyros/Japan profile and the final logical
address before releasing CPU reset, and waits for the graphics FIFO to drain.
Stingray is deliberately held unsupported until P6.

The on-chip slots retain every byte of the program, sound, RGB PROM, CLUT,
color PROM and raw MCU images. The main CPU sees big-endian words; the download
transport carries its first byte in D7:0. MCU storage is preservation evidence,
not execution of the Kyros partial/bootleg MCU; the board still uses the named
MAME-compatible HLE.

Graphics use the unchanged logical raw ROM bytes. For physical SDRAM only,
swap byte-address bits 0 and 3. This reversible mapping places raw bytes
`row` and `row+8` into one 16-bit word, reducing tile-row read traffic.
All tile-row request addresses must have bit 3 clear; low/high output bytes
then correspond to the first/second half of that plane row. Each input word
becomes two masked byte writes. A 16-word FIFO and two beats of backpressure
headroom cover the registered board forwarding pulse.

## Decisive checks

- `research/onchip_loader.json`: 105088 canonical words checked through real
  board diagnostic ports; corrected CPU shell then executed 10 frames with
  zero unmapped accesses.
- `research/gfxmem_loader.json`: actual FIFO and pinned SDRAM controller,
  all 393216 bytes checked at the SDRAM command/data pins; 196608 input words,
  393216 physical writes and 24576 read pairs, exactly once; CL2/burst1 mode and
  refresh commands exercised. Maximum sampled row-read latency: 10 cycles.
  Download/controller drain alone: 2793464 cycles (58.20 ms at 48 MHz).
  HPS transport time is additional and has not been measured.
- `sim/gfxmem_main.cpp` models the external SDR SDRAM device only. It checks
  command order, mode, byte masks and read data. It does not prove electrical
  setup/hold, data retention, every SDRAM speed grade or complete video deadlines.
- `research/cpu_boot_300.json`: earlier source `01a1aa1`, 300 real CPU frames,
  88229 strip writes, IRQ acknowledgements 245/248, zero unmapped accesses.
  Coin/start inputs were applied; visible gameplay and acceptance of those
  inputs remain unqualified until the renderer/state comparisons are available.

## Quartus execution and recovery

The initial attempts below are historical diagnostics, not current execution
instructions. Quartus is resumed. Prefer the absolute QuartusFast frontend
documented in plan.md. Development map/fit/STA checks run unqueued and occupy
no production lane. No preassembly recipe registration or lease approval is
required. Only gated full compiles/assembly/conversion use the shared FIFO and
its permanent two-job ceiling. Queue admission never authorizes assembly.
Preserve every strict ceiling in resource_limits.json and all final gates.

The old scripts/quartus_develop.py and scripts/quartus_preassembly.ps1 lease/raw
shell entrypoints are retired and refuse execution with the current frontend
instructions. Use a reviewed immutable check project, then a visible absolute
QuartusFast build command without --allow-rbf. Preserve the Template timestamp
header and fx68k readmemh prerequisites; do not silently discard preprocessing.
The exact timestamp-only-hook review, assignment equivalence and input pins are
retained in research/quartus_check_merged_preprocessed_admission.json,
research/quartus_check_merged_fast_launch.json and the complete private overlay
receipt research/sound_write_width/complete_overlay_launch.json (original
recovery checkout until imported). These are preparation evidence, not a fitted
resource/timing pass. No hardware input was changed by this rule correction.

The first analysis failed because direct `quartus_map` does not execute the
Template flow's build-date generation hook. Failed evidence is retained at
`artifacts/quartus/20261009_115845/`. The restarted owned job is described by
`sim/build/quartus_initial2_job.json`; its evidence directory is
`artifacts/quartus/20261009_120221/`. Do not restart it while its PID is alive.
Any successful baseline fit still excludes planned renderer/audio/MCU features
and the unresolved external timing constraints; it cannot authorize assembly.

The second map reached hard-block generation but failed because this project's
new PLL used an unsupported `pll_type="auto"`. The actual Quartus 17 library
and the pinned generated reference require `"General"`; it is corrected in
the own PLL module. See `research/pll_type_diagnosis.json`. The new owned job
uses `sim/build/quartus_initial3_job.json`; the previous job ended and must not
be resumed. This is a corrected synthesis finding with fresh results pending.
