# Connected color-control correction

Related Bandido sheets33/34 are the physical source; source PNGs are5088x6600. Exact original-coordinate viewboxes/hashes are in `docs/evidence/sheriff_color_control_trace.json`. This supersedes the narrow-viewport interpretation; Sheriff board revision and electrical timing remain conditional.

| Origin | Connected destination |
|---|---|
| OUT6 2D Q0(2), Q1(5), Q2(7) | 3D LS158 1A(2), 2A(5), 3A(11) |
| OUT6 2D Q3(10), Q4(12) | 4C A(13), B(3) |
| 4C Y3_n(12) | Both4E NAND4/5; output6 ->3D ST15 |
| 4C Y2_n(11) | Sheet34 4F NAND1 |
| 3L O4(11) | Same4F NAND2; output3 ->3K D2(5) |
| 3K nQ2(6) | Return continuation ->sheet33 4F NAND13 |
| 4C Y2_n(11),Y1_n(10) | 4E NAND1/2; output3 ->4F12 |
| 4F output11,4C Y0_n(9) | 4E NAND10/9; output8 ->3D S1 |
| 3L O1(14),O2(13),O3(12) | 3K D4(13),D1(4),D3(12) |
| 3K nQ4(14),nQ1(3),nQ3(11) | 3D 1B(3),2B(6),3B(10) |

The4C enables are grounded and1C high. Primary [TI SDLS057](https://www.ti.com/lit/ds/symlink/sn74ls155a.pdf) defines positive B:A selection and active-low decoder outputs. For mode=OUT6 Q4:Q3, Yk_n=NOT(mode==k):

```
D2 = NOT(O4 AND Y2_n)
nQ2 = held(O4 AND Y2_n)
4E3 = NOT(Y2_n AND Y1_n)
4F11 = NOT(4E3 AND nQ2)
S = NOT(4F11 AND Y0_n)
ST = NOT(Y3_n AND Y3_n)
```

Thus S=mode0 OR ((mode1 OR mode2) AND held_nQ2), ST=mode3. Same-mode capture gives PROM for mode0; conditional O4 selection for mode1; inverted OUT6 color for mode2; white for mode3. Sheet34 `[2100,2850,3220,3290]` decisively shows NAND3 returning to3K D2; `[2870,2870,3450,4200]` shows three independent A descents. Sheet33 `[4240,4780,5088,6000]` contains the decoder/gate chain. Adjacent continuations preserve wire order; crossed lines are not assigned a junction.

Local MAME0.289 is monolithic `D:/Arcade/AI/mame289/src/mame/nintendo/n8080.cpp`; the guessed `_v.cpp` is absent. Lines349–360 give mode bits3/4, color bits0–2 and bit0-R/bit1-G/bit2-B. Lines486–518 apply PROM color, bit3 conditional override, complemented forced color and white. Lines1384–1385 identify1024-byte `82s137.3l`, CRC820f8cdd/SHA1 197eeb008c140558e7c1ab2b2bd0f6a27096877c. Source hash/excerpts are retained; ROM bytes are absent.

Dump bits0/1/2/3 associated with O1/O2/O3/O4 make all64 stable PROM/mode cases match. This is a functional inference, not independent electrical/programmer pin-order proof. Exact Sheriff revision, CPU-to-WDO timing/polarity bridge, capture propagation, power-up and CRT amplitude remain limits. Dynamic mode changes retain the sampled fourth-output condition; MAME's instantaneous rule does not justify removing it.
