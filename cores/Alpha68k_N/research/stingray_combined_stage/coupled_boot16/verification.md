# Actual private Super Stingray coupled boot diagnostic

Build and bounded16-field run both exited0 using the same ELF and real68000/Z80/T48. Source/ROM/legalinput pins and compiled-copy hashes are retained in verification.json. Canonical hardware and the preferred P6 candidate remained unchanged.

Observed 0 accepted MCU commands, 0 shared writes, 7 IRQ2 pulses, 13 firmware control events and 0 firmware BUS events. The initial CPU/MCU command exchange is not complete within this bound.

The retained MAME executable, source, recorder and ROM identities match. CPU command taps omit direct MCU control/HALT/shared-write ordering, and no separate historical process-exit receipt remains. This evidence establishes only the recorded finite behavior; it does not qualify physical timing, paired MCU ordering, attract/gameplay or graphics.
