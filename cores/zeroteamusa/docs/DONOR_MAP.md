# Donor choice and complete component coverage

Prepared 2026-10-04. Repositories are downloaded under `donors/`, with exact
revisions in `donors/manifest.json`. Their mere presence does not establish
Zero Team compatibility. No separate, complete public Zero Team USA / SEI251
RTL was found in this search. The explicit gaps below still require work.

## Primary base decision

Use **[rmonic79/Arcade-Raiden2_MiSTer](https://github.com/rmonic79/Arcade-Raiden2_MiSTer)**
as the hardware base inside the fresh MiSTer template. It supplies the
integrated V30 `ucore`, a COP implementation, four video layers, sprite
renderer, memory clients, sound glue and MiSTer options. It is a closer
initial implementation than the 68000-based Cup Soccer board.

The requested
[spacestate1/Arcade-Raiden2_MiSTer](https://github.com/spacestate1/Arcade-Raiden2_MiSTer)
is staged as the strongest alternate source for modular COP, tile/sprite,
memory and sound-latch behavior. Its own `rtl/raiden2_main.sv` documents a
V33 `nec_core` adaptation that does not match V30 bus timing. This makes it
a useful functional donor, but the actual V30 path in rmonic79 is preferable.
Its README refers to benches/models outside the published checkout; only
the published `tools/check_files.py` is present here. Reuse available code;
do not assume unshipped simulation infrastructure exists locally.

## Selection matrix

| Board block | First source, exact local entry points | Adaptation / alternate |
| --- | --- | --- |
| NEC V30 CPU | `raiden2-rmonic/rtl/ucore/v30_core.sv`, BIU/EU includes, `ucrom.hex`, `ucdecode.hex` | Keep integrated version; `nec-test`, `irem-m72`, and `raiden` provide CPU provenance and targeted behavior references |
| V30 bus and ROM | `raiden2-rmonic/rtl/Raiden2/Raiden2_main_top.sv`, `raiden2_addr_main.sv`, `raiden2_sdram_bridge_cpu.sv` | Change the Zero Team map/reset bank; `raiden2-spacestate/rtl/raiden2_cpu_fetch.sv` is an alternate transaction pattern |
| SEI1000 COP | `raiden2-rmonic/rtl/Raiden2/Raiden2_cop3.sv` | Drive actual US uploads; compare `seibu-cup-soccer`, `gundam-sd`, `sdgundam-rainbow`, `denjin-makai`, `legionnaire`; avoid unrelated 68000 maps/byte order |
| COP DMA / math / BCD | Same COP; `raiden2-spacestate/rtl/raiden2_cop_dma.sv`, `raiden2_cop_cmd.sv`, `raiden2_cop_itoa.sv` | Port only commands / modes required by US traces; MAME `seibucop*.ipp` is staged |
| COP sorting / collision | Primary COP plus Cup Soccer and SD Gundam implementations | Highest uncertainty: MAME TODO and different command tables; identify first mismatching result rather than stub returns |
| SEI0200 tile/CRTC | `raiden2-rmonic/rtl/Raiden2/Raiden2_tile_layer.sv`, `Raiden2_text_renderer.sv`, `Raiden2_seibu_crtc.sv` | Set banks 0/2/1/0, 320×256, target ROM geometry and DMA; alternate `raiden2-spacestate/rtl/sei0200.sv`; D-Con provides simpler family examples |
| SEI251 sprites | `raiden2-rmonic/rtl/Raiden2/Raiden2_sprite_renderer.sv`, `spram_dp.sv`, sprite caches/clients | Adapt SEI252-family renderer, wrap/clip/order/key behavior; alternate `raiden2-spacestate/rtl/sei252.sv`; SeibuSPI is reference-only unless file licenses permit reuse |
| Sprite cipher / battery | `raiden2-rmonic/rtl/Raiden2/raiden2_decrypt.sv` and `crypt/` are infrastructure donors | Replace Raiden II algorithm with exact `reference/mame/r2crypt.cpp:zeroteam_decrypt_sprites`; key retention/reset is a specific implementation task |
| Discrete priority / blending | `raiden2-rmonic/rtl/Raiden2/raiden2_mixer.sv` and palette path | Replace Raiden II priority/blend data with target `init_zeroteam` / blend table; alternate `raiden2-spacestate/rtl/raiden2_sei360.sv` is behavioral, not a physical SEI360 claim |
| Z80 | Integrated donor T80 plus `t80/` upstream | VHDL must be synthesized once to Verilog by GHDL for Verilator, or use staged JTFRAME TV80 if conversion fails; never emulate sound in host C++ and claim full RTL |
| SIE150 sound interface | `raiden2-rmonic/rtl/Raiden2/Raiden2_audio_z80.sv`; `raiden/rtl/Raiden/Raiden_audio_z80.sv` | Actual body matters: Raiden's stale header says YM2151, but it instantiates JTOPL2; alternate `raiden2-spacestate/rtl/raiden2_seibu_latch.sv` |
| YM3812 | `jtopl/hdl/jtopl2.v` plus transitive `cfg/jtopl2.yaml` / `jt26.yaml` files | Integrated OPL2 wrapper from `raiden`; D-Con is an alternate but its clocks and pin7 differ |
| MSM6295 | `jt6295/hdl/` and donor integrated JT6295 | One chip; pin7 high; 28.636363/28 clock; include interpolation HEX files and RAM/filter dependencies |
| YM3014 / HB-45A / LA4460 | JTOPL/JT6295 samples + donor signed mixer/filter/limiter | Digital functional equivalent; mono to both MiSTer output channels, optional appropriate mix controls |
| RAM / ROM / buses / PALs / 74xx | Primary shared RAM, BRAM wrappers, SDRAM/DDR arbiters, address decode and timing | Four PALs undumped; preserve decoded behavior and byte enables; do not invent PAL netlists |
| Reset / oscillators / CRTC sync | Primary PLL, CE and `Raiden2_video_timing.sv` | Fixed 8 MHz pixels, 282 lines, 256 active; recalculate actual SDC CE constraints only in final hardware phase |
| JAMMA / RC220 / coins / DIPs | Template `hps_io` and donor input/sound glue | Four players, three game buttons each, four coins/starts where target DIP mode permits; verify actual semantic button labels |
| SDRAM / DDR3 / download | Primary `sdram.sv`, `raiden2_ddram.sv`, DDR clients and ROM arbitration | Maintain proven backpressure/CDC; loader staging must acknowledge writes before CPU release |
| MiSTer video/scaler/crop/flip | Untouched root `sys/`, primary wrapper and `video_freak` / `arcade_video` | Horizontal 4:3 by default; no inherited mandatory TATE or shooter-only menu controls |
| CRT Adjust | `crt-adjust/` plus primary `crt_adjust.sv` / `crt_vsize.sv` | Keep feature gating and default neutral output; include V-Size only if resource/behavior budget permits |
| High scores | `hiscores/` | Confirm target RAM sentinels and table addresses against US code; do not blindly copy Raiden addresses |
| Scanline-engine fallback | `jtcores/modules/jtframe/hdl/video/` object drawing / buffering utilities | Only replace a failed donor path; avoid starting a generic engine rewrite before measuring it |

## Other staged boards and rejected base choices

- `seibu-cup-soccer`: shared COP/CRTC family, four-player and protection
  references; 68000 board and different COP generation, not an identical PCB.
- `raiden`: V30 + YM3812/one-OKI donor; older dual-V30 video/protection board,
  so use audio/CPU portions rather than its whole game wrapper.
- `dcon`, `blood-bros`, `sky-smasher`: sound, tile, reset, input and glue
  alternatives; older 68000/Seibu video family.
- `denjin-makai`, `gundam-sd`, `sdgundam-rainbow`, `legionnaire`: additional
  COP commands, collisions, sorting and sprite behavior; older/related board
  variants and per-game timing are not transferred wholesale.
- `seibu-spi`: later SEI25x video lineage; different CPU/sound/cipher and no
  repository-wide license found. Supporting reference only by default.
- `irem-m72` and `nec-test`: V30 CPU development and bus-timing evidence;
  Irem graphics/sound are unrelated.
- `irem-m92`: V33 source used by the spacestate alternate. Its CPU is not
  the target V30 and should not displace the selected CPU without evidence.

## Search record and honest gaps

Searches covered the supplied repositories, rmonic79's public repository
inventory (saved locally), MiSTer-devel's NEC CPU boards, Jotego's
sound/JTFRAME sources, SeibuSPI and public Patreon announcements. The
Raiden II/DX Patreon release and the later Cup Soccer COP investigation
point to the public source; a binary-only Patreon core is not a new RTL
dependency. No paywall or private source is required for the selected path.

Useful first-party references:

- [Raiden II/DX announcement](https://www.patreon.com/IBeceriVideoludici/posts/surprise-raiden-167665330)
- [Cup Soccer COP investigation](https://www.patreon.com/IBeceriVideoludici/posts/seibu-cup-soccer-170241164)
- [JTOPL chip support](https://github.com/jotego/jtopl)
- [JTFRAME in jtcores](https://github.com/jotego/jtcores/tree/master/modules/jtframe)
- [Official MiSTer core requirements](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/Contributing-a-Core-to-MiSTer-FPGA)

Open work is SEI251-specific cipher/key behavior, target COP command
coverage and sort correctness, observable undumped-PAL glue, and target
priority/blend rules. These gaps have usable family donors and MAME
references, but no staged source is claimed to be a complete exact chip
replacement. Do not mark them complete until actual target gameplay works.
