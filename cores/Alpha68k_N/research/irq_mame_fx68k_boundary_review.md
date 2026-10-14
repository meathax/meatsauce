# MAME0.289 and fx68k interrupt-boundary review

MAME configures the microcode-derived m68000_device, not the separate Musashi CPU. All1024 binary fx68k microcode words match the MAME generator table values.

MAME input changes recompute m_int_next_state. Generated handlers snapshot that state when IR transfers to IRD. In opcode30fc, the destination write precedes this snapshot; DBRA has explicit branch-specific snapshots. fx68k instead samples/stabilizes IPL on Phi2 and captures intPend into its sequencer group-one exception latch at an enabled enT3 boundary.

The actual writes, savedPC854/858 and savedA0 difference2 establish which operation completed before each captured IRQ. They do not establish the internal MAME cutoff timestamp or unique physical cause. These implementation mechanisms can explain a software ordering difference without proving an RTL defect.

Ranked missing evidence: MAME pending/next-state at its DBRA snapshot; exact native microaddress/enT3/rInterrupt latch; timer/bus placement relative to both cutoffs; physical PCB sampling correctness. The existing observer raw micro word is not a unique microaddress, and its internal PC is not a dispatch timestamp.

No replay or production change was made. Original finite-stop coverage correction remains authoritative. B16, MAME-bug, RTL-defect, physical-cause and timing-fix acceptance remain false. Source lines, hashes, actual native timelines and next narrow evidence are in the adjacent JSON.
