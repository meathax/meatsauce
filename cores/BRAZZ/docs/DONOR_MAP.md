# Donor coverage and selection

Nine public snapshots are staged, pinned to commits. `../donors/manifest.json` is the exact inventory. Each donor directory has `PROVENANCE.json/.md` and `FILES.json`. Sources are reference snapshots, not already integrated or tested modules. Binary RBF/SOF releases and ROM fixtures were excluded. The pristine template remains the platform donor in the project root.

## Best staged candidates

| Donor | Selected role / exact entry point | Reuse classification |
|---|---|---|
| [JTcores/JTFRAME](https://github.com/jotego/jtcores) | `donors/jtframe/modules/jtframe/hdl/sdram/jtframe_sdram.v`, `jtframe_sdram64.v`, `jtframe_burst_sdram.v`, cache blocks; `hdl/ram/jtframe_dual_ram*.v`; `hdl/clocking/`; `hdl/jtframe_uart.v` | Primary directly reusable primitives after adapting geometry/bus/CE; not a complete Crystal SoC |
| [PSX MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) | `rtl/gpu_pixelpipeline.vhd`, `gpu_rect.vhd`, `gpu_poly.vhd`, `gpu_videoout*.vhd`, `rtl/sdram.sv`, `rtl/ddram.sv`; existing `sim/gpu/` | Closest texture/pixel/cache/framebuffer transport design reference; VHDL and PSX command/blend semantics prevent direct GPU reuse |
| [Saturn MiSTer](https://github.com/MiSTer-devel/Saturn_MiSTer) | `rtl/Saturn/VDP1/VDP1.sv` + package; `rtl/Saturn/SCSP/SCSP.sv` + package; `rtl/sdram1.sv`, `sdram2.sv`, `ddram.sv` | Closest SystemVerilog textured framebuffer and 32-voice scheduling reference; license metadata NOASSERTION, no root license found; establish terms before copying RTL |
| [NeoGeo MiSTer](https://github.com/MiSTer-devel/NeoGeo_MiSTer) | `rtl/io/upd4990.v`; backup-RAM/RTC HPS integration; `rtl/mem/` | RTC calendar/BCD/persistence ideas and generic memory integration; uPD4990 is not DS1302 register/serial compatible |
| [Ultraembedded SDRAM AXI4](https://github.com/ultraembedded/core_sdram_axi4) | `src_v/sdram_axi_core.v`, `sdram_axi.v`, `sdram_axi_pmem.v`; `tb/` | Licensed compact Verilog controller fallback and existing Verilator/SystemC memory tests; geometry/width/burst/latency must fit MiSTer |
| [CRT Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) | `rtl/crt_adjust.sv`, core-side integration docs/examples | Direct platform feature donor; preserve native VBlank; do not use sys-side variant; V-size optional |
| [Hiscores MiSTer](https://github.com/JimmyStones/Hiscores_MiSTer) | Source helper and example interface in its staged file inventory | Conditional score-save donor only if actual score storage is not already persisted by NVRAM |
| [SiliconRE](https://github.com/furrtek/SiliconRE) | `Konami/054539/` diagrams/SDF/schematics/trace | Research documentation only; selected snapshot contains no complete K054539 RTL implementation; not a VRender0 sound donor |
| [RISC8 PIC-compatible](https://github.com/collectivertl/risc8_tcoonan) | `rtl/`, `dv/`, `doc/`; compatible with PIC16C57 per upstream description | Licensed future research fallback; cartridge MCU is unidentified/undumped and may not be a 16C57; not required to implement MAME's crysking protection patches |

JTFRAME includes useful existing SDRAM/clock/cache/RAM benches under `ver/` and `verilator/tests/`; run only selected/adapted block tests when that block is used. Controller tests are not proof of game/video bandwidth. Source snapshots may contain submodule pointers: `FILES.json` is the authority for actually downloaded files. Referencing a submodule does not mean its source is staged.

## Every documented component/function

| PCB/SoC component | Coverage / donor decision |
|---|---|
| SE3208 | No compatible public synthesizable donor found. Stage complete MAME CPU + disassembler as BSD functional reference; write custom RTL. Generic Hyperstone/SH2/ARM/RISC-V donors are incompatible. |
| VRender0 local/system memory control | JTFRAME/PSX/SDRAM transport primitives + custom address/lane/ownership/register logic. |
| 2 DMA channels | Custom VRender0 descriptors/control/IRQ; generic cache/FIFO/arbitration donors only. |
| 4 timers | Small custom counters/prescalers/IRQ from MAME. No need to import an unrelated SoC timer register bank. |
| IRQ controller | Custom vector/pending/mask/ack logic; no compatible drop-in found. |
| 32 GPIO / chip selects / watchdog / PWM / SIO | Custom source-compatible registers/decoders, with runtime access diagnostics; no unrelated peripheral core needed for empty/unexercised source regions. |
| 2 UARTs | JTFRAME UART datapath candidate; custom VRender0 register/FIFO/IRQ wrapper. MAME UART implementation staged. |
| CRTC/PLL/video output | Custom programmable source timing/IRQ; platform PLL/CE + standard template arcade_video/video_freak/scaler output. |
| VRender0 packet/texture/ROZ/blend/RGB565 framebuffer | Custom target GPU; staged PSX/Saturn architecture and JTFRAME cache/FIFO/line-buffer primitives. No full compatible GPU found. |
| VRender0 32-channel wavetable SPU | Custom target SPU from MAME; SCSP architecture reference; µ-law/sample/envelope/IRQ behavior is not interchangeable with SCSP/K054539. |
| HY57V651620 ×3 | External-memory storage; JTFRAME primary / Ultraembedded fallback / PSX-DDR transport reference. Controllers serve FPGA memory, not cycle-exact emulation of each physical SDRAM chip. |
| GM76C256 battery SRAM | Ordinary RAM + MiSTer persistence, source map 64 KiB vs physical note 32 KiB retained as an explicit uncertainty. |
| MX27L1000 BIOS | Audited original ROM bytes; existing template loader/BRAM or SDRAM. No MCU/flash controller needed for read-only boot. |
| Intel E28F128J3A ×3 / unpopulated U4–U8 | Custom bank/command/read-ID/erased-bank behavior plus DDR ROM image; MAME `intelfsh` staged as broader reference, though driver uses its own small command handler. |
| dgSMART-PR3 scratched PIC16xxx? | MAME's exact eight-patch behavior; PIC-compatible RISC8 staged conditionally, not falsely labelled the actual chip. No game PIC ROM available. |
| DS1302 | MAME device staged; NeoGeo BCD/calendar helpers reference; custom compatible serial slave. A host driver for a real DS1302 is the wrong direction. |
| ATF16V8 PAL | Address/control decode equivalent from MAME map; no PAL fuse equations/dump identified. |
| 74HC138 cartridge decoder | Simple combinational decode; separate large donor core unnecessary. |
| DS1233 reset supervisor, SW1 | Platform reset synchronizer/readiness + CPU/board reset behavior. |
| SW2/SW3, 8-way DIP, JAMMA inputs | Template HPS I/O + custom active-low matrix/service/test/DIP state. |
| TD62003, coin counters, LEDs/lamps | Custom digital output/counter state. Analog transistor switching is external to FPGA behavior. |
| DA1133A/DA1311A DAC note, TDA1519 amplifier, VOL | MiSTer stereo audio output and mix/volume controls; no amplifier/DAC transistor RTL required. |
| 14.31818 MHz, 32.768 kHz, 3.579545 MHz crystals | PLL/clock enables/calendar tick; cartridge clock only relevant if a future actual MCU implementation is possible. |
| RTC battery, power/passives, CN1/CN2/connectors | Persistence/platform electrical infrastructure; CN2 purpose unknown. No invented behavioral chip or unsupported external device. |
| MiSTer HDMI/analog scaler/rotation/HPS/SD bridge | Official unmodified template `sys/`; no alternate framework replacement. |
| CRT geometry / score-save / pause | CRT Adjust direct donor; conditional Hiscores; small custom shared pause arbitration. |

## Search depth and rejected candidates

Preparation used primary MAME sources, targeted public web searches for SE3208/EISC/VRender0/Crystal System FPGA/RTL, MiSTer-devel's public cores, current JTcores source/catalogue/submodule list, OpenCores-indexed results and public Patreon mentions. The precise GitHub API repository searches and results are saved in `research_log.json`: `se3208`, `vrender0` and `CrystalSystem FPGA` each returned zero repositories at query time. Code inside unrelated repositories/private work can still exist; no exhaustive global absence claim is made.

- Historical `jotego/jtframe` returned 404; recovered from current `jotego/jtcores/modules/jtframe` instead.
- `jotego/jt539` returned 404; not represented as downloaded or usable. The public jtcores `.gitmodules` reference is insufficient to retrieve unavailable source.
- `ChenJianyunp/DS1302_verilog` search result has no declared license and is a board-side controller example, not an emulated RTC chip. `lvandesigner/Indu_Monitor` uses an external DS1302 and is not a compatible slave donor.
- `EddieHyun/PIC16C57` and `hcyang1012/PIC16C57-Verilog` lacked declared license metadata; the licensed RISC8 candidate was selected for staging. None supplies this cartridge's unknown firmware.
- Commercial ADChips EISC/SE3208 FPGA/IP references and academic SE3208 designs establish that implementations have existed; no redistributable synthesizable target source was located. They are not donors.
- Public Patreon/core-release mentions did not yield target SE3208/VRender0 source. No paid/private HDL was downloaded, and an RBF-only release would not be a source donor.
- PSX/Saturn renderer and PCM architectures are useful examples but not chip replacements. SiliconRE selected material is documentation only. Ordinary 68k/Z80/Yamaha/OKI cores are not relevant to this PCB.

The quickest route is now custom CPU/SoC/video/audio against the pinned MAME models with staged primitive/architecture reuse. Reopen donor discovery only if a concrete missing block or new licensed compatible source emerges.
