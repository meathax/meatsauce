# SE3208 control transfer interface

Primary-source research now establishes implicit R0 for control-register
transfers. The ADChips Jupiter data book, section 4.17.6 (PDF page 159),
explains MVTC/MVFC direction and gives examples loading R0 immediately before
MVTC. The example annotation for MVFC has a direction typo; its surrounding
instruction description distinguishes reads from writes. The related ASIC's
device register map must not be substituted for VRender0's.

- [Jupiter data book](https://datasheet.datasheetarchive.com/originals/library/Datasheets-UD4/DSAUD0063929.pdf)
- [VISA2000 data book](https://datasheet.datasheetarchive.com/originals/library/Datasheets-UD3/DSAUD0058543.pdf)

`se3208` now exports a real coprocessor request/reply interface. MVTC submits
R0, the two-bit coprocessor number and three-bit register selector. MVFC writes
the returned 32-bit value to R0. Retirement waits for successful completion;
errors preserve the faulting PC/opcode and stop execution. Other GPRs, SR, SP
and ER are preserved by the implemented transfer path. Further primary ISA
clarification remains relevant to unexercised privilege/extension corner cases.

`se3208_cp_access` holds requests under backpressure, accepts immediate or
delayed replies, and buffers the result while CPU ce is paused. Its transport
runs on clk. Reset cancels the outstanding transaction. One request may be
outstanding. All partners must share reset; no transaction may survive a
system reset into a new request epoch.

`scripts/sim.py cpu_control` verifies all 64 canonical encodings from a
synthetic reset-vector BIOS, with production state loading disabled: 128
successful transfers and 64 explicit device-error cases, plus invalid-opcode
rejection and reset cancellation. Read replies contain varied full-width
values; writes use the executed R0 value. This is CPU transport verification,
not an implementation of a physical coprocessor.

The board currently connects an explicit error responder until the real CP0
device is integrated. It does not supply constant success/status data to pass
boot. CCMD/GETC/EXC/LDC/STC and unknown encodings remain unsupported.

## Device implementation evidence and limits

VISA2000 sections 3.16.2.1–4 (PDF pages 56–57) identify CP0 CR7 as the cache
enable command, CR6 as status, CR5 as invalidation, and CR3 as bank policy.
They specify enable bit 11, invalidate command bit 0, and status busy bit 20.
These roles fit the observed Crystal System program's save/clear/restore R0
control sequence. This correspondence is an inference from firmware and a
related manufacturer's ASIC; the VRender0 revision has not been identified.

VISA2000 page 55 describes 2KiB while its status table describes 1KiB. Jupiter
pages 155 and 163–164 describe another cache and a different CR5/6/7 map.
Keep these differences explicit when choosing VRender0 configuration fields,
cache geometry and behavior. The earlier AE32000 manual is not a replacement.

Next integrate CP0 control with actual cache/buffer state and invalidation
completion, then resume original BIOS/game boot against the qualified oracle.
Do not replace cache enable/invalidation with successful no-ops or claim game
acceptance from this synthetic test. Raw documents, rendered reviewed pages
and firmware disassembly remain private under `sim/obj_dir/isa_research`;
`se3208_databook_research.json` records provenance and hashes.
