# Kyros warm reset: retained background RAM
MAME 0.289 alpha68k_n.cpp:381,392 maps 0x060000 as RAM shared with m_videoram (MSB watchdog, LSB background colour). The actual soft-reset reference retains background value38 at fields300,301,330; later gameplay uses64. RTL incorrectly cleared this word on every held reset.
The board now initializes it at power-up and clears it during a ROM download, preserving it during cabinet reset. CPU, flip and DAC reset behavior is retained. PCB retention is not independently measured.
The old actual CPU run has390 differing pixels at330, native black versus reference green. Background38 is a raw lookup index, not foreground palette pen38. Actual retained sprite/work RAM comparison: research/kyros_background_reset_phase.json. Field360 has broader unresolved graphics differences.
The corrected full-system simulator built exit0, ELF SHA256 46a65f217f6c24f1ba5b5bc6902413bc976ec40b167541ecbe3fb2872813cb2e, and is replaying421 fields with reset after300. No corrected graphics pass yet.
The C++ harness exports actual internal RAM/background at existing saved-field boundaries and accepted sprite writes330..420. Reads do not inject CPU/RAM/game behavior.

## Corrected actual CPU evidence — 2026-10-10
Field330 now has zero differing pixels, zero differing sprite/work RAM bytes
and retained background38. This replaces the old390-pixel field330 failure.
A broader comparison exposed20835 differing pixels at cold-boot field60 despite
identical final sprite/work RAM. Field360 still has2104 differing pixels with
identical final sprite RAM and one differing work-RAM byte. These failures remain
open; final RAM agreement alone is not a raster-time proof. Record accepted
CPU writes and establish scanline-aware reference images before classifying
them under B16 or changing logic. Do not mask differences or shift frames.
