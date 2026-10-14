# Integrated development state inventory — 2026-10-11

The centrally integrated graph retains the real 68000/Z80, SDRAM graphics pipeline, PROM decode, AY/YM2203/DAC and framework interface. It is not a production acceptance receipt. Diagnostic state is not a shipped savestate feature.

The board uses one 48 MHz game clock with enables. Kyros/Japan retain their existing CPU enable, memory, IRQ2, MCU compatibility and bus acceptance paths. Profile2 adds a rational 3,579,545 Hz Z80 enable and genuine T48 firmware MCU, rational MCU clock enables, low-byte shared RAM write arbitration, firmware IRQ2, flip and accepted-transaction HALT drain. The RAM address/data port serves MCU replies before conflicting main-CPU work accesses; hiscore borrow waits for the registered MCU write drain.

P2 transaction data comes from the donor's architectural latch at the already delayed enabled write observation. Physical P2 output remains unchanged. Sound ROM loader word address remains explicitly 15 bits; its extra diagnostic read exists only in Verilator. Registered CPU read and byte-lane timing remain unchanged.

## Current acceptance boundary — 2026-10-11

Current source checkpoint6caf retains the integrated donor/board graph; source and terminal receipts are recorded separately in progress.md. Fifteen complete B01/B02 RGB fixtures and both nonvacuous500-pixel CLUT255 probes qualify the finite late-scene renderer requirements. Full real CPU attract/gameplay is a separate gate; natural stage5/ending progression is not an additional requirement.

The current Kyros4401 replay is still partial at the root-observed3439-field checkpoint, with no terminal result. B04 ordinary pickup, B16 timed18-pixel/CPU-phase divergence, Japan control/timing and Stingray12-byte RAM plus complete181/1800 lifecycle acceptance remain open. Japan's raw8 endpoint bytes are retired stack; its historical strict RAM failure is retained and does not establish timing equivalence. Complete-design resource/all-corner timing and external I/O/CDC evidence must remain distinct; no RBF or hardware readiness is claimed.

Production ROM admission accepts profiles0/1/2 after finite genuine181 and realHPS wrapper qualification. The exact final joined native build, full1800 replay, strict RAM, complete fit/I/O constraints and hardware/release acceptance remain open.


Historical source-join v4 preparation checkpoint (2026-10-11): MCU program storage uses two 2048x8 parity banks, registered bank reads and captured address bit0. All4096 bytes, adjacent-loader lane ordering, FFF wrap and one-cycle program read are preserved by the source-extracted79875-comparison smoke (actual build/run0). This modifies storage RTL in simulation and synthesis; the v3 byte-identical preprocessing result only described the superseded diagnostic guard. Current board43b8c6e7600e4c4089f0d3c0e4a15637be8bfcbdd626ddd0bc0e222b7b1553ce is separately staged, not part of the historical181 executable. Original joined MAP98.65% and guard-only MAP98.8046% estimates failed the ALM requirement; no FIT was run on those graphs. At that recorded preparation checkpoint, root application was held pending actual banked ROM RAM inference and accepted resource estimates. Current disposition follows the source-bound progress receipts and acceptance boundary above. T48/P6, shared SSG period0 correction, native dependency recipe, H0O5, profile<=2 and reviewed additiveSDC are preserved. Paired storage proof does not qualify full-board gameplay, mixed-port hardware collisions, timing or I/O.
