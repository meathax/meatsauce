# MAME reference oracle

The isolated official MAME 0.289 executable contains all three target machines.
`research/oracle_identity.json` pins its executable, release asset and driver source.
Its XML ROM names/CRC/SHA1 agree with the staged source audit. Kyros MCU redump
warnings remain genuine source limitations; the audit does not repair them.

Run `python -X utf8 scripts/capture_oracle.py` from this checkout. Each target gets
1800-frame attract and gameplay recordings under ignored `sim/captures/<set>/<mode>`.
Matching completed recordings are reused only after checking all artifact hashes.
The recorder observes real MAME CPUs and injects digital controls; it never changes
game RAM. Coin is pressed at frame 120, start at 160 and actions begin at 200.
The frame-complete notifier samples state before applying controls for the next
frame. Both the relative frame and MAME screen frame are retained.

Each recording contains native 256x224 RGB8 images, MAME PNGs, strip/work RAM,
257 palette entries, per-frame PCs/SR/controls/background, finite write events,
scanline histograms and 48 kHz mono PCM. The original unrotated RGB stream is the
comparison format; PNGs follow MAME's presentation rotation. `screen_device::pixels`
in the pinned `src/emu/screen.cpp` converts indexed pixels to adjusted RGB colors.
The Lua documentation's palette-index wording does not describe this implementation.

MAME 0.289 provides `screen:frame_number()` and `screen:time_until_pos`, but no Lua
`screen.vpos`. Beam bins derive from the time remaining to (0,0), frame/pixel periods
and screen.cpp's half-pixel rounding, modulo the 384x264 raster. Visible scanlines
are 16..239. Vector-read taps record serviced 68000 vector accesses; they do not
measure physical IRQ pin edges. CPU taps do not see direct C++/MCU shared-RAM writes,
so the frame RAM snapshots remain necessary for those changes.

`research/reference_capture_manifest.json` is the compact checked evidence. Final
frame PNGs show gameplay in Kyros, Kyros Japan and Super Stingray; the image evidence
supports the coin/start transition alongside changing RAM, PCs and pixel hashes.
These are reference runs, not RTL simulation passes. Input injection by itself is
not treated as proof of gameplay.

The gameplay sweeps show visible writes to all three tile groups in all targets.
Kyros/Japan position writes are mostly in blanking, with 1891 visible writes versus
311419 blanking writes; Stingray has 77299 visible versus 77837 blanking position
writes in the captured post-start interval. Start with live per-line RAM fetches.
A whole-frame latch would require additional PCB evidence. MAME's frame renderer
does not alone prove physical pixel timing, and no raster-fidelity claim is made.

Recorder failures are preserved under `*_failed_*`; early completed captures lacking
scanline data are `*_v1_no_scanline`. Neither supplies the current timing evidence.
Late-stage/ending and non-default DIP/cocktail fixtures remain pending before their
corresponding acceptance gates. B09/B10/B12/B13/B14/B15 physical limits remain open.

# Loader contract

`rom_layout.json` and `scripts/make_rom_layout.py` define the shared download image.
It has a 256-byte header (A68N, version, profile) and stable byte-addressed slots.
68000 even bytes feed D15:8; 16-bit transport words carry their first stream byte
on D7:0. Graphics go to SDRAM, while program/audio/PROM images use inferred RAM.
The Kyros firmware slot uses the separately audited full raw bootleg dump, never
MAME's overlapping original/bootleg region. It remains an optional firmware candidate.
Both Kyros MCU source limitations are retained in `research/rom_manifest.json`.

## 2026-10-09 — canonical displayed-frame RGB correction

The original `frame_*.rgb` and `.pix32` artifacts come from Lua
`screen:pixels()`. In MAME 0.289, `screen_device::pixels` reads
`m_bitmap[m_curbitmap]` (screen.cpp:1495). `update_quads` sets the completed
texture and then flips `m_curbitmap` (screen.cpp:1794–1795), before the machine
frame notifier. Those diagnostic pixels can consequently be an older drawing
buffer. They must not be used as current displayed-frame acceptance references.

The saved native screen PNG uses the displayed texture. All three pinned GAME
declarations are ROT90, so its 224x256 pixels are losslessly converted back to
256x224 with inverse ROT90. Canonical current references are now
`frame_*.display.rgb`, produced by `scripts/normalize_oracle_display.py`.
`research/oracle_display_manifest.json` binds all 66 original PNGs, normalized
RGB hashes, source conversion and original capture manifest. 28 captures differ
from the original drawing-buffer pixels; originals and their manifests remain
intact. New captures normalize after emulator completion; reuse also restores
the displayed-frame sidecars without rewriting original capture receipts.

Decisive case: Stingray gameplay frame 1200 had 746 differing pixels against
the drawing buffer. The same captured RAM rendered by the actual native
strip/palette/SDRAM RTL matches the inverse-ROT90 displayed PNG exactly. Changing
flip instead produced 46424 differences. No renderer change was needed. Details:
`research/renderer_sting_snapshot_diagnosis.json`; original rejected fixture
`research/renderer_fixtures.failed_backbuffer.json`. This corrects oracle
observation; it does not prove full live CPU gameplay or close late-scene gates.
