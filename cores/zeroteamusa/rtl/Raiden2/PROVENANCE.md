# Source provenance

Upstream: https://github.com/rmonic79/Arcade-Raiden2_MiSTer.git

Commit: `534c84c5803959e76538b65ac71808616f1caa41`

Original path: `rtl/Raiden2/`

Imported unchanged, retaining original per-file notices. Integration changes belong in a dated change entry below. The project license is GPL-3.0-or-later; upstream file notices remain authoritative.

2026-10-04: made the two main work-RAM initialization paths explicit relative
to the project root in `Raiden2_main_top.sv`. The zero table and hardware
behavior are unchanged. This module is not yet part of the running CPU seam.

2026-10-04: `Raiden2_main_top.sv` and `raiden2_addr_main.sv` now use the
Zero Team CPU source/staging map: BG B800, FG C000, MG C800, text D000,
palette E000 and sprite F000. Renderer DMA offsets remain donor offsets;
sprite fill/command writes and COP source routing follow the new ranges.
The initial fixed bank adaptation was BG=0, MID=2, FG=1; see the correction
below. Added P3/P4 input ports.
The donor CPU/COP/CRTC engines remain intact. Target sort/protection/cipher
behavior and exact register cutouts remain under investigation.

2026-10-04: adapted `Raiden2_video_timing.sv` to the target's actual /12
pixel divider, 512×282 raster and 320×256 visible area. The donor's active
constants had been /13, 473 total pixels and 240 lines despite older comments.
Text/tile/sprite renderers now cover 256 lines; text uses the native scroll
origin. `raiden2_mixer.sv` has an explicit Zero Team priority mode
(BG,spr0,MG,spr1,FG,spr2,text,spr3), without Raiden II alpha blending,
and exports the completed-pixel strobe. The simulation-only blend asset
path is explicit. `spram_dp.sv` uses an address-register/output-register
memory model under Verilator; its synthesis primitive remains unchanged.
The isolated renderer output from actual early-boot buffers matches MAME
exactly. This does not establish later sprite cipher/protection/gameplay.

2026-10-04 correction: the target `bank_reset(0,2,1,0)` argument order is
BG, FG, MID, text. Therefore the shared video uses BG=0, FG=2, MID=1.
The early text-only checkpoint could not exercise the mistaken FG/MID
interpretation. The live video text origin is zero: MAME dispatches scroll
only to BG/MID/FG, so text must not use the donor CRTC base registers.
The shared target video now decodes sprite fetch responses through the
actual `zeroteam_sprite_decrypt` RTL, with one response pipeline stage.
The main-wrapper fixed bank output was also corrected to `16'h0210` after
the live run; that run's shared renderer used its own correct fixed banks.
Its frozen build-input hash inventory retains the actual tested source.
# Zero Team USA collision ROM adaptation

The B100/B900 hitbox reader now selects the registered RAM source or the
variable-latency program ROM port independently for its pointer and descriptor.
The main board translates the banked COP ROM window with `raiden2_addr_main`,
using the same bank registers as the V30. Direct ROM addresses retain their
existing mapping. This corrects the donor's assumption that the game always
copies its hitbox table into RAM: observed USA collision pointers and descriptors
remain in the banked ROM window.

`sim/cop_collision_main.cpp` exercises the production COP and address translator
with observed USA operands, both ROM banks, delayed replies, and independent
RAM placement. These are component checks; CPU-driven combat remains a separate
acceptance condition. Original donor authorship and licensing remain in place.

## Zero Team blank sprite ROM range

The target video instance enables `BLANK_UPPER_HALF` in the generic sprite
renderer; its default is disabled for donor boards. USA sprite ROM is 8 MiB
with only the lower 4 MiB populated/encrypted. The upper half remains 0xff,
and the target cipher explicitly passes it through. Codes 0x8000..0xffff are
therefore transparent. The USA program fills unused slots with code 0x8000
at (0,0); skipping those slots before the FIFO prevents blank work from
exhausting the top-row budget. The original 512-entry reverse scan and all
populated codes remain supported. Exact first-stage component pixels match
MAME after this change; full live gameplay gates remain separate. See
`docs/evidence/video-first-stage-hud.json` for source/ROM identities and the
before/after proof. No ROM bytes or CPU state are modified.
# 2026-10-06 timing qualification

Share the raster target's low-byte increment between flip modes and express
its ninth-bit wrap directly. Verify all 1,024 nine-bit row/flip combinations
against the original expression. No request or rendering cycle is added.

In `Raiden2_sprite_renderer.sv`, replace the cascaded tile-code additions with
carry-save reduction and pack the disjoint tile/row/word fields directly.
Preserve 16-bit tile-code wrap, every ROM address and all request cycles.
The actual RTL arithmetic passes `sim/run_sprite_address_checks.py`:
268,435,456 comparisons covering all 16-bit codes and 4-bit geometry values.

2026-10-06: Combine disjoint tile and column fields before the signed sprite
X-origin addition. Preserve the 11-bit wrap, clipping inputs and cycle count.
Verify the production expression with sim/run_sprite_position_checks.py
(1,048,576 combinations covering every signed origin and flip setting).

2026-10-06: Factor `raiden2_addr_main.sv` into parallel aligned-window
predicates, shortening the address-to-COP-trigger/stall path. Preserve every
byte mapping, open-bus hole, exclusive sprite-buffer select and banked ROM
address without adding a register or bus cycle. The actual original decoder
at repository baseline `fd97f89` is the independent RTL reference in
`sim/run_address_decode_checks.py` (all 134,217,728 input combinations).
