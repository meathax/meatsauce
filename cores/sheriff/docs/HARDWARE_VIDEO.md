# Sheriff physical bitmap path

## Current color-clock source review (2026-10-10)

Do not integrate the historical once-per-line4J QD claim. Parent PROM aggregate statistics (`docs/evidence/sheriff_prom_spatial_scope.json`) show28 of32 tile rows vary in RGB and up to6 colors in a row. A static held-color mode clocked once per line cannot reproduce that structure. The independent joined-page audit identifies inverted4I QD/HREAD_n as the3K CLK9 source; retain its exact source proof and qualify only the changed clock/hold ordering before production integration. Earlier latch tests remain evidence for their assumed input clock, not proof of the physical route. These statistics do not establish a MAME bug, exact Sheriff revision or electrical propagation.

## Horizontal reload and blanking polarity (2026-10-10)

Close connected viewports distinguish test-point names from active gate
inputs: TP4 HB is4G Q5, while5T pin1 receives complementary Qbar6. TP5 VB is
Q9, while5T pin2 receives Qbar8. Both test-point signals are high during
blanking. The corrected load predicate is `~HB & ~VB & QA & QB & QC`.
Earlier active-input HB/VB labels were ambiguous; preserved source/receipts
retain their historical scope. `n8080_video_path.sv` now takes the actual
test-point polarities. The corrected exhaustive gate table is in
`docs/evidence/sheriff_video_control_network.json`; its previous table is
retained under `_checks/horizontal-video-path-20261010/`.

4J RCO15 comes from its high nibble and4I carry. Three4H inverters/C5 drive
4J LOAD_n9 and4G CLK3;4J A/B are zero, C/D take4G Qbar6, and4G D2 takes its
own Qbar. In the stated zero-delay ordering, the counter loads old Qbar as
preset0/12, then falling RCO clocks4G. This gives256 active counter clocks
and64 blank clocks per320-clock period. Manufacturer load/enable/carry
semantics are supported by [TI's SN74LS161A documentation](https://www.ti.com/product/SN74LS161A);
exact fitted family and RCO/gate/RC electrical behavior remain open.

Original GPL3 `rtl/n8080_horizontal_counter.sv` connects that network to the
existing phase and corrected serializer blocks. Native joined build/test
exit0 covers1280 counter pixels,128 loaded bytes,5120 RD-retention
observations and both directions. The first byte appears eight shared
counter clocks after the active transition, directly from pre7 loading and
the fetch pipeline; this does not establish the analog visible window or
authorize a fitted coordinate/reference offset. Evidence:
`docs/evidence/sheriff_horizontal_video_path.json` and
`docs/evidence/sheriff_horizontal_network.json`. Recovery:
`_checks/horizontal-video-path-20261010/attempt-v2/`.

The first native case exited1 due to my bench's completed-bit check expecting
index8 instead of final bit7. Failed source/ELF/receipts are retained; the
correction rebuilt only C++ against the unchanged generated RTL model.
The joined blocks remain outside production board/files.qip. Next trace
vertical counter enable, the actual flip latch and PROM/RGB visible gating,
then integrate complete DRAM/readback/READY/held-byte scanout. Do not repeat
the completed component case or waive field2760.

## Connected fetch/load checkpoint (2026-10-10)

`docs/evidence/sheriff_dram_cycle_edges.json` connects the already qualified
counter/delay network to the RAM mux and DRAM strobes. The two settled periods
agree: video RAS selects C2, CAS selects C3 eight crystal periods later, and
the pre7 common-counter load edge follows CAS by four periods (198.412698 ns).
No visible-coordinate or reference offset is chosen. New original-page
viewports trace 3B Q10 through 4I/4J/5I/5J CLK2 to serializer 1L CLK11 across
the adjoining sheets. Exact Sheriff revision, visible origin and electrical
delay qualification remain separate from related-Bandido connectivity.

When CPU WR RD is low, the strobe disable gate releases CAS at that same
ideal load transition. Model the pre-edge DRAM byte; do not silently order
simultaneous gate changes as a post-release read. TI's primary
[1982 MOS Memory Data Book](https://bitsavers.org/components/ti/_dataBooks/1982_LCC7061_TI_MOS_Memory_Data_Book.pdf),
TMS4116NL pages26/30/31, gives CAS-relative maximum access100/135/165 ns for
grades15/20/25. Those figures alone do not prove PCB setup/hold: gate and
register delays, fitted RAM grade and the output-disable minimum matter.
The derived RAS-to-CAS delay397 ns exceeds the conditional maxima used to
guarantee RAS-relative access; use the CAS-relative bound. The online primary
table was inspected; the local download returned HTTP403, so no local PDF
hash is claimed.

Implemented `rtl/n8080_video_path.sv` as the connected 5T/5B load predicate,
1K mode gates, A=RD7..H=RD0 pin order, qualified 198 register and NAND end
selection. It takes pre-edge4I and common-clock enables from its caller and
adds no independent clock or guessed byte offset. Actual native Verilator
build/test exit0:512 byte loads,4096 stream pixels in both complementary
directions,4096 post-edge RD changes preserving held-byte output and four
blanked boundaries. `docs/evidence/sheriff_video_path.json` binds source,
ELF/log hashes and both exit receipts; recovery `_checks/video-path-20261010/`.
This connects the functional primitives; it is outside the production board
and files.qip, and does not pass physical DRAM, MAME graphics or release gates.

Next derive horizontal reload/blanking, visible origin and actual NOR/REV
flip-latch mapping from the joined drawings. Then connect the DRAM address,
readback/READY and byte serializer together, retaining pre-edge capture and
the electrical limits. Reuse the completed native component case; keep
field2760's mismatch and the original comparator as negative evidence until
the complete supported path is integrated and compared.

The current board RTL reads bitmap RAM continuously and selects one bit at each pixel. The timed MAME-write comparator models that same functional scanout. Primary hardware drawings now establish a separate video shift register, so neither implementation nor comparator yet qualifies the physical byte-fetch boundary.

## Primary sources inspected

| Source | Exact evidence | Local recovery |
|---|---|---|
| [Nintendo Sheriff TWG-1 operation manual](https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Sheriff.pdf), 8 PDF pages | Page 6: TWG-CPU PI-500861 parts locations, 4116 RAM, LS174 at 4F/4G and LS153 multiplexers. Page 7: TWG-I/O PI-500932, `198` at 1L, raster counters and PROMs. | `_checks/manuals/sheriff-twg1.pdf`; page PNGs `sheriff-page-06.png`, `sheriff-page-07.png`; readable rotated page `sheriff-io-readable.png` |
| [Exidy Bandido operator's manual](https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Bandido.pdf), January 1980, 40 PDF pages | Pages 33–34: I/O schematic 77-3367-11. Page 34 shows P9 RD7..RD0 parallel inputs into `198` at 1L, mode/clock connections, QA/QH selection through 11K NANDs and the video output. Pages 35–36: CPU schematic 77-3366-11, 4116 DRAM, read latches 4F/4G, address mux and READY circuitry. | `_checks/manuals/bandido-1980.pdf`; original 5088x6600 page PNGs `bandido-page-33.png` through `bandido-page-36.png`; cropped `bandido-ls198-detail.png` and `bandido-mode-detail.png` |
| [Texas Instruments TTL Data Book, second edition, 1981](https://bitsavers.org/components/ti/_dataBooks/1981_TI_The_TTL_Data_Book_For_Design_Engineers_2ed.pdf) | PDF page 13 indexes SN74198 at printed 7-338, PDF page 595. The original description/table defines clear, hold, parallel load and both serial directions, sampled on rising clock edges; mode controls change while clock is high. | `_checks/manuals/ti-ttl-databook-1981.pdf`; inspected text `_checks/manuals/ti-74198-plain.txt`. PDF bitmap extraction needs missing jbig2dec; this qualification uses the manufacturer's text/table. |

These are original manual scans, retained locally with their copyright. PDF hashes and reviewed observations are in `docs/evidence/sheriff_video_primary_sources.json`. Crops/rotation are document viewports, not redrawn circuits. PDF page numbers above are one-based and differ from printed manual numbering.

**KNOWN:** Sheriff's own parts drawing places a `198` at 1L. The related Bandido circuit feeds that package from the parallel DRAM read bus and uses its end outputs for video. The scan labels it `198`; a `74LS198` suffix has not been established. The serial video path is separate from the CPU's software-accessible shift latch.

**INFERRED:** Matching CPU/I/O package positions support applying the related Bandido byte-serialization topology to Sheriff. They do not prove every resistor, gate connection or board revision is identical. Preserve that distinction until the connected waveform is reconstructed or measured.

## Observed corner and pending derivation

At restart frame 6780, x95/y31, the current RAM sample is tick 5,553,508,158. RTL writes byte 0x43eb 39 master clocks before that sample; MAME writes the same value about 167 clocks after it. Pixel x95 is bit 7 of the byte beginning at x88. Its hypothetical first-pixel sample is 70 clocks earlier, placing the RTL write **within** the eight-pixel interval. A held byte could therefore change this corner's result. That is a falsifiable hypothesis, not a derived load edge or a qualified fix. Frame 2760's differing write occurs before its corresponding eight-pixel interval; the same hypothesis cannot automatically explain both pixels.

The frame-6780 IRQ also differs: native stacks PC 0x0a03 before `LXI H,immediate` (three bytes, ten T states), while MAME stacks 0x0a06 after it. The existing bus replay starts its vblank windows at the target edge and misses the preceding opcode fetches. Its post-IRQ trace remains usable, but independent pre-IRQ qualification needs corrected leading windows: SHERIFF_BUS_FRAMES=2758,6778 uses completed-field indices and includes both sides of the frame-2760/6780 edges. Combine that observation with the next necessary corrected-board replay; no clock shift or reference exception follows from the pixel symptom alone. See `docs/evidence/sheriff_pixel_6780_boundary.json`.

The next implementation work must:

1. Trace 1L CK and S0/S1 through the horizontal counters and load/direction gates on both I/O sheets. Establish parallel-load and shift modes from the exact 74198-family device documentation, including the scan's pin labels.
2. Trace the CPU-board DRAM read latch, HREAD, COMADR, RAS/CAS and READY path. Derive the address held at load, the visible raster origin, and any CPU-visible arbitration. Do not infer READY permanently high from the current RTL baseline.
3. Express the supported phases with the existing board master clock and enables. Document any phase quantization or remaining physical assumption; a clock change requires fresh timing checks once Quartus is authorized again.
4. Implement the smallest independent video register and load/shift enables. Keep the CPU shift buffer and RAM-service port separate. Cover normal/flip, row/byte boundaries and one write on each side of the derived load edge. Retain the old selector as a negative test baseline.
5. Update the independent scanout oracle from the same primary derivation, then rerun only affected short cases before the required real-ROM scenarios. Do not choose a load offset because it makes MAME pixels pass.

## Standalone register and first third-round pixel

`rtl/n8080_video_register.sv` implements the SN74198 function table with a single master clock and a rising-chip-clock enable. Its eight-bit state maps bit 0 to QA/input A and bit 7 to QH/input H. Clear is overriding and asynchronous. It does not initialize state independently of clear/load. The caller owns the chip clock and mode waveform; no physical load phase is guessed inside the primitive.

Actual Verilator qualification checks all 256 prior states across the four modes, both serial inputs, four parallel patterns, both clock-enable levels and both clear levels: 65,536 cases. It also checks low/falling-edge hold and immediate clear, plus both eight-bit end-output streams for the related schematic's A=RD7..H=RD0 wiring. The oracle maps each flip-flop from TI's table independently. Actual executable stdout/exit receipt and hashes are in `docs/evidence/sheriff_video_register.json`. The primitive remains outside the production board and `files.qip` until connected timing is established; electrical delays are not qualified by these functional checks.

The first third-round native difference is frame 2400 x33/y33, bit 1 of RAM 0x4424. The focused MAME capture reproduces the original static-input I/O and RAM-write files as exact byte prefixes. It clears the byte with MOV M,A at 0x12c3 about 88 clocks before the current pixel sample; RTL clears it 156 clocks after. Loading once at the proposed first-pixel sample (ten clocks before this pixel) would still yield different held bytes. This falsifies that specific first-pixel-load explanation for the corner; it does not establish the real load phase.

The preceding vblank saves MAME PC 0x0891 and native PC 0x0894, straddling a three-byte, ten-T-state JNZ. Native stack edges are +419/+494 clocks, while MAME writes both bytes at about +250. The instruction-boundary cause is still unqualified because the actual native pre-IRQ fetches were not captured. Use completed-field window 2398 alongside 2758/6778 in the next necessary native replay. Preserve the normal frozen controls and all mismatches. Evidence: `docs/evidence/sheriff_rounds_pixel_2400_boundary.json`.

Production board scanout is unchanged. No physical-byte qualification, new timing pass or MAME mismatch waiver is claimed. Quartus remains on hold.

## CPU clock network

The related Bandido I/O schematic, PDF page 33, connects decade counter 2A, shift register 3A, positive-edge flip-flop 3B and NAND clock driver 5A. `tools/derive_sheriff_clocks.py` reconstructs their Boolean network using the original drawing and manufacturer truth tables. The report `docs/evidence/sheriff_clock_network.json` records exact pins, source hashes, all ten crystal intervals, all 25 board-clock samples and remaining assumptions. Its 5,120 initial-state cases converge to non-overlapping clock levels: phi1 is high in crystal intervals 0–1, phi2 in 3–7. The preceding 48%/52% complementary enables did not express this network.

`rtl/n8080_cpu.sv` now uses phi1 for master phases 0–4 and phi2 for phases 8–19. At 50.4 MHz the ideal phi2 rising edge lies at phase 7.5; this sampling rounds it 9.920635 ns late. The CPU frequency, PLL, raster origin and IRQ edges are unchanged. This is a conditional related-board derivation: exact Sheriff net identity, CPU-to-pixel initial phase, electrical delays and READY/DRAM arbitration remain open. It does not establish the physical video load edge or the cause of the long-gameplay pixel differences.

The architectural check and 486 documented-opcode cadence cases pass with these enables. The 75 memory-service/pause cases also pass. A fresh 106-field real-ROM run exits zero; its six captured fields match the existing timed MAME-write scanout model with zero differing pixels. This short result does not qualify uncaptured gameplay or the physical serializer. Older IRQ and full-wrapper reports retain their original-source scope; interrupt boundaries changed and require fresh analysis. Actual logs and receipt are in `_checks/physical-cpu-phases-20261009/`; no Quartus check has run.

## Connected serializer controls and READY observations

The page-34 mode gates can now be traced separately from the DRAM sampling question. 5T is a four-input NAND and 5B is an OR; the four 1K packages symbols are NAND gates, including those drawn as OR shapes with inverted inputs. Their ideal common load signal is `load_n = ~(HB & VB & 4I_QA & 4I_QB) | ~4I_QC`. Thus parallel load requires both blanking signals and all three low counter outputs high. This is a pre-edge counter predicate, not a derived visible x-coordinate or RAM sample tick. `1K` output 3 drives 1L S0 pin 24 and output 6 drives S1 pin 1. With complementary NOR/REV flags, normal shifting uses S1:S0=10 toward QA; reverse uses 01 toward QH. The end-output NAND network selects QA under NOR and QH under REV. The existing A=RD7..H=RD0 component stream checks remain applicable.

`tools/derive_sheriff_video_controls.py` records 64 conditional mode rows, eight end-selection rows, source/pin provenance and exact original-page viewports in `docs/evidence/sheriff_video_control_network.json`. These are zero-delay gate derivations, not a physical board or simulation release pass. C6 220 pF is drawn on the mode signal. HB/VB polarity, counter reset, visible origin, clock-to-counter order, DRAM address/latch timing and propagation delays still prevent choosing a production load edge.

The CPU page-35 READY circuit uses the second half of LS74 at 3D: D pin 12 receives inverted phi1 TTL through 4D; CLK pin 11 receives CP2 pin 23 phi3 TTL; PRE_n pin 10 receives RDY IN; Qbar pin 8 feeds CPU READY pin 23. Page 33 traces phi1 TTL to 3A QB and phi3 TTL to 3A QE through XOR buffers with their other inputs grounded. These are separate from the MOS clock-driver outputs. In the ideal settled network, QE rises at decade count 5 while inverted QB is low. If both asynchronous controls stay high this samples READY high, but RDY IN can independently force READY low. The manufacturer table also identifies the unstable both-controls-low case; Qbar must not simply be computed as inverse Q there. C34/C35 120 pF appear on D/CLK.

The [TI LS74-family function table](https://www.ti.com/lit/ds/symlink/sn74ls74a.pdf), PDF page 1, and [TI LS00-family pin table](https://www.ti.com/lit/ds/symlink/sn74ls00.pdf), PDF page 3, were downloaded and visually reviewed. Exact hashes and local recovery are in the control-network report. The separate RAMSTB/RDY IN read-latch and DRAM transaction waveforms still need connected reconstruction; the current `.pin_ready(1)` is not thereby qualified as a hardware timing model. No production serializer or READY logic was changed in this step.

## CPU readback and the parallel video bus

CPU sheets 35/36 establish distinct paths: 4116 DO signals pass through 4E/4H AND gates whose shared input is pulled high through R4 1k to +5 V onto CP2 RD0..RD7; those same gated signals feed 4F/4G, whose outputs feed CPU DI10..DI17. The video parallel RD byte is not automatically held by the CPU readback latches. At 4F, D1 pin 3 receives Q2 pin 5 feedback; Q1 pin 2 is RDY IN and D2 pin 4 is tied high. Wider connected viewports corrected the earlier mistaken HREAD_n-to-D1 trace. HREAD_n instead feeds 4T LS86 pin 5 separately from Q2 at pin 4. The request NAND 3F uses STSTB and CPU A14, not the MEMR status output. Its RAMSTB_n output reaches READY 3D CLR_n. Exact pins, original-page recovery and limits are in docs/evidence/sheriff_memory_primary_connections.json.

The conditional latch clock is HREAD_n XOR Q2 (4T output 6); 4T output 3 is Q1 XOR Q2. TI SN74LS174 pinout and function table establish positive-edge capture with asynchronous low clear. On each capture Q1 receives old Q2 and Q2 receives one: after clear the sequence is 00, 01, 11. RDY IN rises on the second capture. `tools/derive_sheriff_ram_handshake.py` checks 16 flag/clear/edge transitions and eight initial-state/HREAD scenarios; provenance, connected viewports and traces are in `docs/evidence/sheriff_ram_handshake.json`. Releasing clear while CLK is high does not create a capture. This event model does not qualify real XOR feedback pulse widths, propagation or RC delays. Connected bottom-net views of CPU sheets 35/36 identify both 4F/4G CLR pin 1 inputs on RAMSTB_n from 3F output 3, shared with READY 3D CLR pin 13. CPU WR RD and RDY IN are separate neighboring cross-sheet nets. The complete CLR waveform and READY response (including overlapping low preset/clear), CAS/RAS/WE, valid RAM byte and address-mux schedule remain open; two captures do not establish a CPU wait-state count. Production board RTL is unchanged.

## First third-round corner after the clock correction

The saved cb67879-source replay passes all 45 captured fields through 2401, including the old first differing pixel at field 2400 x33/y33. Fresh pre-IRQ events identify ANA A at PC 0x0890; current sampled enables and its independent four-T duration predict ACK and both stack writes exactly. Native and MAME both save PC 0x0891. Native now clears the byte 69 clocks before the pixel sample, MAME about 88 before; the old complementary-waveform source cleared it 156 clocks after. See docs/evidence/sheriff_clock_round2400.json. This resolves the saved-model corner while leaving raster/IRQ generation and scanout unchanged; physical byte-load, READY/DRAM timing and concurrent worktree board changes remain unqualified. Preserve the old negative baseline above.

## RAM address selection and data buffering

Connected CPU sheets 35/36 and the TI LS153 function table establish shared selectors A=NOT COMADR_n (pin 14) and B=NOT HREAD_n (pin 2). With both enables grounded, B:A selects C0/C1/C2/C3. These columns, written AR0 first, are:

| Selection | AR0 through AR6 |
| --- | --- |
| C0 | A0, A1, A2, A3, A4, A5, A6 |
| C1 | A7, A8, A9, A10, A11, A12, A13 |
| C2 | H0, H1, H2, H3, H4, V0, V1 |
| C3 | V2, V3, V4, V5, V6, V7, 0 |

Under the C0/C2-row and C1/C3-column convention, CPU indexing retains all 14 bits; video indexing is H[4:0] + 32*V[7:0], selecting the lower 8 KiB. H/V are physical CP3 levels; their relationship to visible x/y, flip and serializer phase remains open. These wiring projections do not establish actual RAS/CAS edge order.

3E LS02 output 13 is HREAD_n AND NOT CPU_WR_RD_level. The 5B LS32 gates OR this disable level into raw CP2 CAS_n and RAS_n. Their negative-input AND-style schematic symbols implement positive OR; do not substitute a NAND. The shared 4116 WE input comes from the first LS153 channel: C0/C2/C3 are high; C1 comes from 3F LS00 output 6. Wider connected views correct the earlier 3B package label to 3F. Its inputs carry buffered A14 and inverted CPU WR_n from 4D LS04 output 4. Therefore the Boolean write predicate is HREAD_n AND NOT COMADR_n AND A14 AND NOT CPU_WR_n. This identifies CPU column-phase write selection; it does not determine the effective DRAM write edge. CPU WR RD generation and raw CP2 signal phase still need reconstruction.

The common 4E/4H input is pulled high through R4; RD therefore buffers DO rather than blanking it by phase. This corrects the earlier unqualified common-control assumption. The DRAM output-valid window remains open. Exact pins, primary source hashes and connected viewports are recorded in `docs/evidence/sheriff_memory_mux_connections.json`, reproduced by `tools/record_sheriff_memory_mux.py`. No production RTL or physical-memory timing pass follows from these connections.

## Restart corner after the clock correction

Field2760 still differs by one pixel in the saved cb67879 model. The local 17-T CALL/IRQ prediction matches actual ACK and stack writes, and native/MAME return PC is now 0x2175. Native writes RAM 0x43ba at sample-149; MAME records the write at sample+6.9966248. The nearby instruction epoch differs by approximately 125 clocks, with an additional 31-clock difference between bus-write and instruction-end placement. These observations do not establish why execution epochs differ or qualify physical RAM arbitration. `docs/evidence/sheriff_clock_restart2760.json` preserves the negative result, source scope and frozen-prefix receipts; no raster/reference adjustment or graphics waiver follows.

Connected I/O page33 views establish raw RAM controls from 4A LS164: CAS_n=NOT QB (pin4 through 4B inverter), RAS_n=QB AND QD (pins4/6 through 4F NAND and 2I inverter), and COMADR_n=NOT QG (pin12 through 4B inverter). The CPU-board inverter therefore makes the mux A selector equal 4A QG. HREAD_n remains NOT 4I QC. These relative pin equations are in the memory mux report. Complete 4A data/clock, counter initialization/reset and propagation order are still required before assigning master ticks, DRAM output-valid windows or serializer load edges.

## Conditional RAM clock primitive
Connected page33 traces establish 4A CLK8 as 2A QA/CK2 (10.08 MHz), and its tied A1/B2 inputs as 4I QB13. The second half of 3B toggles CK2 to clock 4I at 5.04 MHz. 4I LOAD9, CLR1 and ENT10 are high; ENP7 shares the derived clock net. A logical count event therefore assumes ENP high at that edge; electrical enable setup/hold remains unqualified. 4A captures the old QB before the downstream 3B/4I transition. This supersedes the open 4A clock/data question, without assigning absolute raster/master phase.
`rtl/n8080_memory_phases.sv` implements those conditional stages using one master clock and crystal clock enables. Its reset is an artificial reproducible zero-state origin, not PCB reset evidence. Native Verilator test `sim/memory_phases.cpp` checks 16,000 master samples and 6,400 crystal edges against closed-form edge/history equations, including clock-enable holds; actual build/test exits are zero. `docs/evidence/sheriff_memory_phases.json` preserves connections, source/view recovery, hashes, receipts and the 64-crystal-edge steady sequence. The primitive is outside files.qip and the board. Physical DRAM/READY/serializer validity and exact Sheriff applicability remain open; no graphics/release pass follows.

Connected CPU page35 views establish the readback reset pulse: 4B LS08 combines CPU SYNC pin19 with inverted CP2 phi1 TTL (4D input13/output12), giving STSTB=SYNC AND NOT phi1_TTL. 3F LS00 input1 is this STSTB, input2 is buffered A14, and output3 drives RAMSTB_n=NOT(A14 AND STSTB). MEMR is a separate neighboring status net. Thus readback 4F/4G and READY 3D clear during the qualified status pulse rather than throughout a latched memory-read status. The memory mux report records all eight Boolean input rows, checked independently against the single clearing tuple (A14,SYNC,phi1_TTL)=(1,1,0). Pulse width, propagation and exact CPU/raster phase remain unqualified.

## 2026-10-09 terminal corrected-clock restart corners
The immutable cb67879-source replay through 6,781 fields finished with actual exit 0: 4,543,144 RAM writes and 13,412 IRQ acknowledgements. The original frozen input/ELF hashes match the terminal receipt. Reused the existing focused MAME reference and unchanged timed-write oracle: field6780 has zero differing pixels. Its final pre-IRQ LXI H at 0x0a03 has sampled T1 at edge-50, final phi2 at edge+194, RST T1 at edge+200, ACK at edge+202 and stack writes at edge+369/+444. Native and MAME both return to 0x0a06. Native RAM0x43eb write128 is now sample+136, after the pixel; MAME records it at about sample+166.991659. No raster/IRQ/scanout/reference offset or tolerance changed.
`tools/record_clock_restart6780.py` records `docs/evidence/sheriff_clock_restart6780.json`, including the actual terminal receipt, source/input/observer hashes and local prediction. Frozen RGB/RAM/state snapshots for both corners are byte-identical to terminal native files. Field2760 remains the separately documented one-pixel failure; the complete graphics gate is false. Current concurrent display RTL, physical DRAM/READY/serializer, audio and release remain unqualified. Do not rerun this completed 6,781-field model. Quartus remains on hold.

## 2026-10-09 upstream restart epoch localization
Terminal native/MAME ROM-read alignment reaches an earlier field2758 vblank return difference: native stacks0x0590, MAME stacks0x05a0. Their ISR opcode sequences match for990 opcodes with MAME epoch125 clocks earlier. At RET0x026d, native resumes0x0590 while MAME executes JZ0x05a0 ->0x0590 (10T/250 clocks), then resumes the same stream. The next1,202 matched opcodes have MAME epoch125 clocks later. This explains a local -125 ->+125 epoch change; it does not establish the upstream reason the IRQ straddles that branch. The directly preceding native opcode fetch is outside the saved bus windows.
`tools/trace_clock_restart2760_epoch.py` -> `docs/evidence/sheriff_clock_restart2758_epoch.json` verifies actual IRQ stack bytes, 3,730 paired ROM reads and74 untaken conditional operand pairs omitted by MAME. MAME0.289 i8085.cpp:821-847 explicitly skips those operand reads when the condition is false; the aligner accepts only the two exact sequential operands followed by an identical sequential opcode. The one taken-JZ crossing is explicit and separately checked, with no general resynchronization. Alignment then stops at the next unexplained sequence difference near the mid-screen IRQ (native CPI0x0a22 versus MAME ISR0x0008). Actual trace exit0 and logs/receipt are `_checks/physical-cpu-restart-corners-20261009/epoch2760-trace-*`. Full source/observer hashes are retained. Field2760 remains a graphics failure; no raster/reference adjustment or timing waiver follows. Quartus remains on hold.

## 2026-10-09 complete restart epoch window
Extended the existing trace through all13,372 MAME ROM accesses:13,365 paired accesses plus seven explicitly reordered post-IRQ accesses, with311 untaken operand pairs omitted by MAME. Three IRQ reorderings are independently checked against stack bytes: the already recorded vblank JZ crossing and two mid-screen CPI3 crossings. Native saves0x0a24 at both mid-screen edges; MAME saves0x0a22 and executes CPI after the ISR. There is no unexplained ROM-sequence mismatch within this recorded two-field window; this is not a full-state or graphics pass.
At the first mid-screen edge2259814400, actual native CPI sampled T1 is edge-150; its7T final phi2 is edge+19, ACK edge+27, and stack writes edge+194/+269. MAME ISR fetch minus11T puts the atomic RST start about25.0034152 clocks before the request. This independently reproduces the existing MB-18 backdated IRQ symptom with the corrected CPU waveform. At the next mid-screen edge2260633600, native CPI T1 is edge-75 and MAME atomic RST starts about49.9966248 clocks after the request; that second boundary does not predate its request. Opcode epoch segments are -125,+125,-50,+125,-50,+125. The local CPI reorderings preserve the +125 offset after return.
Actual trace exit0, source/hash consistency and complete-window checks pass. Evidence remains docs/evidence/sheriff_clock_restart2758_epoch.json and tools/trace_clock_restart2760_epoch.py; existing log/receipt paths are reused. Field2760 still differs by one pixel; earliest upstream pre-vblank fetch remains outside the bus/reference windows. Do not waive the pixel or change raster/reference offsets. Quartus remains on hold.

## 2026-10-09 isolated readback/READY implementation
Implemented original GPL3 `rtl/n8080_ram_readback.sv` with one master clock: HREAD_n XOR first-capture feedback, LS174 flags/data clear and capture, and READY LS74 Qbar clear/preset/phi3 semantics. Twenty-two explicit manufacturer-function cases pass in native Ubuntu Verilator, including00->01->11 feedback, held-clock retention, clear release with clock already high, both async controls low, and no false phi3 event on preset release. Actual build/test exits0; logs/receipts are `_checks/ram-readback-20261009`. `tools/record_ram_readback.py` reproduces `docs/evidence/sheriff_ram_readback.json` with source/receipt hashes.
This is a master-clock sampled conditional pin model outside the board/files.qip. Electrical pulse width, simultaneous-event propagation, DRAM-valid timing, CPU waits, absolute phase and exact Sheriff applicability remain unqualified. No full-game or timing/resource pass follows. Quartus remains on hold.

## 2026-10-09 direct preceding-vblank fetch qualification
The immutable2759-field prefix replay is terminal, actual exit0; original ELF/input hashes remain exact. Newly recorded pre-edge opcode fetches directly establish ANA A0x059f at sampledT1=edge-200 (4T), then JZ0x05a0 atT1=edge-100 (10T). Their final phi2 samples are edge-106 andedge+144. ISA/clock prediction gives RST T1+150, ACK+152 and stack writes+319/+394, exactly matching actual bus events and returnPC0x0590. The9,156 overlapping field2758 bus rows are identical to the previous completed6781-field replay. Do not rerun either completed model.
MAME records ANA A approximately124.9966128 clocks later and begins its atomic RST after that4T instruction, aboutedge+24.9966, before executing JZ; its saved returnPC is0x05a0. This particular vblank is not a backdated-request case. The epoch gap already exists before ANA A; its upstream origin remains unqualified. tools/record_prior_vblank_boundary.py -> docs/evidence/sheriff_prior_vblank_boundary.json retains direct observations, local prediction and source hashes; actual recorder logs/receipt are _checks/physical-cpu-prior-vblank-20261009/boundary-record-*.
The initial recorder incorrectly expected RET before JZ and rejected the data; corrected it to the observed ANA A. A second guard exposed equal MAME operand/opcode timestamps; choosing the last chronological eligible CSV row preserves the recorded access order. No failed report was accepted. The final recorder exits0 and source/hash checks pass. Leading MAME runtime exit remains unknown, separately retained in its reference evidence. Field2760 graphics, current board source, physical RAM/READY/serializer and release remain open. Quartus remains on hold.

## 2026-10-10 vertical enable junction correction

The earlier claim that 5I/5J CLK2 and ENP7 share CK/4 was a source-reading error. The connected Bandido sheet34 view (and original TSF second-source view) shows each ENP7 riser crossing CLK without a junction dot and continuing to the HB_n/4G Qbar6 feedback. CLK2 alone uses CK/4. 5I ENT10 takes4J RCO15 and5J ENT10 takes5I RCO15; both ENP inputs qualify counting. Consequently the active-end carry increments vertical and the blank-end carry does not. QA is still V0; no bit omission, fitted delay or arbitrary divide-by-two is needed.

The [primary TI counter datasheet](https://www.ti.com/lit/ds/symlink/sn74ls161a.pdf), PDF pages1–2, confirms both count enables and ENT-controlled carry. The native joined horizontal/vertical counter model passes actual build/test exits0 over163840 counter clocks:512 increments,512 rejected blank carries,81920 clocks/256 rows per field,224 active rows and1474560 non-CE hold observations. VB D12 is V5&V6&V7 and CLK11 is V4 rising; ideal transitions are line16/240. See `docs/evidence/sheriff_vertical_counter_native.json` and corrected `sheriff_vertical_network.json`; do not rerun these unchanged benches.

The original misread report/tool/doc are retained under `_checks/vertical-counter-20261010/source-correction/`. The historical128-line extension remains a negative for omitted ENP gating, not an unresolved equation to patch by divisor. `rtl/n8080_vertical_counter.sv` remains outside production `files.qip`; real Sheriff applicability/reset/visible origin, propagation/grade, IRQ phase and DRAM/READY/serializer/PROM/RGB integration are not qualified by this isolated model. Field2760 remains open.

## Historical vertical extension contradiction — corrected above


Nintendo original Space Fever Color schematic (three pages, TSF-I/O drawing on page 2) is staged as a related-board cross-reference. `tools/record_vertical_network.py` records its source hash, connected viewports and counter pins in `docs/evidence/sheriff_vertical_network.json`. 5I ENT10 receives 4J RCO15; The original report incorrectly joined CLK2/ENP7; the corrected connections are above. 5J ENT10 receives5I RCO15. Both LOAD9 pins are high. The connected address view shows every 5I output QA..QD feeding V0..V3 through 5K XOR gates, and 5J QA..QD feeding V4..V7 through 5L. QA is not omitted: the earlier informal lowest-bit explanation is rejected.

A bounded contradiction check extends the existing conditional horizontal equations by incrementing an eight-bit vertical count on each terminal carry. It produces alternating 64/256-pixel carry gaps, two increments per 320-pixel period, and a vertical wrap after 128 horizontal periods. Sheriff MAME 0.289 specifies 256 total lines. This is a failed physical extension, not a new native RTL pass. The earlier horizontal native receipt still proves the supplied isolated equations; it does not qualify the full PCB raster. Resolve the connected reload/enable/clock interpretation before integration. Do not insert an arbitrary divide-by-two or shift the reference to hide this contradiction. Sheriff applicability, blanking/flip latch and reset timing remain open; production RTL is unchanged.

Rendering recovery: bundled Python lacks `fitz`; bundled Windows Poppler rendered the staged PDF successfully. Local PDFs and viewports remain ignored; committed reports retain hashes and recovery paths.

## Connected OUT6 direction source — 2026-10-10

The connected Bandido I/O sheet33 trace resolves the serializer direction source: WDO5 enters 2D LS174 D5 pin14; its Q5 pin15 feeds 2L LS04 input13. Output12 supplies NOR and two further inverters (11/10 and9/8) supply RV. For the latched Q5, NOR=!Q5 and RV=Q5. The nearby grounded P9 bus is a separate net. 2D CLK9 receives active-low OUT6; the LS174 captures on its rising edge, with clear1 connected to PCL_n. CPU-to-WDO polarity and the physical bus/latch/reset timing remain open.

`rtl/n8080_video_path.sv` now accepts `flip_latched` (the physical Q5 level) and derives both direction nets. The focused native regression passed actual build/native exits0:512 byte loads,4096 pixels,4096 post-load RAM-change retention observations and4 blanking boundaries, across both directions. Sources, connected viewboxes, original PDF/render hashes and terminal receipts are bound by `docs/evidence/sheriff_video_flip.json` and `sheriff_video_path-flip-source.json`; original pre-edit sources remain under `_checks/video-flip-20261010/source-before/`. Older reports retain their historical source identities.

This is related-board source and isolated functional qualification. The module remains outside production `files.qip`; exact Sheriff revision, PROM/RGB capture clock/polarity, DRAM/READY and visible/IRQ origin remain unqualified. No whole-game graphics pass, field2760 waiver, Quartus timing/resource pass or RBF is implied.

## 3K horizontal clock source — 2026-10-10

The full left continuation resolves 3K CLK9: 4J LS161 QD pin11 descends at originalx~193 to the y~2150 wire, which turns down atx~1865 into CLK9. The nearby vertical-derived NAND6/XOR11 nets are distinct routes. The prior NAND/vertical-row equation is withdrawn; original reports and corrective chronology are retained in `_checks/prom-clock-source-correction-20261010/`, `_checks/color-latch-20261010/clock-report-before-horizontal.json` and Git.

3K is an LS175 with CLR1 tied high. `rtl/n8080_color_latch.sv` models its four digital storage bits and complementary outputs. The joined native harness implements the actual horizontal QD7->8 edge as `ce_counter && phase_4i==15 && upper_4j==7`, using one master clock and the existing qualified four-crystal-edge divider schedule. Actual build/native exits0 cover10240 counter clocks,32 captures320 clocks apart,16 input values and92160 no-CE holds. Data is deliberately varied between captures; q/q_n retain the last captured pin levels. The initial bench ratio failure (build0/native2) and exporter-only failure are retained; no repaired RTL or unrelated campaign was needed.

`docs/evidence/sheriff_prom_clock.json` binds the full source route and `sheriff_color_latch_native.json` binds source/ELF/terminal evidence. The bench uses CLR/reset only as a reproducible origin; the physical tied-high clear and power-up state remain open. PROM pin/dump mapping, LS158/control/PNP polarity, data-versus-clock propagation, exact Sheriff revision and visible/IRQ/DRAM timing still need qualification. This primitive stays outside production files.qip and is not a whole-game graphics pass.

## Corrected clock and PIO source qualification (2026-10-10)

Fresh connected-page geometry proves the3K CLK9 riser crosses4J outputs without dots and joins HREAD_n from2L inverter of4I QD. The4J-QD clock claim is withdrawn. Hbyte is `{upper_4j,!phase_4i[3]}` XOR physical flip; V is raw vertical XOR flip (`docs/PIO_COUNTER_BRIDGE.md`). The focused source-clock native test passes800 captures/12000 holds/12800 static addresses and15 flip holds. It samples settled pre-edge PROM pins, not gate/PROM electrical propagation. Counter-to-visible-pixel/color-tile equivalence and production scanout remain open; do not count this as a graphics acceptance pass.
