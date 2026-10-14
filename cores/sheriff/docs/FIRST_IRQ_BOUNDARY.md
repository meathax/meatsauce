# First Sheriff IRQ return-PC divergence

The earliest differing saved IRQ return PC occurs at field66, after82 equal return PCs. `tools/find_first_irq_return_difference.py` locates it in the completed native/reference write journals; it stops on any stack-pair ambiguity. The reference pair identity is explicitly inferred from timing/address, then independently checked at this boundary by a new short exact-callback capture.

`tools/capture_first_irq_boundary.py` reused the retained synthesizable-board model and ordinary parent-ROM inputs for68 fields. Real native and MAME children both exited0; a Linux parent also persisted native exit0. The unchanged main-board/CPU/harness hashes, model ELF and original model closure are recorded. All tested I/O/memory/digital-sound/audio prefixes and five native/reference snapshot pairs are byte-identical to the saved complete restart captures. The model retains old SN gain constants; this does not qualify current integrated audio.

The request edge is master tick54067200. Native T1 values below are bus-derived tags (DBIN minus27 or SYNC minus2); MAME values are atomic opcode callback times. Neither is a measured physical phi1 edge.

| Event | Native, clocks from request | MAME, clocks from request |
|---|---:|---:|
| LDA60c0 T1 tag/callback | -400 | approximately-450 |
| ANA A T1 tag/callback | -75 | approximately-125 |
| Next T1 boundary after ANA | +25 | approximately-25 |
| JNZ0fef T1 tag/callback | Deferred until after IRQ | approximately-25 |
| RST T1 tag/inferred callback | +25 | approximately+225 |
| Saved return PC | 0ff3 | 0fef |

The source-model native final ANA phi2 gate sample is at+12. The RST bus-derived tag is+25, observed ACK is+27, and stack writes are+194/+269. The completed reset audit in `CPU_PHASE_ORIGIN.md` establishes that this tag sits at counter phase7; phi2 ends at phase19, so the offset is19-7=12. The earlier +19 projection in this report is superseded. MAME has already begun the10-T-state JNZ, which finishes at+225 and branches to0fef. Actual stack writes confirm both PCs. Exact callback order does not turn MAME atomic accesses into physical bus edges.

Across the first82 equal return-PC cases, inferred MAME RST starts are consistently50 master clocks (two8080 T states) earlier than native. At the first different case this becomes+200, because the reference takes the branch before servicing the interrupt. This explains the local split without an ANA flag error. It does not yet establish the physical power-up/reset phase or repair the later field2760 pixel.

The existing reset audit already matches all78 pre-opcode pin samples and uniquely identifies release phase7. Native first SYNC52/DBIN77 and tag50 differ from MAME's virtual PC0 fetch at time0. This supports an observation-origin difference without proving a donor reset fault; another reset bench is unnecessary. Next qualify actual CPU/raster/IRQ and memory-service timing. Do not change clocks to align MAME's virtual start, tune an image offset to field2760, or repeat unchanged long runs. Physical counter/DRAM/READY/serializer, current integrated gameplay/audio and resource/timing gates remain open.

Evidence: docs/evidence/sheriff_first_irq_return_difference.json and sheriff_first_irq_boundary.json. Recovery: _checks/first-irq66-boundary-20261010/{launch,terminal,source-binding,prefix-comparison}.json, native-exit-code.txt, native/bus.csv and mame/observations_exact.csv. The initial foreground launch observation failed while the recorded host11756/native-wrapper47976 remained live; no job was restarted. The independent child receipts subsequently reported success.

No production RTL, Quartus, RBF, hardware deployment or reference payload edits occurred. This completed68-field diagnostic should be reused unchanged.
