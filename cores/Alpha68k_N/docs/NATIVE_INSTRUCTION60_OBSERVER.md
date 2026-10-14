# Native field60 instruction observer status

Parent9624866. The real-system harness now writes instruction_events.csv for
accepted transactions in fields59/60: raw raster, address/strobes/read/write,
data before the edge, and actual FC, exception-unit PC, Ir/Ird and phase
registers after the accepted edge. These are read-only Verilator root reads;
no game CPU, clock, ROM, memory/renderer or pinned-framework RTL changed.
Internal fx68k PC is not labelled an instruction-address/CURPC equivalent
without inspecting its recorded bus context.

Actual Ubuntu build exit0; dedicated collector ELF and source manifest are
pinned in research/kyros_instruction60_diagnostic_* records. The61-field real
CPU run remains pending terminal qualification. Current loaded runner source
is frozen in its ignored capture. A future Windows launch now fails before
writing a job, while the current Linux run retains its already-loaded code.

Two setup failures are preserved. First, Windows Python invoked a Linux-only
runner and raised WinError2 before any RTL build/run. Second, the copied
runner retained three hard-coded old ELF/output references. Its own verified
PID was stopped by SIGTERM, terminal-15, before relaunching with every reference
corrected. The partly overwritten original background61 capture is now
quarantined at sim/captures/diagnostics/background60_wrong_output_archive.
It contains mixed streams and is not a qualified replacement. The original
background ELF was recovered from its frozen build root and matches the
original receipt hash exactly; its local alias is restored.

Committed original causal findings remain available, along with independent
reset421 evidence and saved field60/360 RGB. References to the original
background61 capture's live path must be treated as requiring requalification
until a documented fresh capture replacement is verified. No evidence is
silently attributed to the old ELF. Recovery requirement and exact handles:
research/kyros_background60_capture_requalification_required.json and
research/kyros_background60_original_elf_recovery.json.

Next: revalidate the exact current PID/terminal receipt, qualify all61 metrics,
check available RGB against the prior snapshot hashes/independent reset421,
and inspect the program bus around the background write. Record any qualified
fresh replacement explicitly. Do not restart an active run on timeout or call
this observer a gameplay/audio/timing pass before its evidence exists.

## Terminal qualification and attributed fresh replacement

Actual61 fields completed exit0; all57,344 unique pixels per field, zero unmapped/deadline/overflow/duplicates, worst2,280 ticks. All saved images equal the quarantined image files and independent reset421 checkpoints0/30/60 match. Original/current DUT manifests differ only in sim/system_main.cpp (read-only observer). The original background61 live path now contains a qualified fresh copy with explicit replacement/source-ELF metadata, not an attributed recreation of the old execution. Archive and old receipts remain.

Native backdrop write uses Ird/Ir0x13FC, internal PC0x1AE3C, FC5, the same byte50 and absolute destination as MAME instruction0x1AE34. Both native and MAME take160 master ticks (20 CPU clocks) from the preceding work write0x020EAE to the backdrop write. The observed offset already exists before this MOVE.B; do not patch its cycles or CPU clock. Before-edge debug DIN may show a pipeline-stage value and is not CPU-latched fetch data. Next investigate earlier interrupt/start execution phase, with complete recorded bus context rather than guessing from that diagnostic input value. Full evidence in research/kyros_instruction60_diagnostic_verification.json.
