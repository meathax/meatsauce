# Conditional READY timing gap in the MAME reference

The current local MAME source maps Nintendo8080 RAM4000..7fff directly (`n8080.cpp:680`) and clocks Sheriff at20.160MHz/10 (`:1188`). The complete driver and8080 CPU device header/implementation contain no READY-named interface or model. The exact hashes and public callback/input declarations are preserved in `docs/evidence/sheriff_ready_reference_gap.json`.

The related-Bandido drawing instead connects8080 READY23 to3D LS74 Qbar8. RAMSTB and the readback RDY_IN flags control its asynchronous pins; phi3 samples its D input. It can stall both A14 memory reads and writes. This connection is source-supported; actual Sheriff revision, valid DRAM data/access/write ordering, electrical edge cases and reset alignment are still open. See `CPU_READY_SERVICE.md` and the memory handshake evidence.

These sources identify a reference limitation to resolve before an expensive paired replay of integrated physical arbitration. They do not establish a measured Sheriff wait count or explain away field66/2760. Preserve the original reference captures and graphics negatives. Do not change native clocks/raster/IRQ or add fixed waits to reproduce an atomic MAME schedule.

After the actual memory service is source-qualified and connected, compare the first affected CPU/RAM boundary. If the reference omits a required service event, retain the original baseline and record the precise divergence. Any corrected reference must be a separately identified ordinary-ROM/input run implementing the justified service, with source/fixture/receipt closure; it cannot retroactively qualify or replace the original baseline. The complete zero-unexplained-graphics and gameplay acceptance conditions remain required.
