# Conditional connected CPU DRAM service

The joined qualifier connects the existing CPU READY adapter, source-derived memory phases, DRAM pin control, storage and RAM readback. Actual storage DO feeds readback, whose captured byte feeds CPU RAM reads; its READY output services CPU wait. Source RAS/CAS/WE and DI commit all RAM writes. Host memory supplies the ordinary instruction ROM fixture only.

CPU_WR_RD is an explicit input supplied as constant1: all CPU slots are enabled, including those during non-RAM bus cycles. This is conditional stimulus, without a production generator/polarity claim. PhysicalHbyte19/V166 are fixed supplied video address pins. The previous service fixture's rounded50.4MHz/20.16MHz projection and reset origins0/5/10/15/20 are retained, without searching or fitting an offset.

The unchanged storage component captures row/column on supported RAS/CAS edges, writes early or delayed DI on the corresponding pin event, and produces held DO. Readback samples old DO before shared-clock validity changes. The qualifier checks valid second captures from the requested RAM address against bytes observed at actual storage writes. That ledger never provides read data. A write must have raw CPU A14 asserted/WR low and the latched row/column must match the CPU byte address.

The ordinary STA/LDA/MOV/LHLD/SHLD/CALL/RET fixture is byte-identical to the existing CPU READY service program. Completion requires its actual committed values and marker, successful reads through captured DO, serviced waits and stable wait addresses. Coincident unsupported storage edges stop the run. No host write-on-WR-release, invented CPU_WR_RD equation, derived clock, phase tuning or production patch is used.

Run `tools/qualify_cpu_dram_service.py` with the bundled Windows Python. It freezes sources/fixture, builds and runs the joined top in explicit Ubuntu WSL, and records actual OS exits, traces, executable hash and source/evidence closure. The report is [sheriff_cpu_dram_service.json](evidence/sheriff_cpu_dram_service.json); recovery is `_checks/agent-cpu-dram-service-20261010`. The report's `conditional_joined_service_qualified` and actual receipts determine the result; this document does not assume a pass.

The storage primitive's existing component synthesis proves M10K use without fabric-memory explosion. Its physical DUAL_PORT form is acceptable because logical accesses serialize on one address; physical SINGLE_PORT is not an additional acceptance gate. No synthesis, fit, native abstract-service rerun or full-board ROM replay is needed for this joined test.

Physical CPU_WR_RD timing/generation, dynamic arbitration, exact Sheriff revision and DRAM grade/vendor/load, CPU/serializer setup/hold, reset/refresh and electrical simultaneous-edge order remain open. Even a successful joined run qualifies conditional functional service only. Board RTL and production QIP remain untouched.
