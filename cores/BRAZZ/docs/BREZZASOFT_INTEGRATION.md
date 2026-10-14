# Integration of BrezzaSoft_Crystal_System_MiSTer (kyledlester) into Arcade-CrystalSystem

Source staged locally (kept, Git-ignored like the other donors): `donors/brezzasoft_crystal`, upstream
`https://github.com/kyledlester/BrezzaSoft_Crystal_System_MiSTer` commit `50d1d6d` (2026-10-07), GPL-3.0-or-later
(compatible with this core). Reference oracle stays MAME 0.289; where the two cores differ, this core keeps its
own PCB/MAME-verified behaviour unless the reference is demonstrably better.

## Brought in

| Area | Change | Origin | Verification |
| --- | --- | --- | --- |
| Games | Evolution Soccer, Top Blade V, Office Yeoin Cheonha, plus Urachacha Mudaeri (MAME 0.289 "working", not in the reference) | reference game list; MAME 0.289 ROM sets, patches and inputs | MRAs assembled from the MAME zips (`scripts/build_mra.py --check`); full-board boot in Verilator against the MAME CPU oracle |
| Board record | MRA index 1, 16 bytes `"CRYS", ver, game id, flash banks` (same format) | reference | `cs_board_config.sv`; MRA check |
| Cartridge banks | 1..7 populated 16 MiB banks; BIOS follows the cartridge in DDR3; unpopulated banks read 0xFF and the flash ID reads 0xFFFFFFFF (MAME dummy region) | MAME 0.289 / reference | board sim with 1-, 2-, 3- and 4-bank games |
| Protection | MAME 0.289 `init_evosocc/topbladv/officeye` word patches in the MRA download stream (as crysking) | MAME 0.289 | MRA check verifies every patched halfword |
| Inputs | per-game MAME port layouts: button 4; Top Blade V (2 buttons, PORT_IMPULSE coins, test/service bits swapped); Office Yeoin Cheonha / Urachacha (3 players, P2/P3 starts on P1_P2, coin 2 shared) | MAME 0.289 / reference MRA buttons | `mister_controls` bench (362 checks) |
| UART | VRender0 UART0/1 (`vr0_uart.sv`, MAME vr0uart): Urachacha uses UART0 | MAME 0.289 | `control` bench (TX timing + IRQ 15) |
| CP0 | MVTC write-back request (CR3 bit 6) and unspecified coprocessor registers are no-ops (MAME); Top Blade V / Office Yeoin Cheonha issue them | MAME 0.289 | `cp0`, `cp0_board`, `cpu_board` benches |
| Flip rule | Frames without sync-flip packets flip at vblank once the renderer drained the queue (reference `caught_up`); crysking keeps the wait-for-sync rule (sticky per boot) | reference | `gpu` bench (640 MAME frames + both flip modes) |
| CRT Adjust | rmonic79 MiSTer-CRT-Adjust (unmodified `rtl/vendor/crt_adjust.sv`) via the reference glue, adapted: geometry measured each frame (this core's CRTC places HSync at 344, the reference at 361), sync lag derived from it; replaces this core's sync-shift CRT position | reference | `mister_sys_video` raw sys chain bench (native/scandoubled/HQ2x/CRT modes; H-Size/H-Position/V-Shift) |
| Orientation | Native 180-degree flip (all outputs incl. analog/Direct Video); Rotate CW/CCW stay HDMI-only | reference | `scanout` bench: flipped output equals the rotated MAME screen |
| Test switch | OSD Test switch (SW3) | reference | `mister_controls` bench |
| RTC | DS1302 seeded from MiSTer's RTC on first update and after each reset (MAME uses host time) | reference | wiring (no bench: hps_io RTC) |
| 360-pixel mode | `arcade_video` sized for Top Blade V's 360-pixel picture; DDR rotation limited to 320-pixel games | reference doc | fit |
| Ordered texture-write queue | own reimplementation `rtl/memory/cs_texq.sv` of the reference crystal_texq idea, with arbiter preemption so sound never underruns | reference | `texq` bench (34 checks), `arbiter_preempt`, 1.5 G-clock sound runs |

## Evaluated and not taken

| Item | Reason |
| --- | --- |
| PIC16 protection core (Top Blade V / Office Yeoin Cheonha firmware) | MAME 0.289 (this core's oracle) runs both games with word patches; patches applied |
| Top Blade V VRender0 at 80 MHz | MAME master only; MAME 0.289 runs it at the standard clock |
| Fixed 14.3 MIPS CPU (MAME master: 3 cycles per instruction) | game-speed work was paused by request; this core keeps MAME 0.289 nominal pacing |
| HSync at 361 (reference CRTC) | this core's CRTC placement kept; CRT Adjust made geometry-independent instead |
| 4-bank open-row SDRAM scheduler | larger redesign; candidate for later |

## Results

Timing: fit16 (RTL before the texq registered push) failed setup at -0.451 ns on both slow corners (CPU request ->
arbiter -> cs_texq RAM write-enable). With the registered push (texq writes the RAM one clock after the push, reads held
for that clock, settle 3), the production check fit21 closed all four corners (setup +0.072/+0.039/+0.588/+0.570 ns,
hold +0.242/+0.102/+0.104/+0.075 ns). Release compile through the shared Quartus queue, 2026-10-09: TIMING MET, worst
setup +0.072 ns, 0 failing clocks; ALM 65%, LABs 91% (3,825/4,191), peak/average interconnect 50.7%/32.3%, RAM blocks 47%,
memory bits 28%, DSP 70%. `releases/Arcade-CrystalSystem_20261009.rbf`, 3,687,416 bytes, sha256
`d64481f799a70d9e45214f6c307777ec4749a650f2703b5f0c36532a43f56131`; all six MRAs pass `scripts/build_mra.py --check`.

Not yet done: the five-game 3 G-clock regression on the final RTL (earlier runs on the preemption build: officeye,
topbladv and evosocc 1.5 G clocks without audio underrun) and any MiSTer hardware test.
