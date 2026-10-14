# Current complete-design synthesis: actual RAM diagnosis

The actual check-only map completed with exit0,0errors/215warnings after1:00:08. All161frozen source pins match. Fit and STA were withheld by the parent because synthesis reports695,378registers and1,025,516raw logic cells; these are not fitted ALMs or M10K counts.

Main ROM is healthy: frozen map.rpt1133 contains Simple Dual Port65536x16,1,048,576bits;948 has42ALUT/3registers. The earlier async warning17778 is superseded by inferred message17999 and final RAM tables. No main-ROM CPU, clock, phase or debug change is justified.

The board942 contributes624,631registers,622,882locally, and291,634localALUTs. Its sound-ROM524,288bits plus strip-RAM65,536bits plus work-RAM32,768bits total622,592, only290below its own register count. The board RAM table contains mainROM, soundRAM and fx68k micro/nanoRAMs, with no soundROM/workRAM/stripRAM entry. Work-RAM LUT muxes are explicitly named4052–8227. This strongly identifies these arrays collectively; the report does not give separate named FF counts or explicit uninferred warnings for each, so individual attribution and cause remain qualified.

Video ROM991 has44,103registers/19,389ALUTs and2,048block-memory bits; renderer990 has4,788registers/2,935ALUTs. CLUT initially warned then later inferred, reinforcing that early warnings alone are insufficient. The JSON records exact source port contracts, source pins, report recovery hashes and limits.

Next: qualify minimal sound/color-ROM read inference separately, preserving actual CPU sampling; analyze work-RAM multiple MCU/CPU/paused-HPS writers and strip-RAM CPU/renderer collision semantics before modifying ports. Do not launch fit or claim any seven-metric/timing pass on this baseline. No assembler or RBF generation was invoked.
