# Word0x22 and replicated strip RAM candidate
Production patch: **board_replicated.patch**; capture-host patch: **host.patch**. Base files are pinned in qualification.json.

Work RAM uses full-byte banks and an external16bit word0x22, preserving simultaneous coin writes with old0x29-high shadow. CPU/HS/HLE accesses, reset retention and acknowledged pause remain at their original edges. Registered responsekind selects the newly clocked RAM output on the same accepted edge, without a later mdin pipeline or DTACK change. Pause-entry snapshots priorCPU DI before hiscore reuses the read port. Hiscore preserves old read data on writes and its last output between accesses.

Strip RAM has two equal SDP copies. Every CPU write updates both at the same edge. One serves acceptedCPU olddata reads; the other serves the physical renderer olddata read. This avoids the65kregister duplicate seen in both failed TDP coding probes. Extra65536blockbits are subject to all full fitted hard limits.

Authentic originalcandidate real-fx68k fixture passed8852edges/5187readDI checks, all18registers/PC/bus/HS/debugports/fullRAM and both coin branches. It deliberately counted24writeDI-difference ticks. Finalreplicatedvariant restores originalOLD_DATA and is joined through sourceinduction plus independent8193-edge exactstorage miter, not claimed as a different finalexecutable run.

Authentic isolatedQuartus map passed:167rawcells,51registers,163840blockbits, six namedbytebanks.48analysisRAMsegments is not a fitted M10K count. FailedIcarus,space-containingMdir,implicitunique-case runtime and ineffective ternary/ifelse inference receipts remain preserved.

The time0implicitcase failure is avoided with +verilator+noassert; generated C++ pins prove explicit miter if/$fatal comparisons remain ungated. Finalcombinedgameplay, fullfit/timing andRBF remain false. Parent owns canonical patch integration and finalcombinedrun.
