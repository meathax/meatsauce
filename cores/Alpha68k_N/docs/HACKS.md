# Explicit fidelity limits

## Kyros MCU compatibility mode (B09)

The initial RTL implements MAME 0.289's named Kyros MCU compatibility model rather
than executing original Alpha8511 firmware. It handles ID 0x12, coin identifiers
0x22/0x22, command-triggered shared-RAM updates, distinct coinage tables and flip
writes at word offset 0x2d. Reads return zero while updating shared RAM once per
completed main-CPU transaction. The full bootleg dump remains an optional firmware
candidate; the partial original dump is BAD_DUMP and missing zero-page ROM.

No original-firmware or physical MCU timing claim follows from a MAME-compatible
result. B10/B12/B13/B14/B15 retain the compatibility dispositions and evidence
limits in `mamebug.md`. Missing physical information does not authorize a guessed
correction or create an endless research gate for the MAME-compatible scope.

## Integrated Stingray compatibility boundary

The integrated profile2 path executes the authentic 1024-byte 8748 firmware rather than the Kyros compatibility callbacks. The T48 port observation fork exports architectural P2 write data because delayed physical pins lose the ready transition. Prior genuine-firmware component evidence does not establish current whole-game acceptance. MCU oscillator frequency, original PCB timing, analog audio and undocumented hardware remain explicit fidelity limits; no guessed PCB correction is claimed.

The fx68k HALT pin is a single-step input. The board drains an accepted AS transaction, then holds its existing phase enables at AS-high while the MCU owns HALT. The physical/MAME timing equivalence of this boundary remains subject to coupled CPU evidence. No synthetic CPU/game action is added.

The shared YM2203 SSG period-zero correction changes all profiles and requires final-source replay binding. It is not covered by the profile0/1 board-cone equivalence claim.

Finite current limits: B01/B02 fixture requirements are qualified; actual CPU lifecycle remains separate. B04 pickup and B16 timed18-pixel/phase divergence remain open. Japan raw8 endpoint differences are explained as retired stack without closing control/timing; Stingray12-byte RAM and complete181/1800 lifecycle remain unresolved. No masks, synthetic game behavior, blanket timing exceptions or hardware qualification are inferred from those explanations.
