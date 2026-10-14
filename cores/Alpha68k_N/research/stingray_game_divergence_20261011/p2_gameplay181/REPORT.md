# Super Stingray P2 gameplay181 qualification

The one genuine CPU/Z80/8748 run exited0. All15 current source/protocol checks pass with native verifier exit0. All75 frozen source files and all70 files compiled by the reviewed native recipe match their pins; CRT/PLL are retained in the frozen source graph and intentionally absent from this native recipe. Only the two reviewed P2 integration files change functional RTL. The World/Japan MCU cone remains held in reset and excluded from CPU pause, RAM, IRQ and flip behavior.

Full completed MAME RGB at frames0,30,90,119,179 is byte-exact, with no offsets or masks. All five strip RAM checkpoints are exact. Work RAM is exact at0/30/90; frame119 retains5 differing bytes and179 retains7, all listed in strict_work_differences.json. These remain an open rawRAM gate without an inferred stack/cutoff cause.

The main CPU consumes coinage01 at matchedPC5274 in field122 and start128 atPC4208 in field162, matching actual official MAME consumption. All38 MCU command tuples match MAME in order. Together with exact completed gameplay frame179 this qualifies the finite credit/start/gameplay sequence. The original1800-row preparedCSV was used; its first181 rows match all applied fields. Callback-derived shifted input remains an unpromoted hypothesis.

Actual audio captures146792 samples at48kHz,0 clipped samples, with406 YM,70 AY1 and656 AY2 writes. MAME audio fidelity is a separate open gate. A15/15 protocol result does not qualify1800, timing/resources, external IO or hardware.

Two readonly consumer failures are preserved: an incorrect181row assertion against the unchanged1800row inputCSV, and a compiled-set assertion that included the native-unused CRT/PLL files. Verificationv2/protocolv3 correct only these consumers and run no simulation. Source, ELF, admission and inputs remain frozen. The sole build/run and final readonly verifier exits are authentic0.
