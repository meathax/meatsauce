# Isolated DRAM control pins

`rtl/n8080_dram_control.sv` implements only the connected zero-delay gate
and LS153 multiplexer equations retained in
`docs/evidence/sheriff_memory_mux_connections.json`. Related Bandido
connectivity remains conditional for the exact Sheriff revision.

The inputs are explicit pin levels: CPU address A0–A15, raw CPU WR_n,
SYNC and phi1 TTL; CPU_WR_RD; physical Hbyte bits H0–H4 and V0–V7;
and already qualified raw CAS_n, raw RAS_n, COMADR_n and HREAD_n.
CPU_WR_RD generation remains unresolved. This module does not derive it
from SYNC, DBIN, MEMR, READY, the CPU address or an access request.

The LS153 selector is B:A = NOT HREAD_n : NOT COMADR_n. C0 supplies
A0–A6; C1 supplies A7–A13; C2 supplies H0–H4,V0,V1; C3 supplies V2–V7,0.
With row C0 and column C1, row + (column << 7) reconstructs CPU A0–A13.
With row C2 and column C3, it reconstructs Hbyte + (V << 5), confined
to the lower 8192 bytes. Hbyte/V are physical levels; visible origin,
counter reset and flip transformations are external questions.

The 3E NOR disable output is HREAD_n AND NOT CPU_WR_RD. The 5B OR
gates produce raw CAS_n OR disable and raw RAS_n OR disable.
STSTB is SYNC AND NOT phi1 TTL, and RAMSTB_n is
NOT(A14 AND STSTB). The first LS153 selects high WE_n on C0/C2/C3;
C1 selects the NAND output NOT(A14 AND NOT raw CPU WR_n).
The exported write predicate is the Boolean selected-C1 write level.
It is not a DRAM storage commit event.

`tools/qualify_dram_control.py` snapshots the new module/harness and the
existing frozen source-derived `sheriff_dram_cycle_edges.json` rows.
It consumes all 32 edge rows, both before/after states, both explicit
CPU_WR_RD levels, and the connected eight-row RAMSTB truth table.
It does not rerun the phase derivation. The native address tests cover
all 65536 CPU pin addresses (all 16384 positions with A14/A15 aliases)
and all 8192 physical Hbyte/V combinations, including every walking bit
and row/column boundary.

Actual exits, source/model/fixture hashes and the scoped results are in
`docs/evidence/sheriff_dram_control_native.json`; recovery is
`_checks/agent-dram-control-20261010/`. No 4116 storage/data model,
access-time, refresh, setup/hold, READY response, serializer sampling
order, physical Sheriff timing or production integration follows.
The module is not added to the board or files.qip. No Quartus or RBF
operation is part of this qualification.

The completed qualification has actual build/native/workflow exit 0, with
zero mismatches across 1024 frozen pin cases, 65536 CPU pin addresses and
8192 video addresses. All source, fixture, model and report artifact hashes
verify independently in
`_checks/agent-dram-control-20261010/independent-verification.json`.
The exported 3E NOR gate output is named `disable_level`.

The initial setup-key guard failure (exit 1, no compilation) is preserved in
`_checks/agent-dram-control-setup-v1-20261010/`. The reserved-name compile
failure (exit 1, no native execution) is preserved in
`_checks/agent-dram-control-compile-v2-20261010/`. Both corrections concern
the new helper/interface; they do not select an unresolved physical signal.
