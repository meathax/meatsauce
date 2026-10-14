# Hardware facts and evidence boundaries

The project name is Nintendo8080; its folder remains the user-selected `sherrif`. It needs several substantially different board profiles, not one universal PCB.

| Profile | Main CPU | Graphics/memory | Sound | Primary source |
|---|---|---|---|---|
| TSF-derived Sheriff/Space Fever/HiSplitter/Space Launcher | 8080A, 20.160 MHz / 10 | CPU-driven 1-bit bitmap, PROM/color-control variants; CPU ROM `0000-3fff`, RAM `4000-7fff` | 8035 6 MHz, 1 KiB program ROM; one-bit DAC and SN76477 with monostables | `n8080.cpp`, `n8080_a.cpp`, `n8080_a.h` |
| HeliFire extension | Same main CPU | Bitmap plus color RAM `c000-dfff`, sea/sky/stars/flash | Distinct sound board: 8035 **5 MHz**, 8-bit DAC and envelope | Same driver, `helifire_state` / `helifire_sound_device` |
| Computer Othello, COG CPU | M58710S, 8080A equivalent; 3.579545 MHz crystal; MAME underclock workaround | 256-byte work RAM, 512-byte one-bit DRAM framebuffer, M58741P TV interface/HOLD arbitration | Beeper and independent seven-segment timer | `cothello.cpp` |
| Block Fever, TBF-CPU | NEC D8085AC; 6.144 MHz oscillator, CPU internally divides by two | 512-byte work SRAM, 512-byte tile RAM, PROM graphics, ball X/Y registers, ADC0800 and I/O latches | Discrete circuitry; MAME fixed beeper approximation | `blockfvr.cpp` |

Sheriff raster is 320x256 total at 5.040 MHz; active 256x224 before ROT270. Do not copy Space Invaders IRQ scanlines or Western Gun Part II's different guessed frame timing. IRQ scanlines 128/240 and vectors CF/D7 are explicitly configured in this driver.

The TSF source's pictured sound board includes 8035, 6 MHz oscillator, 2708 EPROM, 74123 monostables, 74275 latches, 7405 inversion, SN76477 and three volume controls. Its main board lists eight 4116 DRAM packages. These notes describe the photographed Space Fever boards, **not a complete independently verified Sheriff BOM**. The logical memory map is more reliable for initial implementation than copying a possibly misleading per-package capacity comment.

Block Fever's driver supplies a much fuller package inventory: M5L2078S/M58732S EPROMs; UPB8212 ports; D8085AC; M3624 PROMs; M58723P/D2111AL SRAMs; ADC0800PN; LS125/10/74/04/00/139/194/124/175/93/86/266/14/107/164/08/03 glue; SN74121 mono; MB434/MC14086B parts; LM380 amplifier and connectors. These become functional RAM/latch/counter/decode/analog-model blocks in `donormap.md`; exact unspecified connections remain schematic questions.

No EEPROM, Yamaha/AY PSG, sprite ASIC, separate GPU or high-bandwidth graphics ROM is identified for Sheriff. Do not stage unrelated chip implementations simply to increase the donor count. Workload and memory size fit a simple BRAM board architecture; actual device utilization remains unmeasured until the first real fit.

Primary data is the local MAME 0.289 source snapshots and verified dumps. `mamebug.md` identifies where the source itself admits uncertainty. Manuals/PCB measurements must close those uncertainties before claiming a physical correction. A functional MAME implementation does not supply all DRAM arbitration, analog component behavior or TTL wiring automatically.
