# SE3208 primary vendor encoding evidence

The official ADChips EISC Studio3 SDK supplies a working SE3208 assembler,
disassembler, linker and simulator. The tools run with the SDK's matching
32-bit Cygwin runtime. They were extracted statically; no installer was run.
Raw tools, objects and probe output remain private in `sim/obj_dir/isa_research`.
Source URL and hashes are in `se3208_vendor_tools.json`.

Primary source: [ADChips Studio3 update page](https://www.adc.co.kr/support/update_view.php?idx=1356),
[official SDK archive](http://www.adc.co.kr/download/EISC_Studio/ES3_setup3615.zip).

## Verified encoding correction

`scripts/se3208_vendor_probe.py` assembles all 64 canonical MVTC/MVFC
operand combinations, disassembles them, and disassembles every word in
FC00..FFFF. The first operand accepts numeric values 0..3 and occupies bits
9:8. The CR selector occupies bits 2:0. Bit 3 distinguishes MVTC from MVFC
inside the 60..6F subrange. This does **not** establish the meaning of the
numeric first operand or an implicit payload GPR.

| Low byte | Vendor mnemonic | Encodings across four first operands |
| --- | --- | ---: |
| 00..3F | CCMD | 256 |
| 40..4F | GETC | 64 |
| 50..5F | EXC | 64 |
| 60..67 | MVTC | 32 |
| 68..6F | MVFC | 32 |
| 80..87 | LDC | 32 |
| 90..97 | STC | 32 |
| Remaining low bytes | unknown to this vendor disassembler | 512 |

Do not call the 512 unknown words architecturally reserved without additional
evidence. The staged vendor simulator also contains FCC0/FCC8 handlers that
the staged assembler/disassembler does not name; the tool revisions are not
a complete physical-chip specification.

The boot words are `fc65: mvtc 0, %cr5`, `fc67: mvtc 0, %cr7`, and
`fc6e: mvfc 0, %cr6`. **Correction to earlier research/progress wording:**
MAME's disassembler prints CR14 for FC6E and describes the first operand as
R0. These names must not be treated as primary ISA evidence. Earlier dated
entries retain their original wording; this entry supersedes those operand
interpretations. The observed program does save/clear/restore R0 around
control writes, but that observation alone does not define the instruction.

`rtl/cpu/se3208_decode.sv` now follows this primary classification for all
1,024 words. Existing enum values remain stable; five new operation classes
are appended. At the encoding-correction milestone, the CPU sequencer faulted on all
coprocessor operations. Subsequent primary documentation established implicit
R0 and enabled the transfer protocol; see SE3208_CONTROL_INTERFACE.md. The
physical device and other instruction groups remain incomplete. There is no no-op boot bypass,
constant status reply, state injection or change to game ROM data.

## Decisive verification

`python -X utf8 scripts/sim.py cpu_decode` regenerates both independent
oracles and compares all 65,536 RTL decode results: 64,512 MAME results plus
1,024 vendor results. **PASS**, with 736 vendor classification corrections
to MAME. The simulator source manifest fingerprints the primary CSV, probe
script and tool metadata, preventing reuse of a stale run-only binary.
Evidence: `simulation_cpu_decode.json`, `se3208_vendor_encoding.json`.

## Vendor simulator is not a control-effects oracle

The staged `se3208-elf-run.exe` is a real interpreter: a synthetic HALT
program terminates, a JMP-to-self program times out, and FFFF reports an
unknown opcode at the expected PC. However, its FC00, FC40, FC50, FC60,
FC68, FCC0, FCC8, FC80 and FC90 functions consist only of an x86 function
prologue/epilogue and return. They have no register, memory or control-device
effects. In particular FC60/FC68 do not define real MVTC/MVFC behavior.

Public provenance and probe results are in `se3208_vendor_simulator_probe.json`;
private exact disassembly is `vendor_bin/control_handlers.x86.txt`.
The local COFF symbol table maps FC60 to 0x4067C0 and FC68 to 0x4067D0 in
the hashed simulator. Empty handlers explain why a normal simulator exit
cannot settle the Crystal System cache/control behavior.

New related-ASIC primary documents and CPU transfer evidence are recorded in
SE3208_CONTROL_INTERFACE.md. Remaining device evidence includes VRender0-specific
configuration and a verified implementation/physical observation of the affected registers.
AE32000 documentation uses a different architecture encoding and cannot
silently supply the missing SE3208 peripheral behavior. The real cold-boot
fault at 020820C4/FC65 remains unresolved; this decoder result is not an
attract/gameplay acceptance result. No Quartus or RBF build was performed.
