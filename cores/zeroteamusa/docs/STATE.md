# Active state inventory

Updated 2026-10-05. The live Verilator board runs real V30/COP/CRTC/DMA/video
and target sound from reset. Early boot buffers and the SEIBU PRESENTS scene
match MAME. The observed US distance trigger passes 78 component replay cases;
the corrected sprite origin now produces a pixel-exact live title frame.
Later protection/sorting, integrated gameplay/audio, four-player operation,
progression and final platform/MRA integration remain pending. Finished user
savestates are not in the current scope.

| State | Active owner | Access / current status |
| --- | --- | --- |
| V30 registers, prefetch, BIU/EU microcode state | `rtl/ucore/` | Native donor ss register file retained; simulation debug register view enabled without injecting state |
| Microcode tables | `rtl/ucore/ucrom.hex`, `ucdecode.hex` | Immutable build-time source assets; load failure is fatal in simulation |
| Main work RAM | Main-wrapper RTL BRAM | Real target RAM and byte enables used by CPU and COP; read-only snapshots saved locally |
| Program ROM | `roms/regions/maincpu.bin` | US image, 1 MiB; target-only hash recorded in evidence |
| COP uploads/registers/DMA tables | `Raiden2_cop3.sv` | Connected to target CPU and real DMA ports; later commands/sorting still require validation |
| Private tile/palette/sprite RAM | Main/video RTL | Six live early-boot buffer ranges match MAME exactly; shared renderer uses BG=0, FG=2, MID=1 |
| Sprite cipher | `zeroteam_sprite_decrypt.sv` | Real video fetch transform; all 2,097,152 region words match original MAME decryption/passthrough |
| Z80/YM3812/OKI state | `ZeroTeam_audio.sv`, TV80/JTOPL2/JT6295 | Real sound RTL integrated; corrected active-low-input 1-second cold boot: 400,923 fetches, 179 FM IRQs, 180 coin reads, 49,715 samples; integrated music/sample validation pending |
| Input/IRQ/raster latches | Live board/video seam | 60 real IRQ acknowledgements; native /12 pixels, 512×282 total, 320×256 visible; sound coins/four-player routing pending |

The isolated actual-RTL-buffer logo is pixel-exact. The historical live logo
frame differs in 162 blue pixels on two rows; see `docs/evidence/live-logo.json`.
A later complete SEIBU PRESENTS raster matches MAME exactly. The title's
historical one-pixel displacement is documented separately in
`docs/evidence/title-origin-diagnosis.json`. The corrected live title at
240 IRQs matches MAME with zero differing pixels; see
`docs/evidence/live-title-origin-fixed.json`. Each run's frozen inventory
records its tested sources. Rich attract and gameplay remain separate gates.
The platform wrapper now selects the tested target audio source closure and
four-pad/keyboard frontend. Its loader/video path remains donor-derived and
requires final adaptation/acceptance. No Zero Team RBF
has been built; the final simulation gate and explicit RBF build rule apply.

The live model now uses native Verilator serialization for all real CPU,
COP, video/cipher and sound registers/memories, plus a separate complete
host ROM-bridge/capture-state stream. A short uninterrupted/resumed run has
exactly equal device counters, seven memory ranges and the final image.
Version, model settings, RTL and ROM hashes gate restoration. Streams stay
ignored/local; this is a diagnostic checkpoint, not a MiSTer user savestate.
Post-attract continuation still needs exercising with the ongoing full run.
