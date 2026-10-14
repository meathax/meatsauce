# Real 8748 integration boundary
MAME0.289 alpha68k_n.cpp:301..358/configuration is the source for this interface.
T48 is pinned at jtcores548b87b32a1b528a16cb41f689accb179e85d1a8, with original
copyright/license in rtl/vendor/t48/LICENSE.upstream and hashes in SOURCE.json.
The two extra output ports expose actual enabled decoder BUS/P2 write strobes,
including repeated identical writes. Removing only these observations restores
the donor logic exactly after newline normalization.

Both clock inputs use the48MHz master. A fractional9263750Hz oscillator enable
feeds xtal_en; the donor xtal3 output enables its five-state machine cycle.
There is no additional divide15 or generated clock domain. The oscillator
frequency follows MAME; physical timer accuracy remains uncertain (B10).
64-byte RAM has six-bit addressing and registered reads, as in t8048_notri.
It is retained on reset. Synchronous program data covers the internal1KiB ROM;
addresses outside that region are unmapped external program space.

Main commands latch address/data/read mode. P1 reads the address; P2 input bit3
represents read mode. T0/T1 use active-low coins. Output control bit4 enables
IRQ/HALT and clears/releases when low; bit5 requests main IRQ2; bit6 low writes
shared RAM low-byte; bit7 is inverted flip. Output pins are sampled one master
tick after their real donor register writes. Main IRQ2 HOLD/IACK and work-RAM
arbitration must be integrated at the board boundary.

## Finite firmware probe — 2026-10-10
Real staged1024-byte firmware; Verilator5.050;3,500,000 master cycles.
Build and run exited0.675481 oscillator enables match the exact fractional
count;225160 Clock-State enables equal divide3. Firmware executed internally
without external-ROM accesses, emitted2 BUS and10 control writes, wrote shared
RAM once and requested IRQ2 three times. The first read command halted at
tick480000 and firmware released at483604; its shared response was62.
The second command arrived with IRQ/HALT disabled and did not create another
halt. All these are actual firmware execution, not scripted MCU responses.
Evidence: research/t48_probe_job.json, t48_probe_exit.json,
t48_probe_result.json, t48_probe_events.csv, t48_probe_inputs.sha256 and
mcu_and_reset_phase_verification.json. ROM/ELF hashes are in the job/exit records.

The external commands/coin edges are artificial probe inputs. This is neither
paired MAME handshake validation nor real68000/Z80/Stingray attract/gameplay.
The wrapper is not enabled in the production board/files.qip. Kyros remains
first; production integration follows its qualification.
