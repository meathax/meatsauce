# Sheriff donor map and integration contracts

Prepared 2026-10-09. All repositories below are actually downloaded under `donors/`; exact revisions are recorded in `docs/evidence/donors.json`. The template is at revision `3ea1134cf05d62c2b1db30362277a823d739ced2`. Donor bank files are local/ignored, with reproducible provenance and selected pristine copies in `rtl/vendor/`. **Downloaded does not mean simulated, qualified or integrated.**

Scope: only Nintendo parent `sheriff`. Related-board/repository names below identify useful source provenance, not supported games. Excluded hardware and donor research is preserved in `docs/DONORMAP_FAMILY_ARCHIVE_20261010.md` and adds no completion requirements.

## Staged repositories

| Source | Pinned commit | Role / qualification |
|---|---|---|
| [MiSTer Template](https://github.com/MiSTer-devel/Template_MiSTer) | `3ea1134cf05d62c2b1db30362277a823d739ced2` | Active platform project; `sys/` unchanged; GPL-2.0-or-later template |
| [MiSTer Space Invaders](https://github.com/MiSTer-devel/Arcade-SpaceInvaders_MiSTer) | `db34f40586a572e30a2ada96fa683a7441a02866` | Proven MiSTer 8080 bus/video integration pattern; T8080se fallback; shift/pause/RAM examples. Not the Nintendo board |
| [MiSTer Donkey Kong](https://github.com/MiSTer-devel/Arcade-DonkeyKong_MiSTer) | `737a576b0b5510a71f0aea68a3d5b5560ed5d468` | T48 integration and GPLv3 discrete RC/mixer building blocks. Its `I8035IP` wrapper explicitly says noncommercial freeware: **reject that wrapper for open-source integration** |
| [MiSTer Interact](https://github.com/MiSTer-devel/Interact_MiSTer) | `34658145881d19e0bd25d0434629f89e9656c45f` | Preferred Verilog `vm80a_core`, a reverse-engineered 8080 core. CPU file states CC-BY-3.0; preserve that attribution independently of the repository's GPL-2.0 license |
| [T48 upstream](https://github.com/devsaurus/t48) | `837bd24f8a93275e0233c679b4f00e344bb4e912` | MCS-48 kernel, integration manual, benches. BSD-style notices in kernel files; retain COPYING and per-file notices |
| [Jotego JTCORES](https://github.com/jotego/jtcores) | `548b87b32a1b528a16cb41f689accb179e85d1a8` | Sparse staging of JTFRAME T48, clock enables, RAM and sound/filter/mixer utilities. JTFRAME utilities typically GPL-3.0-or-later; T48 files retain their own BSD notices |
| [Hiscores MiSTer](https://github.com/JimmyStones/Hiscores_MiSTer) | `31789f3b6bf61c379117f73adc879e3c9d5873ae` | `hiscore.v`, GPLv3; requires game-specific RAM ranges/signature and pause acknowledgement |
| [openFPGA Space Invaders](https://github.com/obsidian-dot-dev/openFPGA-SpaceInvaders) | `4202655b5b17b7de556a3f5e446e64a8247aae9c` | MIT SystemVerilog 8080/audio alternative/reference. No READY/HOLD/clock-enable input in inspected CPU port list; not a plug-in replacement for all boards |
| [MiSTer CRT Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) | `c682de9f4acc61d8f4c7779efb48149d3baa3a8e` | GPL-3.0-or-later CRT geometry, native-sync approach; choose the standalone adapter to keep `sys/` untouched. V-size is separately experimental |
| [8085-Core](https://github.com/malisaber/8085-Core) | `c001dea1f14565e1c3108b5a0fc7d6327108a6b6` | MIT VHDL 8085 candidate with muxed bus/interrupts; README explicitly says **DAA is a stub**. Useful controller reference; must be completed/qualified before Block Fever |

File-level notices are authoritative. Do not assume a root repository license relicenses all inherited modules. The combined core's license/attribution must cover the selected files; preserve source and synthesis redistribution notices. Neither candidate 8085 nor the restricted DK wrapper is silently promoted to a working donor.

## Component-by-component integration

| PCB component/function | Chosen source / exact staged path | Integration and remaining work |
|---|---|---|
| Intel 8080A; Mitsubishi M58710S equivalent in Othello | Pristine `rtl/vendor/vm80a/vm80a.v` from Interact; generated `rtl/n8080_vm80a_ce.v` | `tools/generate_vm80a_ce.py` checks the pinned donor and adds a common sequential enable to its kernel. `n8080_cpu` uses sustained complementary phase levels and freezes kernel/bus-history state for RAM service. Split data input/output; decode status/SYNC, DBIN, WR, INTE/INTA. Architectural CPU and 75 mid-read pause cases pass; full IRQ-boundary qualification remains open. Othello later uses HOLD/HLDA. Retain CC-BY attribution |
| 8080 fallback | `donors/Arcade-SpaceInvaders_MiSTer/rtl/T80/T8080se.vhd` plus its T80 dependencies | Real MiSTer integration history; qualify 8080 mode flags/T-state timing. VHDL conversion is needed for Verilator if selected |
| Intel 8035 sound CPU, external 2708 ROM and 64-byte internal RAM | `rtl/vendor/t48/` from pinned JTFRAME; upstream `donors/t48/rtl/vhdl/` and benches | Own an open wrapper; external ROM, correct RAM size, active-low IRQ and quasi-bidirectional ports. GHDL-derived Verilog or an equivalent same-kernel build for Verilator; do not use a different simulation-only MCU |
| NEC D8085AC, Block Fever | `donors/8085-Core/src/rtl/`; alternative `donors/8085plus/rtl/cpu.sv` | **Coverage gap requiring implementation/qualification.** Prefer the candidate whose short qualification closes flags, DAA, RIM/SIM, masks and timing with least change. If neither passes, finish a licensed base against the staged MAME i8085 model; no ARM emulation |
| ROM 2708/M58732S/M5L2078S | Verified files under `roms/<set>/`; inferred BRAM ROM/download storage | Correct address decode, fill and read latency; ROM chips are data/memory primitives, not a separate CPU donor |
| 4116 DRAM bitmap/work RAM | Standard dual-port BRAM; template/JTFRAME RAM patterns | Preserve the 16 KiB CPU-visible window and real write/scanout semantics. FPGA does not need analog refresh circuitry, but any CPU-visible arbitration delay must be modeled |
| Sheriff video 74198-family register at I/O 1L; LS174 DRAM read latches at CPU 4F/4G | `rtl/n8080_video_register.sv`, original GPL-3.0-or-later functional SN74198; independent of the CPU port-3 shift buffer | TI original function table (1981 TTL Data Book, 7-338) qualifies 65,536 cases and both end-output streams. Nintendo TWG-1 parts drawings confirm the packages/positions; related Bandido schematic shows P9 RD bus to 1L and QA/QH video selection. Primitive is not yet integrated. Exact fitted `198` suffix and load/shift/DRAM phase remain unqualified; derive gates and visible origin before replacing the current per-pixel selector. See `docs/HARDWARE_VIDEO.md`, `docs/evidence/sheriff_video_primary_sources.json` and `docs/evidence/sheriff_video_register.json` |
| Sheriff 82S137 1 KiB color PROM | `roms/sheriff/82s137.3l`, hash-verified | PROM lookup plus protection bit/color-mode logic; inferred BRAM or LUT. No tile/sprite ASIC on Sheriff |
| Shift registers, counters, flip-flops, address decode, input buffers | Space Invaders 8080 examples plus small original synchronous RTL | Reuse equations/state structure; implement Nintendo port addresses/polarity. TTL identity alone does not make another board's wiring applicable |
| 74123 retriggerable monostables | Staged MAME `n8080_a.cpp`; RTL counter/envelope primitives | Original board-specific RTL for trigger edges, retrigger/stop, duration and control-pin output; two for Sheriff |
| SN76477 sound generator | MAME device model, board parameter values; `rtl/vendor/discrete/` and `donors/jtcores/modules/jtframe/hdl/sound/` | **No complete qualified generic drop-in donor located.** Compose VCO/SLF/noise/filter/envelope/mixer RTL. Reuse primitives; avoid substituting the fixed Space Invaders sound graph |
| 74275 latches, 7405 open-collector inversion | Staged sound-board model and own latches/combinational gates | Preserve pin permutation, active level and persistent interrupt semantics. Digital open-collector interaction becomes wired-AND logic where relevant |
| Sheriff one-bit DAC, resistors/capacitors and external amplifier | T48 P2 bit 7, GPLv3 RC/mixer primitives; JTFRAME DC removal/mixer | Event-driven DAC into filtered PCM, gain and saturating mix. External amplifier behavior is modeled only to the degree it affects audio; do not invent “chip cores” for passive parts |
| PLL/reset/enables | Template `rtl/pll*`, JTFRAME enable helpers | Legal 50.4 MHz Sheriff PLL, deterministic reset, clock enables; no unnecessary board clock domains |
| HPS/DDR/HDMI/native video/audio | Root `sys/` from template | Reuse platform APIs untouched; board adapter owns loading, video format and audio |
| Rotation/scaling/crop | `sys/arcade_video.v`, `sys/video_freak.sv`, template screen-rotation module | ROT270 portrait, 3:4 aspect; preserve native analog timing; platform DDR is allowed here |
| CRT geometry | `rtl/vendor/crt_adjust/` | Standalone CRT path; parameters only shown when enabled; native sync retained |
| Pause/high scores | Staged pause examples, `rtl/vendor/hiscore/hiscore.v` | Coordinate CPU/RAM borrow; qualify game-specific signatures; no high-score support claim without working restore |

## Search coverage and rejected approaches

Inspected MiSTer-devel's 8080 and MCS-48 integrations, JTCORES/JTFRAME source tree, T48 upstream, openFPGA Space Invaders, Github SN76477 and 8085 HDL candidates, rmonic79 CRT source, and Gehstock's complete MiST source tree (saved in `docs/evidence/gehstock_tree.json`). No full Nintendo TSF/Sheriff core was found in that tree or the Sheriff/Nintendo-8080 repository searches.

Patreon/announcement searches did not establish a downloadable, appropriately licensed, complete Nintendo 8080 core or general SN76477 implementation. A public binary, Patreon listing, or a claim that a core exists is not reusable open-source RTL. No private access/payment bypass was attempted.

Rejected as plug-ins: Space Invaders memory/IRQ maps (different board), its game-specific sound graph, Interact's promised rather than implemented SN76477 roadmap item, DK's noncommercial wrapper, 8085 projects explicitly supporting only a handful of instructions, and unfinished/stubbed 8085 candidates without qualification. Do not use JT89/SN76489, AY/YM, a Z80 in normal mode, or pre-recorded game samples as an SN76477/8080 replacement.

The map describes Sheriff implementation sources, not a verified reconstruction of every physical package/passive component. Remaining work is Sheriff bus/IRQ/video/input and connected sound integration. Reuse qualified components; new donor hunting must close a concrete Sheriff gap.
# Sheriff sound implementation update (2026-10-09)

The BSD T48 kernel now integrates through original `rtl/n8080_mcs48.sv` into `rtl/n8080_board.sv`: real 1 KiB sound ROM, 64-byte internal RAM, 6 MHz crystal enables, persistent level IRQ, quasi-bidirectional P1 and P2 bit 7 DAC. The noncommercial DK wrapper remains excluded.

Frontend adaptations preserve pristine upstream files: `rtl/n8080_video_mixer.sv` moves template RGB nets to module scope to eliminate undriven implicit wires; `rtl/n8080_crt_adjust.sv` carries VBlank with the RGB read bank instead of the donor's two-HSync delay. Original headers/licenses remain in both files; `sys/` and `rtl/vendor/crt_adjust/` are unchanged. Actual platform rotation has component-level qualification in `sim/rotation_qualification.cpp`; final HPS/hardware integration remains pending.

Hiscore local adaptation (2026-10-10): `rtl/vendor/hiscore/hiscore.v` initializes `pause_cpu` to zero. An idle score service otherwise never clears a permitted power-up one, which stops the real 8080 phase clock through the wrapper pause path. The one-bit change preserves upstream notices and active restore/extract behavior. Original-versus-fixed real-CPU power-up tests and the modified donor's production descriptor restore/autosave/upload regression pass; `tools/record_hiscore_powerup.py` binds their receipts in `docs/evidence/sheriff_hiscore_powerup.json`. This does not establish resolution of the original full-wrapper hostile boot failure or current timing/resource qualification.

`rtl/sheriff_sn76477.sv` is original synthesizable fixed point RTL derived from the MAME 0.289 measured SN76477 capacitor equations and gain table, with Sheriff-specific component values. `tools/generate_sheriff_sn.py` generates Q32 constants and gain ROM; provenance/license is `docs/licenses/MAME-BSD-3-Clause.txt`. The 74123 monostable counters live in the 8035 wrapper. This analog model is qualified against an independent floating-point component corpus; integrated gameplay waveform timing and physical PCB calibration remain pending.
## Integrated sound qualification update (2026-10-09)

The real 8035 ROM prefix now matches 1244 MAME connected output-latch events. P2 low bits during external-ROM fetch are the physical address bus; compare its upper output latch and P1, not the raw whole P2 value. The board's downstream one-bit DAC mixer was corrected to 0/+4915, as required by MAME's one-bit 0..1 range and 0.15 route. All twelve real-ROM settled DAC intervals match exactly; no clipped samples occur in the 1100-frame capture. CPU/I/O/sound-port prefixes and 22 shared native images are preserved. Full integrated analog/event coverage and final source timing remain pending; the standalone SN76477 qualification is not promoted to a whole-board sound pass. Evidence: `docs/evidence/sheriff_integrated_dac.json`.

Rotation DDR adapter: rtl/n8080_rotation.sv retains pristine sys/arcade_video.v screen_rotate mapping and framebuffer ownership, with a 512-word synchronous write queue for DDR backpressure. Native/short-stall/81 us burst/hostile-seed component cases are qualified in docs/evidence/sheriff_rotation_backpressure.json. This is an adaptation around the GPL-2.0-or-later template donor; new memory/control fit and STA await the user lifting the Quartus hold.

Host-side HQ oracle: grom358/hqx at a1c7d415f4bb7b947c4c2e47faf220b0148f4bac, staged locally in donors/hqx-reference, LGPL-2.1-or-later with original COPYING and notices retained. Only hq2x.c/init.c are linked into the verification executable; no library code is included in FPGA RTL. sim/hq2x_reference.c supplies the measured platform border and uses the independent algorithm. Checker-pattern proof: docs/evidence/sheriff_frontend_nonuniform.json.

## 2026-10-09 CPU clock integration update

The vm80a CPU adapter now receives non-overlapping level enables derived from the related Bandido 2A/3A/3B/5A network, replacing complementary gates. No vendor core or sys/ edit is involved. See docs/evidence/sheriff_clock_network.json for pin/source provenance and quantization, and docs/evidence/sheriff_cpu_phase_qualification.json for focused actual results. Exact Sheriff net/absolute phase/electrical/READY identity is pending; older saved-source IRQ/full-wrapper qualifications do not automatically cover this waveform. Quartus qualification remains pending under the user hold.

The standalone SN74198 primitive now has a connected conditional gate map in docs/evidence/sheriff_video_control_network.json (5T/5B/1K/2K and CPU 3D READY clock observations). This remains a reference derivation outside production RTL and files.qip until DRAM latch/address timing, blanking/origin and Sheriff net applicability are established. No new donor wrapper or sys/ modification is needed for the basic TTL gates.

The readback control derivation is in `docs/evidence/sheriff_ram_handshake.json`. Use original small RTL for the LS174 flags/XOR connections after the complete RAM schedule is known: Q2 -> D1 feedback, D2=1, CLK=HREAD_n XOR Q2, RDY IN=Q1. This corrects the earlier HREAD_n-to-D1 observation; related-board applicability and physical timing remain conditional. No additional CPU donor or unqualified generic wait controller is needed for these two flags.

RAM arbitration must preserve the physical LS153 column map in `docs/evidence/sheriff_memory_mux_connections.json`. CPU access covers 16 KiB; the physical video H/V inputs select 8 KiB. LS08 RD gates are buffers with a common R4 pull-up; do not add invented read blanking. Implement the observed LS02/LS32 control equations after upstream strobe/write phase is derived.

Original GPL3 discrete-logic implementations staged in RTL: n8080_memory_phases (conditional2A/3B/4I/4A,16,000 sampled tests) and n8080_ram_readback (conditional4F/4G/4T/READY3D,22 explicit function cases). Evidence is sheriff_memory_phases.json / sheriff_ram_readback.json under docs/evidence. Both are outside board/files.qip; electrical phase, DRAM-valid/wait timing and exact Sheriff applicability remain unqualified.
## Connected physical video path added 2026-10-10

Latest joined model: original GPL3 `rtl/n8080_horizontal_counter.sv` models
4J binary reload from4G Qbar and falling-RCO4G toggle with one shared-counter
CE. The serializer now interprets HB/VB as the actual high-blank test-point
outputs;5T receives their complements. Connected native phase/counter/video
qualification covers320-clock periods (256 active/64 blank),1280 counter
pixels and128 byte loads in both directions, build/test exit0. Evidence
`docs/evidence/sheriff_horizontal_network.json` and
`sheriff_horizontal_video_path.json`. Reset is artificial; gate/C5 delays,
vertical enable, actual flip mapping, visible/PROM timing and exact Sheriff
revision remain pending. Blocks remain outside board/files.qip. The older
512-byte stream receipt describes its pre-polarity-correction source only;
use the joined current receipt for the corrected component, without claiming
production integration or a physical graphics/resource pass.

`rtl/n8080_video_path.sv` is original GPL-3.0-or-later board RTL connecting the
already qualified `n8080_video_register.sv` to the related-Bandido 5T/5B load
and1K mode gates, RD7..RD0 parallel pin reversal and NAND end selection.
Inputs are the shared-counter clock enable, pre-edge4I levels, HB/VB, NOR/REV,
clear and serial pins, and the actual RD bus. It owns no separate clock or
invented pixel origin. It remains outside board/files.qip until RAM, raster
origin/blanking and flip mapping are derived. Actual native component build
and test exit0,512 loaded bytes,4096 output bits,4096 post-edge RD retention
checks and four blanked boundaries: `docs/evidence/sheriff_video_path.json`.
Connected DRAM cycle/clock provenance: `docs/evidence/sheriff_dram_cycle_edges.json`.
This qualifies the stated connected functional model, not exact Sheriff
electrical timing or full graphics; production integration and queued timing
checks remain required.

### Vertical counter integration hold (2026-10-10)

Related Nintendo Space Fever Color original TSF-I/O schematic is now staged as an independent family reference, not another game profile or donor implementation. Source/provenance, viewports and rejected naive extension are recorded in `docs/evidence/sheriff_vertical_network.json`. The counter/address wiring includes QA as V0; a naive sampled-carry extension of the existing horizontal component gives 128 rather than 256 lines. Keep `n8080_horizontal_counter.sv` and physical serializer primitives outside board integration until this event interpretation and the Sheriff flip/blanking/reset network are resolved.

### SN76477 mixed gameplay coverage (2026-10-10)

The actual cocktail output-write capture contains mono0 cancellation and mono1 overlap; longer MAME output/WAV captures also contain mono1 retriggers. Coverage and completed native diagnostic are in `docs/evidence/sheriff_sound_control_coverage.json` and `sheriff_sn_mixed_gameplay.json`. Reused the existing dual-gain SN executable and production 74123 equations, preserving the original board audio as the old-gain identity oracle. All 1,439,875 samples are byte identical, but missing OS exit observation keeps job qualification false; MAME mixed-class waveform equivalence remains pending. Current production donor/RTL integration is unchanged.

### SN mixed-class source equations and enable network (2026-10-10)

`diagnose_sn_mixed_waveform.py` extends the qualified mono1 source equations to SLF-controlled VCO, VCO/noise mixer selection, overlap, cancellation and retrigger timers. Generalized Q32 state/output shadow matches the saved native mixed prefix exactly. The independent MAME-order floating SN plus qualified DAC resampler matches the entire saved 12,482,881-sample WAV under a uniform lower timestamp bound at 1,113 ambiguous DAC source-grid edges. The original nominal-timestamp and atomic-control negatives remain recorded. The oracle is a diagnostic only; it does not replace synthesizable chip/gameplay logic.

Exidy Bandido audio pages37/38, including the dual74123 clear wiring and diode-combined SN enable, are staged and hashed in `sheriff_sound_enable_network.json`. Source MAME sequential setters cause 26 additional envelope restarts; actual Sheriff polarity and propagation must establish whether/how to represent this in RTL. No production donor/RTL integration changed, and neither exact physical sound timing nor whole-audio qualification is claimed.

### Main gameplay source projection reuse (2026-10-10)

Current main board specializes exactly to the captured cb67879 source when the user flip input is off; CPU wrapper and VM80A hashes are unchanged. `sheriff_gameplay_source_bridge.json` binds this limited equivalence to the real completed replay, and `sheriff_gameplay_lifecycle.json` records score/death/game-over/restart HUD evidence plus117 exact control-RAM matches. No donor/production RTL changed. This reuse excludes changed audio, current whole-wrapper execution and physical raster qualification; all nonmatching whole-RAM checkpoints and the field2760 pixel remain explicit.

### Native8080 earliest boundary evidence (2026-10-10)
The unchanged CPU wrapper/kernel in the retained real-board model independently confirms the field66 ANA/JNZ/RST bus sequence. sheriff_first_irq_boundary.json retains actual native/MAME exits and all first82 equal-return-PC epochs; the two-T-state pre-boundary phase difference remains a CPU/video/reset-origin question. No donor opcode/flag patch is justified. This diagnostic retains old SN conversion constants and does not qualify current integrated audio or physical reset/raster timing.

## Reused CPU reset qualification (2026-10-10)

The existing VM80A/adapter reset audit matches78 pre-opcode pin samples and uniquely identifies release phase7 for the saved CPU/harness. Native T1 is a bus-derived observation tag, not phase0 or physical phi1. The updated field66 analyzer binds unchanged CPU/kernel hashes and proves the entire harness byte-identical to the audit after removing only the later flip_screen=0/debug_addr=0 input initializers. It derives final phi2 offset12; measured ACK/stack events are unchanged. No donor or production-clock modification is justified by the MAME time0/native tag50 difference. Physical Sheriff reset/raster origin and memory service remain unqualified. See docs/CPU_PHASE_ORIGIN.md and docs/FIRST_IRQ_BOUNDARY.md.

## Current-board SN gain integration (2026-10-10)

The corrected38-word SN gain table now has real current synthesizable-board/8080/8035 evidence through1201 fields:937008 samples predicted exactly from the qualified component replay and unchanged DAC;25485 changed samples. Digital journals and50 selected RGB/RAM snapshots remain byte-identical. Actual native/workflow exits0 and current/snapshot source, model/runner and artifact hashes verify. This qualifies the gain correction in the bare-board mono1 scenario; full-wrapper/mixed-control/physical analog sound and release qualification remain separate. See docs/evidence/sheriff_current_gain_integration.json.

## Related vertical counter primitive — source correction2026-10-10

`rtl/n8080_vertical_counter.sv` implements5I/5J enable/cascade and the VB latch from connected Bandido/TSF source, using one master clock plus CE. Independent ENP7=HB_n qualifies both stages; CLK2 is CK/4, ENT cascades the carries. The focused native model passes256 rows/224 active and rejects the blank-end carry. Primary sources/provenance and actual native exits are in `docs/evidence/sheriff_vertical_network.json` and `sheriff_vertical_counter_native.json`. This is our GPL-3.0-or-later primitive, not a fetched donor. It remains outside `files.qip`; production origin/DRAM/serializer/IRQ applicability and fit/resources are pending.

### Own 3K LS175 model and horizontal CE connection

`rtl/n8080_color_latch.sv` (GPL-3.0-or-later) stores D1..D4 with Q/Qbar outputs on a supplied master-clock CE. Related-Bandido 3K CLK9 is sourced from4J QD11; the joined harness derives the7->8 capture event from the existing horizontal counter. Native qualification/source limits are in `docs/evidence/sheriff_color_latch_native.json` and `sheriff_prom_clock.json`. It is outside files.qip; integration still requires PROM/LS158/PNP polarity and real capture/reset timing. No generated game clock is introduced.

## Source-qualified physical control components (2026-10-10)

`rtl/n8080_dram_control.sv` implements settled related-board mux/CAS/RAS/WE/STSTB/RAMSTB equations with explicit unresolved CPU_WR_RD input. Its native pin/address qualifier passes; it is outside production files.qip and does not supply4116 data or physical access timing. Reuse `n8080_memory_phases`, `n8080_ram_readback` and the qualified READY service when the missing arbitration/data ordering is resolved.

`docs/PROM_DUMP_PIN_BRIDGE.md` joins the Signetics82S137 pin convention, pinned open-reader bit/address ordering and Bandido PIO connections. PROM integer address is `{V7..V3,H4..H0}` after PIO XOR wiring, with O1..O4 corresponding to data bits0..3. This is source convention evidence; historical Sheriff programmer provenance and physical latch timing remain open. The prior4J-QD color-clock donor wiring is under review and must not be integrated. Preserve its native assumed-clock proof.

Corrected color-clock mapping: the source-qualified3K clock is HREAD_n=!4I QD, with ce_capture=ce_counter&&(phase_4i==15). `n8080_color_latch` function/interface is unchanged; its obsolete4J comment is corrected. New immutable native composition uses existing counters, video_path/register, color_path/latch and private parent PROM. Historical4J-QD clock qualification is withdrawn and archived; settled pre-edge sampling and visible-pixel equivalence remain unresolved.

`rtl/n8080_dram_storage.sv` is the local conditional4116 functional storage component: single synchronous16KiBx8 port, explicitRAS/CAS/WE/address/DI, early/latewrites and heldDO/readvalid. Native177checks pass with existingDRAMcontrol/frozenpin fixture. It is outsideproductionQIP; sourceunknownCPU_WR_RD and readback/READY coupling remain separate inputs, physicalAC/refresh is unqualified and actualM10K inference is pending isolated synthesis. Original failedharness context and successfulimmutablev2 snapshots are retained.

Storage device inference nowmeasured: isolatedmap0 infers16M10K/131072bits,34registers,33estimatedALMs and0DSP. Physicalaltsyncram isDUAL_PORT, although localRTLserializes oneaddress/read/write; retain mixed-portOLD_DATA and registeredaddress/unregisteredoutput semantics. No separate physicalSINGLE_PORT requirement. Fullframework timing/resources remain qualified only by their exact integrated-source reports.

Conditional actual-storage service is now qualified by `docs/CPU_DRAM_SERVICE.md`: existing vm80a READY adapter→memory phase/control→4116 storage→readback→CPU READY completes all five synthetic origins. No new donor, production QIP wiring or source phase change. Explicit CPU_WR_RD=1 and fixed physicalH/V prevent a production arbitration claim; preserve these inputs until the generator/net is resolved. Reuse existing M10K inference and joined run.

Production RAM integration is specified in `docs/DRAM_INTEGRATION_REQUIREMENTS.md`. Existing local components require a pause-safe memory-phase input, dynamic video service and timed hiscore/debug bridge; the current simultaneous read owners cannot be substituted by a free extra physical BRAM port. CPU_WR_RD remains the next missing source input. No donor/board/QIP change follows from the read-only assessment.
