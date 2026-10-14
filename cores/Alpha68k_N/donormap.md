# Donor integration map

All twelve repositories below are downloaded locally and pinned in `donors.lock.json`. Its full commit IDs, license-file paths and recorded submodule revisions are authoritative. `donors/<name>/STAGED_PROVENANCE.json` repeats each local checkout's identity. These are staged sources, not integrated or locally tested modules.

The selection favors native Verilog/SystemVerilog for a single real RTL design shared by Quartus and Verilator. Keep original VHDL and generated Verilog together for provenance. Verify a used module's existing targeted regression once; do not run every unrelated donor's suite.

## Repository inventory

| Local donor | Upstream | Pinned revision (short) | Purpose |
|---|---|---|---|
| `donors/snk_triplez80` | [MiSTer SNK TripleZ80](https://github.com/MiSTer-devel/Arcade-SNK_TripleZ80_MiSTer) | `bd2e2846ffac` | User-suggested schematic/TTL video design, T80, sound handshake, pause/controls examples |
| `donors/fx68k` | [ijor/fx68k](https://github.com/ijor/fx68k) | `0602ee4627b1` | Primary cycle-oriented 68000 CPU in SystemVerilog, micro/nanorom included |
| `donors/jt12` | [Jotego jt12](https://github.com/jotego/jt12) | `dc9be7c1ff75` | JT03 YM2203 FM+SSG, pinned nested dependencies retrieved |
| `donors/jt49` | [Jotego jt49](https://github.com/jotego/jt49) | `47301ed51374` | Two external AY PSGs, AY volume/divider and I/O adaptation |
| `donors/t80` | [MiSTer-devel T80](https://github.com/MiSTer-devel/T80) | `830fd0315f0a` | Original VHDL Z80 reference, BSD-style notice in source |
| `donors/t48` | [Arnim Laeuger's T48](https://github.com/devsaurus/t48) | `837bd24f8a93` | Cycle-oriented MCS-48/UPI upstream source, test resources, variant documentation |
| `donors/jtcores` | [Jotego jtcores](https://github.com/jotego/jtcores) | `548b87b32a1b` | Sparse complete JTFRAME, jt680x, Kiwi wrapper references; native Verilog T80/T48, video/memory infrastructure |
| `donors/alpha68k` | [va7deo/alpha68k](https://github.com/va7deo/alpha68k) | `d3d0839730f1` | Closest Alpha custom-chip and INPUT84 research; fx68k/sound/memory integration examples |
| `donors/nmk16` | [kuzearcade NMK16](https://github.com/kuzearcade/Arcade-NMK16_MiSTer) | `c6af34e944de` | Sparse MC68705R3 wrapper, microcode, utility and proof reference |
| `donors/ql` | [MiSTer QL](https://github.com/MiSTer-devel/QL_MiSTer) | `1844a2a9d9ea` | Sparse working T48/T8049 wrapper reference and COPYING notice |
| `donors/hiscores` | [MiSTer Hiscores](https://github.com/MiSTer-devel/Hiscores_MiSTer) | `31789f3b6bf6` | `hiscore.v`, pause/borrow protocol, file persistence |
| `donors/crt_adjust` | [rmonic79 CRT Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) | `c682de9f4acc` | Native analog adjustment integration and timing examples |

Template framework: [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer), exact initial commit in `research/source_manifest.json`. Its `sys/` is already the active scaffold. Do not import a donor's older `sys/` over it.

## Every identified functional component

| PCB component / function | Selected source or implementation | Integration / evidence limit |
|---|---|---|
| Motorola 68000, 6 MHz | `donors/fx68k/fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | Own registered bus adapter; alternating phase enables, DTACK, byte strobes, autovector IRQ1/IRQ2, reset and HALT. Keep ROM lookup paths valid in both tools. |
| NEC D780C-1 / Z80 | `donors/jtcores/modules/jtframe/hdl/cpu/t80/T80s.v` and its dependency closure | Generated Verilog allows native Verilator. Preserve original `donors/t80` as comparison. Use actual Z80 mode, correct CEN and bus timing, vblank IRQ and 4 kHz NMI. |
| Kyros Alpha 8511 / MC68705U3-compatible MCU | Compatibility FSM from the 0.289 callbacks; firmware candidate `modules/jt680x/hdl/jt6805*.v` | No verified complete Kyros 8511 drop-in RTL was found. Full raw bootleg firmware is staged. jt6805 needs microcode generation and a U3 peripheral/memory/port/timer wrapper. |
| 6805 wrapper and microcode | `donors/jtcores/modules/jtframe/hdl/cpu/jtframe_6805mcu.v`; `donors/nmk16/rtl/m68705/` | P5/R3 examples must be adapted to U3, not renamed. NMK16's reported ~960k-instruction comparison is upstream evidence, not a local pass and not proof of Kyros peripheral timing. Prefer matched upstream microcode generation; alternate NMK microcode only after interface/version check. |
| Stingray Alpha 8511, modeled as Intel 8748 | `donors/jtcores/modules/jtframe/hdl/cpu/t48/t48_core.v` plus appropriate wrapper / dependency closure | Configure MCS-48 8748 mode, 1 KiB ROM, correct data RAM/stack/timer and BUS/P1/P2/T0/T1; no UPI protocol substitution. MAME clock is uncertain. |
| T48 supporting reference | `donors/t48/rtl/vhdl/`, `donors/ql/rtl/T48/`, `donors/jtcores/cores/kiwi/` | QL's 8049 and Kiwi's 8742 show integration; neither is the Stingray variant. Jotego's public [Extermination article](https://www.patreon.com/jotego/posts/extermination-76880945) explains T48 adoption for 8742. Public code is the source donor; no beta keys/paywalled binaries are needed. |
| Yamaha YM2203, 2 MHz | `donors/jt12/hdl/jt03.v`, `target/quartus/jt03.qip`, pinned nested `jt49` | Include both FM and internal SSG. Preserve one nested version for JT03; use a separate module/version namespace for external jt49 if necessary. Verify status/timer behavior actually used by software. |
| Two AY-3-8910, 2 MHz | `donors/jt49/hdl/jt49.v`, `jt49_bus.v`, supporting HDL | Match AY divider/volume behavior, register widths, envelope and noise; tie unused input ports according to observed board/software use. YM2149 compatibility alone does not prove exact AY transfer behavior. |
| Software 8-bit R-2R DAC | New signed/scaled latch in sound RTL | Source is MAME's write map and DAC reference. Actual DAC identity/analog network partly unknown, especially Stingray. |
| YM3014 serial DAC | JT03's digital sample output and calibrated mixer | FM numerical output replaces the serial off-chip DAC function; no unnecessary serial DAC emulation. Preserve pitch and gain; analog reconstruction is separate. |
| LM324, UPC1181, volume pots, passive audio network | Wide digital mixer, gain controls, measured filter if needed | Analog components do not need independent synthesizable CPUs. A filter is justified by schematic/recording evidence; output through MiSTer audio infrastructure. |
| Main-board 2016 / 5814 SRAM | Inferred M10K dual-port RAM, donor RAM coding patterns | Work/shared RAM 4 KiB, strip RAM 8 KiB; coherent CPU/video/MCU access and explicit read-during-write behavior. Physical chip placement remains documented in MAME PCB diagram. |
| Sound-board 2114 SRAM | Inferred sound RAM | MAME Kyros window 2 KiB; two physical x4 chips imply 1 KiB. Aliasing remains B14, not a verified correction. Stingray map differs. |
| Program EPROMs | Staged byte-interleaved `maincpu.bin`; BRAM download target initially | Four Kyros ROM halves have `ROM_CONTINUE` remapping. One image and one loader contract are shared by simulation and MRA generation. |
| Sound EPROMs | Staged `audiocpu.bin`, BRAM initial design | Original sizes/fill and per-set maps from manifest. No analog-program-ROM donor is required. |
| Graphics EPROMs / plane muxing | Board-specific N address/bit decoder plus JTFRAME row/line engine primitives | 8 x 2048 8x8x3bpp banks for Kyros; 4 x 1024 banks for Stingray. Later Alpha68k 16x16 sprite engines are not equivalent. |
| Strip/object sequencing | `modules/jtframe/hdl/video/jtframe_objdraw*.v`, `hdl/ram/jtframe_obj_buffer.v` as pipeline references | N-specific 32 strips x 32 tiles per group, exact bank/CLUT address and three-group priority. Keep/adapt primitives only if they reduce code and fit 8x8 rows. No whole-game framebuffer renderer. |
| Color and CLUT PROMs | Inferred ROMs generated from audited `proms`, `clut_proms`, `color_proms` | Exact nibble concatenation, PROM RGB weights and indirect palette. Kyros color `0xff` is valid. |
| ALPHA-INPUT84 modules, coin/start/DIP wiring | Alpha donor board research + explicit N input formatter/coin logic | No certified exact INPUT84 die RTL found. Kyros uses an 8-way joystick; do not import later Alpha rotary control behavior into this game. |
| 24 MHz / 16 MHz crystals and dividers | Master PLL plus enables | Proposed 48 MHz game clock divides exactly for Kyros and pixel/PSG rates; Stingray Z80/MCU require rational enables. Internal CPU/chip dividers must be counted once. |
| Sync, counters, address decode, generic TTL | Plain counters/registers; `donors/snk_triplez80/rtl/ttl/` as donor library | Reusable 74138/139/153/etc. exist. Copy only chips demonstrably needed; unlabelled glue is expressed by its functional truth table. Timing gates use clock enables, not generated fabric clocks. |
| 40174 / 4013 sound latches/flip-flops | Small synchronous registers/FSM; donor TTL conventions | Infer functional latch edges from wiring/reference traces. MAME ignores some related sound writes; B13 records the gap. |
| Background byte / watchdog | New board register and reset policy | Low byte selects background indirect color; high-byte watchdog behavior is unqualified. Preserve separate byte strobes. |
| External SDRAM, FPGA infrastructure | JTFRAME Verilog SDRAM controller/request modules under `modules/jtframe/hdl/`; Alpha donor VHDL memory reference | Prefer graphics-only SDRAM with CPUs in BRAM to minimize arbitration. External SDRAM is MiSTer infrastructure, not original PCB hardware. Select a measured-latency module at P2 and retain its source provenance. |
| HPS/ioctl, HDMI/VGA/audio, scaler/rotation | Active template `sys/`; framework `arcade_video`, `video_freak`, screen-rotation examples | Share the same board RTL with simulation. Runtime DDR3 is for framework scaling/rotation unless measurements justify game memory use. |
| CRT Adjust | `donors/crt_adjust/` | Integrate H/V position/size only after native raster is correct. Check analog/direct video in final hardware phase. |
| Hiscore / pause | `donors/hiscores/hiscore.v`, donor `rtl/pause.v` examples | Borrow work RAM at a safe pause; explicit arbitration with MCU; generate set-specific high-score tables. |
| Reset / power-on / ROM-load completion | Template reset and N reset/load FSM | Explicitly initialize only needed state once. No held-reset clearing of whole arrays every simulation clock. |

## Choices rejected or constrained

- **TG68K.C:** credible 68000 alternative, but VHDL conversion adds friction where staged fx68k directly meets 6 MHz cycle/bus needs. No second CPU implementation is needed for primary bring-up.
- **Whole TripleZ80 core:** valuable clock-enabled/TTL structure, but it has three Z80s and a different video/sound PCB. Its YM3526 and rotary-specific logic are not N-board devices.
- **Whole va7deo Alpha68k core:** strongest family research donor; it implements later board generations. Its sprite format and measured Gang Wars MCU rate cannot be used as Kyros/Stingray facts.
- **NMK16 whole project:** only the 6805 wrapper/microcode/evidence is useful here; unrelated NMK CPUs, graphics and sound are not dependencies.
- **Undumped original Kyros MCU as complete firmware:** rejected. The raw full bootleg image is the firmware experiment; MAME HLE is the initial compatibility oracle.
- **Patreon beta bitstreams and secret unlock keys:** not source donors. Public T48/JTFRAME/JT03/JT49 code covers the relevant silicon without importing inaccessible beta dependencies.

All identified functions have a source donor, a small planned RTL implementation, or an explicitly documented unresolved physical detail. That is complete **functional coverage**, not a claim of a ready-made verified donor for every custom chip or every unlabelled transistor. Obtain additional PCB/schematic evidence only when a specific mismatch requires it.

Before copying modules into tracked `rtl/vendor/`, record URL, full revision, precise source file list, license/notice, local changes and one relevant upstream regression result in `PROVENANCE.md`. `THIRD_PARTY.md` and a dependency closure must accompany integration. The staging lock records source identity, not local fidelity or resource results.

## Imported SDRAM closure (P2, 2026-10-09)

`rtl/vendor/jtframe_sdram/` imports unchanged `jtframe_sdram64`, bank,
initialization, latch and refresh modules from JTCOREs revision
`548b87b32a1b528a16cb41f689accb179e85d1a8`. GPL-3.0-or-later source notices
and the donor LICENSE are retained; per-file hashes and source paths are in
its `provenance.json`. Reproduction: `python scripts/vendor_sdram.py`.

`alpha68kn_gfxmem` supplies download FIFO/masked writes and runtime row-pair
reads; controller settings AW22/HF0/CL2/burst1 target the 48 MHz interface.
Native complete-payload pin-level proof: `research/gfxmem_loader.json`.
The controller and its external phase clock still need actual fitted timing
qualification. No whole-frame graphics snapshot or substitute game engine is
introduced by this integration.

## P5 sound source integration — 2026-10-09

JT03's complete QIP closure is imported under rtl/vendor/jt12 with its pinned
nested PSG version preserved. External AY donors retain originals under
rtl/vendor/ay49/original and derive the a68n_ay49 namespace under hdl, including
AY16 transfer/envelope and reset handling. Hashes, licenses and reproducer:
rtl/vendor/audio_sources.json and scripts/stage_audio_sources.py.
The inactive rtl/alpha68kn_audio.qip describes the source closure; the
alpha68kn_soundchips, alpha68kn_mixer and alpha68kn_audio modules compile and
pass isolated contracts. See docs/SOUND_HARDWARE.md for clock, port, numerical
route and fidelity details. Real Z80 integration/game audio is still pending.

### Audio integration status (2026-10-09)

The staged jt03/JT49/adapted external AYs are instantiated in the real
alpha68kn_system shared simulation path through alpha68kn_audio. Z80 reads
return chip status/register data and qualified board writes drive the chips;
the DAC latch drives the mixer. All use the 48 MHz master with enables.
Game-driven audio acceptance is pending the bound native run in progress.md.
The MiSTer wrapper is still a scaffold; its P8 integration and Quartus gates
remain pending, with Quartus disabled by the user.


### DIP transport integration (2026-10-09)

Pinned `donors/snk_triplez80/Arcade-SNK_TripleZ80.sv:455` supplies the MiSTer convention: ioctl index254 writes low-byte DIP banks selected by byte address. Alpha68k N currently has one physical bank; its wrapper accepts address0 and initializes0x8E. Actual real-HPS tests cover address isolation/default restore, followed by31 fields of real ROM/CPU/video boot (`research/wrapper_dip31_qualification.json`). The donor is used as an interface reference; its game input/rotary behavior is not imported. MRA names/options remain a separate required integration item.


### YMFM versus standalone AY output ranges

JT03's internal SSG sum is positive0..765. Current MAME0.289 YMFM has positive0..16382 per channel; Alpha68k N routes these at0.30. The game mixer now uses that numerical range without the standalone AY bias. External AY cores retain the legacy normalized range. Source hashes, independent route tests and actual RTL replay are in `docs/AUDIO_NORMALIZATION.md` and its manifests. Donor internals and clocks are unchanged; late music component/curve comparison remains pending.

### Requested MiSTer feature integration (2026-10-09)

`rtl/vendor/mister_features/PROVENANCE.md` pins unmodified Hiscores_MiSTer v14
and CRT Adjust/V-Size sources, with retained GPL notices. `alpha68kn_crt.sv`
adapts their read cadence and sync blanking at the core boundary; `sys/` remains
pinned. Hiscore RAM ownership pauses all CPU/bus writers, checks acknowledgement
and range, and preserves big-endian lanes. Standard byte HPS transport supports
indices3/4/254 and pairs index0 ROM bytes into the existing loader. The framework
supplies integer scaling, framebuffer rotation, analog/direct and Y-C routing.
The standard SNK TripleZ80 interface is the comparison reference; no objective
ranking or physical output pass is claimed. MRA generation uses audited MAME
0.289 input/ROM/hiscore records and independently checks all packed ROM bytes.
See `docs/FEATURES.md` and `research/feature_qualification.json` for checked
behavior and unresolved physical, all-game, and fitted-design gates.

### 2026-10-09 — internal YM SSG transfer adaptation

JT03/JT12 expose SSG_COMP, retaining donor default1. The project selects5;
embedded jt49 bank5 derives from MAME0.289 YMFM's32 amplitudes with conditional
YM fixed-volume indexing. scripts/stage_audio_sources.py reproduces the patch,
normalizes adapted line endings and verifies32 entries. rtl/vendor/audio_sources.json
records source/staged hashes, pins, transfer source and quantization. Notices
remain intact. Corrected real-chip replay completed1,800 fields and its finite activity/level
comparison passes; the silent first import is retained as failed. The current
full-system tests and combined waveform residuals remain unqualified. See docs/YM_SSG_CURVE.md. No fitted qualification while
Quartus is held.

## Real8748 integration boundary
Pinned T48: rtl/vendor/t48/t48_core.v, SOURCE.json and LICENSE.upstream.
rtl/alpha68kn_mcu.sv wraps64-byte RAM, fractional oscillator and Alpha8511 pins.
Enabled BUS/P2 write-strobe outputs are the only donor logic adaptation.
sim/build_t48_probe.sh and scripts/run_t48_probe.py execute actual1KiB firmware
in a bounded diagnostic. Production board/files.qip integration waits for Kyros
qualification and paired handshake evidence. See docs/STINGRAY_MCU_INTERFACE.md.

## Real8748 donor boundary — 2026-10-10
rtl/vendor/t48/t48_core.v now stages the pinned self-contained Verilog donor
with original license and two enabled BUS/P2 write observation ports. Removing
that adaptation restores original CPU/timer logic exactly.
rtl/alpha68kn_mcu.sv implements64-byte RAM, fractional oscillator enables and
Alpha8511 pins. sim/build_t48_probe.sh/scripts/run_t48_probe.py executed the
actual1KiB firmware: one halt/release, shared write and IRQ2 activity verified.
Production board inclusion waits for Kyros qualification and paired handshake
evidence; no full Stingray game pass. See docs/STINGRAY_MCU_INTERFACE.md.

## Current donor qualification — 2026-10-10

Quartus has resumed. Dated hold/scaffold paragraphs above record earlier phase
state; progress.md and AGENTS.md govern current integration and check-only flow.
The complete-design map has exposed unsynthesized sound ROM storage; its
private write-index inference proof is pending the unchanged twin. No complete
fitted timing or resource pass is available.

The pinned JT03 embedded jt49 divider forces tone period zero low. The isolated
current-source test proves silence, while pinned MAME YMFM uses period one.
The private one-line correction preserves the GPL notice and passes periods
0/1/37 with exact 768/768/28416 master-tick rising-edge gaps. Nonzero cadence
is unchanged; setup phase changes are explicitly retained. Candidate hash
2c4e8f7924b89756c339d29b58e971238fdd8cbd8f23c64b8c9a78a6990dae4a,
original hash 37f534e196e998b47e09fefc2ac6bfdaa062756193ef0212a4595c1a44b9d491.
See research/ym2203_ssg_pitch_stage/import_manifest.json. The candidate is
retained under research, with production integration still pending.

The real8748 donor now has a private coupled-board preparation patch and
bounded native diagnostic namespace. Physical HALT/arbitration/IRQ ordering
and full Stingray attract/gameplay remain unqualified; static/model cases do
not satisfy that boundary. See research/stingray_combined_stage/integration_contract.json.

## Integrated P6/P2 development graph — 2026-10-11

The current source adds `rtl/alpha68kn_mcu.sv` and `rtl/vendor/t48/t48_core.v` to files.qip. The donor remains JTFRAME revision548b87b32a1b528a16cb41f689accb179e85d1a8 / Arnim Laeuger T48. The fork retains enabled BUS/P2 decoder observations and additionally exports the architectural P2 latch; SOURCE.json and original LICENSE.upstream travel with it. No donor CPU/timer clock logic is changed by the P2 export.

The board profile2 path integrates real firmware ROM, command byte, coin T0/T1, shared reply, firmware IRQ2, flip, rational enables and accepted-AS HALT drain. Kyros/Japan preserve their existing board functional cone. The shared nested JT49 divider removes period-zero constant output; its fork manifest binds baseline and proposed hashes. This shared sound correction applies to all profiles and needs current-source acceptance.

The finite181 protocol/source and realHPS wrapper gates passed before central integration; strict RAM and full1800 acceptance remain open. The existing complete161-source fit does not include the new MCU/T48 assignments or changed board/divider/donor, and cannot qualify this image. Pinned sys remains external and unchanged. Profile2 production admission now accepts the qualified format; complete current-source timing/resource and full lifecycle acceptance remain required.


Prepared source join v4 (2026-10-11): MCU program storage uses two 2048x8 parity banks, registered bank reads and captured address bit0. All4096 bytes, adjacent-loader lane ordering, FFF wrap and one-cycle program read are preserved by the source-extracted79875-comparison smoke (actual build/run0). This modifies storage RTL in simulation and synthesis; the v3 byte-identical preprocessing result only described the superseded diagnostic guard. Current board43b8c6e7600e4c4089f0d3c0e4a15637be8bfcbdd626ddd0bc0e222b7b1553ce is separately staged, not part of the historical181 executable. Original joined MAP98.65% and guard-only MAP98.8046% estimates failed the ALM requirement; no FIT was run on those graphs. Root application remains held pending actual banked ROM RAM inference and accepted resource estimates. T48/P6, shared SSG period0 correction, native dependency recipe, H0O5, profile<=2 and reviewed additiveSDC are preserved. Paired storage proof does not qualify full-board gameplay, mixed-port hardware collisions, timing or I/O.


## 2026-10-11 SDRAM controller timing integration

The pinned `jtframe_sdram64` donor remains unchanged. Its existing `HF` configuration in `rtl/alpha68kn_gfxmem.sv` is now 1 instead of 0 at the 48 MHz game/memory master clock; no new clock domain or donor source patch is introduced. This changes the legal ACT-to-data and PRE-to-ACT/refresh command separation from one cycle (20.833 ns) to two (41.667 ns), satisfying the common Alliance -7 grade 21 ns minimum. Primary device-table/pad checker evidence is retained in local staging `research/dual_release_20261011/sdram_hf1_v2/`.

Full393216 graphics bytes and24576 paired reads remain exact. Recorded whole Kyros/Stingray RGB and dense stress frames pass; current realEMU/HPS wrapper boot/protocol tests pass for both profiles with saved images byte-exact to HF0. The bounded selected-line sweep covers3072 refresh alignments with cold/eight warm histories, worst3068/3072 cycles, no deadline errors/overflow. Corrected8192-interval retention windows pass. Independent integration review: `timing/hf1_phase_independent_review_v1/import_manifest.json` SHA882e4f7685f4c6a5c6cce3d601dc2af4b214486e2deb2c1a369f321d618bc8aa.

This is finite component/wrapper qualification, not universal controller-history or arbitrary physical-module electrical proof. Runtime deadline assertions remain active. Native fit/STA and resource qualification belong to the matching image receipts, not the previous HF0 fit. Full-game logic/source is unchanged by this memory-controller parameter.


## Core-owned framework adapters — 2026-10-11

rtl/alpha68kn_video_mixer.sv retains the pinned MiSTer mixer module/interface/notices and moves the RGB input buses to shared generate scope. This avoids implicit scalar nets when the gamma/bypass branch references them. Source SHA63f65406f82de31e749d5f9e9754b4b84746111083145acd5adc7a57b06003a2; original sys/video_mixer.sv31ed2c... remains untouched. constraints/alpha68kn_sys_binding.tcl pins and evaluates the original framework Tcl while redirecting its one QIP. constraints/alpha68kn_sys.qip preserves all35 ordered assignments and original paths, redirecting only the mixer and filtered framework SDC. The filtered SDC removes exactly the three blanket audio output cuts, with scoped replacements and PAD timing in alpha68kn_pad_contract.sdc. alpha68kn_pad_loads.tcl declares67 Cyclone-V-supported receiver capacitances in farads. These are source-reviewed integration adapters, not independently demonstrated universal board electrical support. Fresh joined fit/STA remains required.
