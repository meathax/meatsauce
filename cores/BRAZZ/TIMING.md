# Timing and resource log

Parsed from `output_files/CrystalSystem.fit.rpt` / `.sta.summary` / `docs/production_timing.json` of each production fit (`scripts/check_production.py --fit`, seed 1, Quartus 17.0.2). Pass = every setup/hold slack >= 0 in all four corners, 0 unconstrained, main clock (`emu|pll general[0]`, 85.909 MHz) setup >= +0.2 ns, all chart resource hard limits met.

| date | commit | snapshot | worst setup / hold (ns) | main clk setup | ALM | LAB | peak / avg interconnect | M10K | mem bits | DSP | result | change |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-06 | e48f589 | 1791239461195686100 | +0.038 / +0.037 | n/a | 80% | 97% | 76.7% / 43.7% | 26% | 19% | 56% | timing pass, LAB over limit | SDRAM 2-cycle DQ capture, HDMI clk 4 mA |
| 2026-10-06 | 3e70fac | 1791283596070130600 | -1.908 / +0.083 | n/a | 67% | 94% | 63.8% / 34.7% | 27% | 19% | 58% | FAIL (SDRAM output setup, LAB) | cache tags + palette to M10K, single clock capture |
| 2026-10-06 | 7d9a5c0 | 1791285517603036800 | -0.075 / +0.070 | n/a | 68% | 93% | 59.1% / 35.1% | 27% | 19% | 58% | FAIL (ascal -0.075, LAB) | SDRAM pins launched on posedge, dense packing |
| 2026-10-07 | 712b53c | 1791289486041396500 | +0.050 / +0.073 | +0.348 | 56% | 82% | 53.1% / 26.6% | 36% | 20% | 58% | **PASS, all limits met** | SPU MMIO-only registers to M10K |

Final fit worst paths: setup +0.050 ns HDMI output (slow -40C, `hdmi_out_d[7]`->`HDMI_TX_D[7]`, provisional board bounds), `cs_hdmi_scaled` +0.148, `pll_hdmi` +0.203, main clock +0.348, `cs_sdram_clk` +2.618; hold min +0.073 (framework `ascal` register pairs). Unconstrained ports/paths 0. Release RBF `releases/Arcade-CrystalSystem_20261007.rbf` sha256 `7d23887f6022cab81aed9d940d20ad2f6e39706db038a4aefc5dd853cb40efe7`, assembled with `quartus_asm` from that exact fitted snapshot.

| 2026-10-07 | 74c6f36 | 1791322120181500500 | main +0.611 / ascal -0.039 (framework, slow -40C) | n/a | 56% | 82% | 52.0% / 26.8% | 36% | 20% | 61% | FAIL (framework ascal) | multiplier operand stage, SEED 2 |
| 2026-10-07 | 4b0fb87 | 1791324334241782600 | +0.589 / +0.139 | +0.148 hdmi | 56% | 81% | 60.9% / 28.7% | 36% | 20% | 61% | PASS | FITTER_EFFORT AUTO FIT |
| 2026-10-07 | 3c1e3f1* | 1791335809463198900 | main -0.033 (nvram_written_q arbiter path) | n/a | 56% | 82% | n/a | 36% | 20% | 61% | FAIL | fallback HSYNC aligned to game (344..378) |
| 2026-10-07 | rc3 | 1791337908659030700 | main -0.107 (cp0 rsp -> decoder -> operand_a) / framework osd -0.019 | n/a | 56% | 82% | n/a | 36% | 20% | 61% | FAIL | nvram event register stage |
| 2026-10-07 | 07513c0 | 1791339814688169300 | main +0.376 / hold min +0.141 (pll_hdmi); cs_hdmi_scaled +0.140 | recovery +3.885, removal +0.832, min pulse +0.529; 0 unconstrained | 56% | 82% | 53.4% / 26.7% | 36% | 20% | 61% | **PASS** (TIMING/AUDIT/INTERNAL) | fetch operands selected from opcode bits; release RBF d52d8ee4 |
| 2026-10-07 | e8ed542 | 1791359966151910500 | framework ascal -0.012 (slow corner) | n/a | 57% | 82% | n/a | 37% | 20% | 61% | FAIL (framework) | SDRAM byte masks on A12/A11 (boot-hang fix) |
| 2026-10-07 | f36ed6d | 1791363094699739100 | main +0.504 / hold min +0.246; worst setup +0.142 (cs_hdmi_scaled) | recovery +2.315, removal +1.121, min pulse +0.529; 0 unconstrained | 57% | 82% | 47.0%/47.0%/68.7% / 28.2% | 37% | 20% | 61% | **PASS** (seed 3; framework ascal path is placement-sensitive) | release RBF 8202bfab, fast DDR3 load + boot-hang fix |
| 2026-10-07 | 81f0186 | 1791367395037539800 | main +0.772 / hold min +0.146; worst setup +0.146 | recovery +3.329, removal +1.157, min pulse +0.529; 0 unconstrained | 57% | 82% | 49.6% | 37% | 20% | 61% | **PASS** | sync-flip display fix; release RBF f0f9aaca |
| 2026-10-08 | 5e5e49e | 1791375258576220400 | main +0.465 / hold min +0.239; worst setup +0.134 | recovery +3.948, removal +1.052, min pulse +0.529; 0 unconstrained | 58% | 84% | 55.4% / 28.6% | 38% | 20% | 61% | **PASS** | GPU line-burst memory path (speed fix); release RBF f44a94f7 |
| 2026-10-08 | 4f2a81a | 1791415309202631300 | main setup +0.149 (slow 100C) / +0.060 (slow -40C, HDMI out); internal +0.160 min; hold min +0.115 | recovery +3.002, removal +0.963, min pulse +0.529; 0 unconstrained | 63% | 41% | n/a | 41% | 23% | 61% | PASS (bar lowered to 0 ns by user) | CPU/GPU/scanout speed work; RBF 261008 sha256 8f40bdf7 |
| 2026-10-08 | (this commit) | 1791429467845351200 | main setup +0.160 (slow 100C) / +0.071 (slow -40C, HDMI out); internal min +0.240; hold min +0.071 | recovery +4.120, removal +1.156, min pulse +0.529; 0 unconstrained | 62% | 41% | n/a | 41% | 23% | 61% | PASS | display scanout line bursts (black-line fix); GPU s12 hold fix; RBF 20261008b sha256 767e6ad2 |
| 2026-10-08 | (this commit) | 1791436843886694500 | main setup +0.162 (slow 100C) / +0.072 (slow -40C, HDMI out); internal min +0.305; hold min +0.078 | 0 unconstrained | 64% | 41% | n/a | 41% | 23% | 63% | PASS | OSD Volume boost, CRT H/V position; no RBF |
