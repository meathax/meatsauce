# Conditional CPU READY service contract

The connected Bandido CPU/I/O sheets establish the request/readback/READY equations below. Exact Sheriff revision, propagation, DRAM data validity and reset alignment remain limitations; this is not a production integration approval.

| Node | Supported connection/equation |
|---|---|
| STSTB | CPU SYNC19 AND NOT phi1TTL(CP2:17), through CPU4D13/12 and4B4/5/6 |
| RAMSTB_n | NOT(A14 AND STSTB), CPU3F1/2/3; shared clear of4F/4G LS174 pin1 and3D LS74 pin13 |
| HREAD_n | NOT I/O4I QC12 through inverter and CP2:31; independent periodic RAM slot waveform |
| Readback clock | HREAD_n XOR old4F Q2, LS864T4/5/6; CLK9 of4F/4G |
| Readback flags | CLRlow -> Q1=Q2=0; positive capture -> Q1=oldQ2,Q2=1; RDY_IN=Q1 |
| CPU DI | Buffered RD0..7 captured by4F/4G; raw buffered RD also reaches video independently |
| READY3D D12 | NOT phi1TTL via4D13/12; C34=120pF |
| READY3D CLK11 | phi3TTL CP2:23; C35=120pF |
| READY3D PRE_n10 | RDY_IN |
| READY3D CLR_n13 | RAMSTB_n |
| CPU READY23 | READY3D Qbar8 |

A14 is the drawn request input, without MEMR or WR_n qualification. Thus both reads and writes can request the handshake. Do not replace it with read_start, MEMR, or an exact software address range. A15 is not part of this request NAND. This identifies service applicability, not a DRAM write commit edge.

During RAMSTB_n low, both readback flags clear. READY is high under active CLR, including the LS74 both-PRE/CLR-low condition where Q and Qbar are both high. That condition is not a stable complementary state. After clear releases, RDY_IN is still low and asserts PRE, forcing READY low. The first positive XOR capture setsQ2; its own feedback ends the XOR pulse. The next qualifying capture setsQ1, releasing PRE. Only a subsequent positive phi3 edge with both controls high samples D; D=0 yields READY=1. Releasing CLR while the clock is already high creates no new capture.

In the settled related-board2A/3A clock network, phi1TTL(3A QB4) is low at decade counts0,1 and high2..9. phi3TTL(3A QE10) is high0..2, low3,4, high5..9. Its rise4->5 samples NOT QB=0. The physical CPU phi1 driver has the opposite level to phi1TTL; phi3TTL is not CPU phi2.

| Ideal crystal-count interval | phi1TTL | phi3TTL |3D D |
|---|---|---|---|
|0,1|0|1|1|
|2|1|1|0|
|3,4|1|0|0|
|5..9|1|1|0|

For a synthetic common origin matching the current25-master-tick CPU phase, phi1TTL=NOT(phase<5). phi3 falls at ideal masterphase7.5 and rises12.5; rounding upward gives phi3TTL=(phase<8 OR phase>=13). Both edges are9.920635ns late at50.4MHz. The phi1TTL rise at crystalcount2/masterphase5 is exact in this projection. CPU phi2 occupies rounded phases8..19; its fall at20 is exact. These equations explain a named digital projection, not board electrical timing.

3A clear is tied high and the source clock chain free-runs. The source does not fix its phase at CPU reset release. The CPU adapter continues phase during reset; the existing memory_phases component holds its modeled divider/counters at zero during reset. A joined synthetic test must name the relative reset release and common crystal rounding convention. No absolute startup/raster/IRQ origin follows from it.

The steady memory_phases projection increments4I on every fourth crystal edge. HREAD_n toggles every16 crystal intervals and repeats every32. Its phase relative to the10-crystal CPU T-state varies; two readback captures therefore do not imply two CPU wait states or any fixed wait count.

Keep current n8080_ram_readback's master-sampled old-state behavior explicit: RDY_IN released by a second capture on the same sampled tick as phi3rise is still seen low by its READY branch, so READY waits for another phi3rise. Hardware XOR/LS174/LS74 propagation could order those events differently. Conditional phase cases must retain that limitation, rather than inserting a fitted delay.

The connected mux/CAS/RAS/WE equations are already recorded in sheriff_memory_mux_connections.json. CPU_WR_RD generation, effective DRAM commit/read-valid windows, XOR pulse width, setup/hold, C34/C35 delay, simultaneous asynchronous-control release and exact Sheriff applicability remain prerequisites for production. A component environment may supply a stable synthetic RAM byte and commit a synthetic write on WR release; that does not qualify4116 DO or WE timing.

Evidence: docs/evidence/sheriff_cpu_ready_service.json. The native joined test, if qualified, is separately scoped in sheriff_cpu_ready_service_native.json. No production source, QIP, raster, IRQ, Quartus or MAME state is changed.

## Native joined qualification

The actual n8080_cpu_ready, n8080_ram_readback and n8080_memory_phases components passed a synthetic stable-RD/write-release instruction program at named reset-release CPU phases0,5,10,15,20. Build0, producer0 and all five Linux native runs0. Each executed15 RAM requests:7 reads and8 writes, both classes entering WAIT. The program checks STA/LDA, MOV, SHLD/LHLD and CALL/RET stack service; all RAM results pass and the address remains stable during WAIT. Observed WAIT master ticks are1375,1275,1350,1275,1200 respectively; no count is prescribed.

Exact frozen sources, generated Linux ELF, compilation logs, perphase event CSVs and process receipts are retained under _checks/agent-ready-service-native-20261010/. Source/binary/trace hashes and explicit assumptions are in docs/evidence/sheriff_cpu_ready_service_native.json. The native observer reports16 flag captures/releases because one pair precedes the15 actual RAM requests during synthetic startup. Sampled clock/preset coincident rows retain the old-state component convention; they do not qualify electrical ordering. No unchanged manual25-phase READY test or long ROM replay was repeated.
