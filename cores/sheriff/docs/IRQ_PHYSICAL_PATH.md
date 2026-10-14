# Conditional physical IRQ path

Primary related-board evidence is the January1980 Bandido manual, I/O drawing77-3367-11 (PDF34) and CPU drawing77-3366-11 (PDF35). Exact Sheriff PCB applicability remains conditional. The PDF SHA256 is aa68eb8538e404c2ee1e02b7b47c0e40c62e9d9800cefcf22981c733c4b30224. Source hashes and original-page crop boxes are in docs/evidence/sheriff_irq_physical_path.json; recovered viewports are _checks/agent-irq-path-20261010/.

| Net | Connected source | Stable equation |
|---|---|---|
| V6,V7 | Raw5J QC12,QD11, before flip/address XOR | Counter bits6,7 |
| INTD |4K LS86 inputs12=V7,13=V6; output11 toP10:3/CP3:3 | V6 XOR V7 |
| NQ |2K LS00 inputs5=V7,4=INTD; output6 | NOT(V7 AND INTD) |
| INTR |2K LS00 inputs9=NQ,10=4G Qbar8/VB_n; output8 toP10:1/CP3:1 | VB OR(V7 AND NOT V6) |
| INT |CPU3D LS74 D2=INTE16, CLK3=INTR, PRE_n4=+5, Q5 toINT14 | Sample INTE on positive INTR; retain between edges |
| IRQ clear |3E LS174 Q1pin2=latched positive INTA,4D5/6 inverter to3D CLR_n1 | INTA high asynchronously clears INT |

C20=300pF is drawn from INTR/3D CLK3 to ground. CPU RESET12 instead receives CP2/P9:49; it is not drawn on3D interrupt CLR. I/O TP6/P9:49 is5D LS123 Q6 through two5F LS14 inverters3/4 and5/6. This trace does not qualify the monostable trigger, pulse width or power-up alignment. A low INTE inhibits a future captured request; it does not establish an asynchronous reset of the retained IRQ latch.

The qualified horizontal/vertical components establish a counter-relative event: positive CK/4 with active HB_n and4J RCO15 increments5I/5J. The blank-end carry is rejected. There are320 common-counter clocks per row and256 raw vertical rows per field. VB clocks on V4 rising with D=V5 AND V6 AND V7, producing steady blank transitions at16/240. These unchanged native qualifications are reused, not rerun.

| Raw vertical transition | Stable INTR event | INTD afterward | Acknowledge byte in that stable vector interval |
|---|---|---|---|
|127->128 | Rise through counter/XOR/NAND path |1 |CF, RST1 |
|239->240 | Rise through counter/VB latch/NAND path |0 |D7, RST2 |
|15->16,191->192 | Fall, no positive3D clock | Conditional on V6/V7 | No new IRQ capture |

In steady operation INTR is high for raw counts128..191 and240..255/0..15. Each rising event follows the active-end horizontal carry, where the qualified horizontal network enters its64-clock blank interval. This supports an event relative to physical counters; it does not identify software h=0, visible x/y, an absolute master tick or a reset origin.

The CPU LS153 truth table selects interrupt data at A:B=11. D0,D1,D2,D6,D7 are high;2Z2C3 pin3 supplies D3=INTD,4D11/10 supplies3Z1C3 pin3 D4=NOT INTD, and3Z2C3 pin3 supplies D5=0. Thus the byte is C7 OR(INTD<<3) OR((NOT INTD)<<4). INTD is live combinational mux data. The source does not prove a vector register captured at request; a sufficiently delayed acknowledge could see another vector interval.

Physical counter CLR/LOAD are tied high in the existing connected trace, and isolated bench reset is artificial. Counter/VB/IRQ power-up state, CPU reset pulse alignment, INTE setup/hold, C20/interconnect delays and exact Sheriff revision remain open. The127->128 transition changes both V6 andV7; the stable XOR equation does not exclude propagation glitches. The240 request adds a VB latch propagation stage. Neither path supplies an electrical edge-order or integer master-tick delay.

Current board inspection at rtl/n8080_board.sv:67/69/166/168/172 shows a v240 origin, pixel_phase0/h0 request, sampled INTE, registered CF/D7 vector and cpu_ack clear. Those behaviors are documented model choices; this source trace does not qualify their physical phase or authorize a production edit.

The saved FIRST_IRQ_BOUNDARY/CPU_PHASE_ORIGIN evidence remains intact: field66 returnPC0ff3 versus MAME0fef and the uniquely matched model reset-release phase7 are observer/model evidence. Do not shift raster or IRQ, invent an offset or align physical reset to MAME's virtual first fetch. No new simulation, production changes, Quartus or RBF were performed.
