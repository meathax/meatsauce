# Zero Team USA MiSTer platform options

Only MAME 0.289 `zeroteam` (US) is supported. No clone support is claimed.
The target wrapper now instantiates the same board, video/cipher and sound
modules as the audiovisual simulation. `sys/` remains unchanged.

| Requested feature | Implementation |
| --- | --- |
| Functional control names | Attack, Jump, Start, Coin, Pause, Service Credit, Service Menu; four pads and keyboard |
| Service menu | Remappable cabinet test switch and SW3:4 DIP drive active-low SYSTEM bit 11; F3 holds it active. F2 supplies a service credit. |
| DIP switches | Native `DIP;` OSD submenu, labelled DIP switches by MiSTer. MRA contains all SW1/SW2/SW3 switches, including explicitly unused positions. |
| Scaling | Normal, V-Integer, HV-Integer, Narrower HV-Integer |
| Rotation | HDMI framebuffer: clockwise/counter-clockwise 90 degrees. Rotate 180 changes the game renderer for analog and HDMI, combined with game-controlled flip. |
| Direct video | Fixed 12-cycle pixel enable; native raster. HDMI rotation/scaling and CRT retiming are hidden/bypassed. |
| Analog / CRT | Native RGB/sync, standard forced scandoubler, CRT Adjust (H-Size -16..+15, H-Position -48..+48, V-Position -2..+19 lines). 15.625 kHz / 55.41 Hz, 282 lines, 512-pixel line, constant 12-clock pixels. |
| Y/C | Existing enabled MiSTer `sys/yc_out.sv` path, configured through MiSTer video settings. No disable-YC macro is enabled. |
| Native refresh | 96 MHz / 12 / 512 / 282 = 55.4078014184 Hz; 15.625 kHz lines; 320 × 256 active. No game-speed-changing 60 Hz option. |
| High scores | MAME table `9212`–`925c`, 75 bytes. Standard index-3 config and index-4 NVRAM. Opening OSD captures changed scores and requests upload automatically. |

SW1/SW2 use DSW bits 0–15. SW3 uses SYSTEM bits 8–15, loaded as MRA
bits 24–31; its unused bits are passed through rather than forced high.
Names, settings, polarity and defaults follow the pinned MAME driver
`reference/mame/raiden2.cpp:857`. Cabinet and startup settings may require
Reset after changing them, as on the original game. Unknown switches marked
unused by MAME are labelled `Unused SWx:y`; no invented game function is assigned.

Attack/Jump and their combined special move follow the
[Zero Team controls reference](https://gamefaqs.gamespot.com/arcade/569234-zero-team/faqs/74649).
MAME exposes an extra raw player switch, but the cabinet has two buttons, so
the core leaves it high and offers no separate Special button; press Attack and
Jump together.

## CRT / Direct Video verification (2026-10-08)

`sim/run_crt_bench.sh` drives the real Raiden2 raster, the platform pixel stage, sys
`arcade_video` (native and forced scandoubler) and `crt_adjust` with the platform's read-clock
generator, and asserts per configuration: 320 visible pixels on every line, 256 visible lines,
constant line (6144 clocks) and frame (1,732,608 clocks) length, constant HSync (456 clocks) and
VSync width, constant pixel width, picture window clear of the HSync pulse and of the next line,
and picture/VSync separation. Raster: 8 MHz dot clock, 512 x 282, 15.625 kHz, 55.4078 Hz (MAME
`set_raw`, not a `set_size` bitmap); native pixel 12 clocks (even, integer); forced scandoubler
6 clocks / 512 lines. Defects found and fixed: negative H-Position blanked the picture (sign
extension in `crt_adjust`), H-Size above +8 and H-Position above about +40 clipped the right edge,
the CRT-adjust path lost the top and bottom picture line, and the non-CRT HDMI/Direct Video path
presented DE two pixels ahead of RGB. CRT Adjust is unavailable under Direct Video by design.
CRT and Direct Video hardware are not yet checked; V-Position direction (positive delays VSync,
moving the picture up on a CRT) needs a monitor check.

## Boot and video protections

The MRA reproduces the pinned MAME regions byte for byte, including ROM gaps
and encrypted sprite padding. Program, characters, tiles and OKI occupy
SDRAM bank 0; the full encrypted sprite region occupies bank 1. The existing
controller addresses 8 MiB per bank, so ordinary 32 MiB SDRAM suffices. Sound
program words download into target BRAM at byte `560000`. DDR3 is used only
for HDMI rotation. The donor sprite cipher, palette composition and 240-line
wrapper have been replaced with the target modules already used in simulation.

Reset stays asserted across PLL/SDRAM initialization, ROM/high-score downloads,
the final outstanding SDRAM write and a registered 22-bit settle interval.
Graphics reads do not reassert reset.
V30 ROM requests and acknowledgements retain their toggle phases; COP and
graphics use their separate level/pulse protocol. Treating the V30 request
as a level would drop every second fetch and can stall boot.
Native video timing continues through
game reset so CRT sync remains present. Both sync pulses are inside blanking;
pixel RGB, DE and sync move together on complete pixel boundaries. CRT vertical
retiming has been removed because it would change the requested native refresh.

High-score accesses borrow the existing work-RAM port only after the V30 reaches
its instruction boundary and COP work completes. The high-score controller
waits for that acknowledgement; a fixed short padding timer alone is insufficient.
Even bytes use the low lane. Signature checks qualify initial restore and do
not incorrectly reject a saved score table after its contents have changed.
Video timing continues while the OSD pauses the CPUs. Audio also pauses.

Rotation writes queue across DDR backpressure, preserving address/data/byte
enables. Ninety-degree rotation is an HDMI feature; native analog/direct video
retains the unrotated raster, suitable for physically rotated CRTs. Rotate 180
is a game-renderer operation and therefore applies to both output paths.

## Verification and remaining gates

`sim/run_platform_checks.sh` runs actual RTL for uniform pixel cadence and
whole-frame timing, sync blanking, byte-mode downloads with variable SDRAM
latency, independent graphics/program/COP/OKI addressing, real board work-RAM
lanes, all 75 saved/restored/uploaded score bytes, OSD-triggered upload, unchanged
score suppression, delayed pause acknowledgement and DDR stalls.
`sim/run_platform_boot.sh` runs the real US V30/COP with the production ROM
bridge and 16-cycle memory responses for 60 native frames. It verifies millions
of program reads, game RAM writes, continuing interrupts and populated text/
palette memory; it does not run the full audiovisual MiSTer wrapper on hardware.
The Rotate 180 boot-logo fixture is checked pixel for pixel against the native
image reversed on both axes, separately from the native/MAME comparison.
`sim/run_inputs.sh` checks 30 vectors including every cabinet and service/unused
SYSTEM switch. `scripts/verify_platform.py` independently assembles the MRA with
the established MiSTer byte-map decoder and compares each region to the pinned
MAME images. Production emu lint includes real framework modules; Intel hardware
primitives are black boxes. Evidence: `docs/evidence/platform-options.json`.

Lint uses compatibility exceptions for the unchanged framework's procedural
net outputs and mixed assignment styles (`PROCASSWIRE`, `BLKANDNBLK`). It is
source/port validation, rather than a timing-closure or resource-fit report.

No RBF was built, and no MiSTer hardware test was performed. Placement, timing
closure, actual SDRAM bandwidth in busy scenes, analog/direct-video/Y-C display
measurements, persistent files on HPS and complete gameplay remain release
gates. Source checks and simulation cannot guarantee every hardware build will
boot or eliminate every scene-specific corruption. Existing MAME COP/sprite
ordering limitations and incomplete gameplay acceptance remain in `plan.md`.
