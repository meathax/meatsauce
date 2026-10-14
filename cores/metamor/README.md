# Metamorphic Force (Konami GX224) — MiSTer core, build sources

Only the files Quartus reads to build the RBF (Quartus Prime Lite 17.0.2, Cyclone V 5CSEBA6U23I7).
No ROMs, EEPROM dumps, build outputs or test benches.

Build: open `jtviostorm.qpf` (revision `jtviostorm`), run the full flow, then convert the SOF with
`quartus_cpf -c -o bitstream_compression=on jtviostorm.sof Arcade-MetamorphicForce.rbf`.
The RBF must be compressed or the DE10-Nano will not load it. Fitter seed 1 closed timing in all eight corners.
