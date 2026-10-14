# Independent deferred tile-write review

All20 finite checks passed. In matching fields59/60 and actual mapped work/sprite ranges, both captures contain10606 writes;10598 match in order. The seven remaining unequal blocks contain four saved-stack values, two relocated tile writes and two identical position writes crossing a field label. The original broader comparison is retained with its selector asymmetry explicitly disqualified.

The pinned loaded MAME Lua records every write callback in0x40000–0x41fff, labels0x40000–0x407ff as positions and the remainder tilesN, and does not suppress unchanged values. Omitting positions from a comparison was a selector gap. Exact source/map lines and actual capture terminal pins are in the JSON.

At0x854 the real ROM disassembles as MOVE.W #$20,(A0)+;0x858 is DBRA D0,$854. At IRQ1/IRQ2 in field59, MAME records writes0x411b4/0x41506 before its exception stack; native records those same writes after its handler. Native saved PC is854, MAME858, and observed handler low-pointer stores differ by−2. The next shared writes0x411b6/0x41508 have native-minus-MAME offset+75ticks; corresponding stack writes have−21ticks. Relative offset growth is96ticks in each case.

This qualifies finite software-visible ordering and journal coverage. It does not establish instruction dispatch-edge equivalence, physical IRQ timing, a96tick hardware fault, a phase correction or B16 closure. B16, timing-fix and whole-game acceptance remain false.

The actual ROM prologue at0x45c is MOVEM.L D0-D7/A0-A6,-(A7). With exception stack base0x20ff2, its predecrement order places A0 at0x20fd6/0x20fd8. Both observed traces save the low word first and the high word32master ticks later. Captured high and low words confirm native A0=0x411b4/0x41506 and MAME A0=0x411b6/0x41508, a−2 difference in each IRQ case.
