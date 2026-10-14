# Alpha68k N requested MiSTer features

This is a development core. `progress.md` and the hashed feature evidence are
qualification records; available OSD controls do not imply all-game readiness.

- Kyros/Kyros Japan: Punch, Jump, Start, Coin and Pause. HPS bit8 toggles Pause;
  opening the OSD also pauses the main/sound CPUs and RAM/MCU-facing bus writers.
  The raster, renderer and SDRAM continue. CPU phase and sound timer phase freeze.
- MAME 0.289 lists **no cabinet Service/Test input** for any of these three sets.
  No fictitious service line is added. All eight physical DIP positions appear
  in the firmware's standard **DIP Switches** submenu, with original names and
  per-game values/defaults. Stingray SW1:7 remains correctly named Unused.
- Scale: Normal, V-Integer, HV-Integer-, HV-Integer+, HV-Integer. `video_freak`
  and its integer-scaling arithmetic are the pinned framework implementation.
  HDMI dimensions are exchanged for quarter-turns, then aspect outputs swapped.
- Orientation defaults to the MAME clockwise 90-degree presentation. Rotate 90
  selects Clockwise or Counter-clockwise; Rotate 180 applies in the native
  renderer and therefore affects analog/direct video as well as HDMI. Quarter
  turns use the framework DDR framebuffer and are hidden/bypassed in direct video.
- CRT Adjust: H-Size, H-Position, V-Position and V-Size. Pinned rmonic79 donors
  run at the core video boundary without framework modifications. H-Size uses
  whole 48 MHz clock periods (6..10 clocks/pixel) and resets on the donor's own
  HSync reference. Enlarged content is blanked at sync, including the donor
  pipeline tail at line reset. It does not use a free-running fractional pixel accumulator.
  CRT is bypassed for scandoubled/HQ2x video. V-Size retimes up to three lines
  through a 12-line buffer and is disabled in direct video to retain fixed HSync
  cadence. V-Size changes HSync frequency; chassis compatibility and resource
  use remain physical/fitted qualification gates. Adjustments reach HDMI too.
- High scores: pinned `Hiscores_MiSTer` v14, configured from MAME 0.289's table,
  indices3 (config) and4 (NVRAM). Autosave defaults **On**; opening the OSD extracts
  RAM and requests a save only when the contents change. The RAM borrower checks
  the 0x020000..0x020fff range, requires current pause plus registered acknowledgement, and
  uses 68000 big-endian byte lanes. Initial signatures gate restore, not later
  payload validity. Main stores each MRA's `.nvm` in `config/nvram`.
- Standard byte HPS transport serves DIPs and hiscores. The wrapper pairs ROM
  bytes into the established 16-bit board loader. MRA generators independently
  expand every audited ZIP/continuation/interleave into the exact packed image.
- Native raster: 6,000,000 pixels/s, 384 pixels/line, 264 lines/frame,
  **6,000,000/(384*264) = 59.1856060606... Hz**, horizontal15,625 Hz.
  Blank x256..383, y0..15/y240..263; HSync x272..303, VSync y248..251.
  MAME supplies totals/crop; pulse positions are the existing RTL choices and
  still need original-PCB sync measurement. Nominal PLL frequency is not a
  crystal-tolerance measurement. Startup's first framework field remains limited.
- Direct video/RGB analog/Y-C use the pinned Template framework's standard
  video_mixer/vga_out/yc_out paths, as in the staged SNK TripleZ80 core. Y-C is
  enabled in QSF (MISTER_DISABLE_YC remains unset); framebuffer support is enabled.
  No physical no-wobble, encoder color/subcarrier, DAC or CRT lock pass is claimed.

Stingray's generated MRA is under `development/`. Real 8748 firmware execution,
its distinct bus/sound maps and coin-DIP behavior are still P6 work; the wrapper
continues rejecting that profile rather than running it through Kyros's MCU HLE.
Its Fire/Special weapon labels are provisional because the original instruction
panel was not located. Kyros Japan full gameplay and all-games non-default DIP,
cocktail and earned-score save/reload qualification also remain pending.

Kyros's legal two-player cocktail/non-default coinage oracle is now qualified:
IN1=0x46, one A coin buys two credits, Start2 and natural Player1 death produce
the actual cocktail flip at1132. The source-pinned combined RTL1801 replay
is running; its terminal/feature acceptance remains pending. See
`docs/COCKTAIL_ACCEPTANCE.md` for exact sources, failed-observer recovery,
native process handles and the final verifier command.

Sources: pinned `donors.lock.json` and `rtl/vendor/mister_features/PROVENANCE.md`;
MAME source/profile/ROM manifests; `research/feature_hiscore_source.json`;
`research/feature_mra_validation.json`; original Kyros manual/pinout linked in
`research/feature_sources.json`. No Quartus command, RBF assembly or deployment
is authorized by this feature implementation request.

On this Windows host, set `ALPHA68KN_BUILD_ROOT=/mnt/d/vibes/fpga/temp`
when building the Verilator wrapper: GNU Make cannot use paths containing
spaces, and WSL /tmp can run out of space. The snapshot handle and input hashes
are saved under sim/build. This is a simulation build, not an RBF build.

`research/feature_qualification.json` binds the final executable and both source
manifests to the decisive checks. The feature fixture checks all 256 DIP bytes,
178 score bytes through real HPS restore/upload, pause ownership, changed/unchanged
OSD save edges, four integer scale modes, five native/CRT/direct-video modes and
pixel-exact 90/180-degree rotations. Separate eight-field Kyros/Japan boots check
the unchanged paired ROM loader and settled native video. These short boot checks
do not establish attract-mode/gameplay qualification for every game. Production
native and framebuffer elaboration use peripheral stubs, and are not fitted
resource or timing proofs. Run `python scripts/record_feature_qualification.py`
after the documented final runs to verify source hashes and renew this record.
