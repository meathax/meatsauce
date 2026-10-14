# Independent bank43b STANDARD fit review

Accept this exact frozen graph for its **timed fit and seven resource gates**. Keep overall timing/release acceptance open because external I/O constraints and the documented physical CDC assumptions remain unresolved. No further internal clock exception, reset waiver, CE multicycle constraint, clock-frequency change or pipeline edit is justified by these reports.

Producer manifest: `../joined_rom_inference_v2/fit_sta_evidence/fit_sta_import_manifest.json`, SHA256 `cff90bd44f912151aea1770d0d67f5b610c6d1af8811b165f442e83351c26d30`. Independent review: `bank43b_independent_review.json`, SHA256 `3601435db68fcec180d972bb1b8ee023123acaadf46f61db10d56371d1de4541`. The reviewer checked 440 report/source records including the native 160-file closure, origin 161-file closure, effective QSF `029436ac2cc7a389bd9b0bae4f2d89fef205a7318d0ff5abc5f988a5d254be5a`, all three assigned SDCs, and the reviewed additive game-group SDC `8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a`. The effective check project has GENERATE_RBF_FILE OFF. The fitted banked board source is `43b8c6e7600e4c4089f0d3c0e4a15637be8bfcbdd626ddd0bc0e222b7b1553ce`.

All 64 exported setup/hold/recovery/removal and same-game/audio tables are positive across eight operating conditions. Native FIT and STA both terminated with actual exit 0. Worst slacks in ns:

| Check | Worst slack |
|---|---:|
| Global setup | +0.341 |
| Global hold | +0.076 |
| Recovery | +4.114 |
| Removal | +0.341 |
| Same-game setup / hold | +4.585 / +0.082 |
| Same-audio setup / hold | +14.630 / +0.120 |
| Native minimum pulse width | +1.041 |

The tightest setup path is `ascal:ascal|o_v_poly_t.g0[17]` to `ascal:ascal|o_v_poly_pix.g[2]`, both on the HDMI generated clock, Slow 1100 mV -40 C. `all-corners/corner_2/setup.txt:23` reports 6.732 ns relationship, -0.579 ns skew and 5.612 ns data delay. The tightest hold path is `ascal|o_poly_lum1[0]` to `ascal|o_poly_lerp_tb[0]~_Duplicate_2` at Fast -40 C. These remain real timed same-domain paths; they are not hidden by asynchronous exceptions.

| Resource | Fitted use | User cap |
|---|---:|---:|
| ALMs | 43.760% | 80% |
| Occupied LABs | 69.721% | 90% |
| M10K | 60.579% | 90% |
| Block bits | 43.632% | 85% |
| DSP | 36.607% | 90% |
| Average interconnect | 17.0% | 60% |
| Peak interconnect | 33.7% | 85% |

All eight native clock-inventory reports and all eight inherited-group reports are byte-identical to the previous accepted STANDARD baseline. The 41 matched assigned framework source files also retain exact bytes. Both related 48 MHz game/forwarded-SDRAM outputs remain in one group; the separate HDMI/audio/framework boundaries are retained. There is no new internal unconstrained-clock omission. As before, zero illegal/unconstrained clocks and no internal-UCP table do not qualify paths excluded by clock groups; the structural CDC and physical limits in `standard_ucp_cdc_findings.md` still apply.

The unconstrained census remains **20 input ports / 30 input paths and 85 output ports / 149 output paths**. Input ports, output ports and input-path tuples are exactly unchanged. Of the output tuples, 38 old tuples are replaced by 38 new tuples: 32 refer to representative fitted DQ driver/enable nodes on the same 16 SDRAM_DQ pads, five to the same LED[0] sink, and one to the duplicated SPDIF output register on SDCD_SPDIF. No pad class or clock domain was added. The exact before/after tuples are frozen in the independent review and supplement; these changed fitted source representatives do not solve any external delay gap. SDRAM controller/gfxmem source bytes are checked separately in the final closure supplement.

The FIT warning code/count delta is **zero**, with no critical FIT warning. The inherited unmatched game-group warnings 332054/332174 persist in the immutable original sys_top.sdc; the reviewed additive overlay supplies the missing actual-clock boundary without changing sys/. Warnings for incomplete I/O (15714), fixed enables (169064), invalid or unmatched fitter/fast-I/O assignments (171167/176250/176251/20013), PLL compensation/LOCKED wiring (177007/21300), and unavailable LogicLock licensing (292013) remain inherited review items, not new bank-ROM errors. Native custom STA reports 1264 warnings and explicitly says setup/hold are not fully constrained; successful process exit does not override that open I/O gate.

The prior external profile gaps remain: installed SDRAM/module and trace/loading bounds, HDMI selected clock master and inverted DDIO pad clock/skew, I2S/MCLK/USER sink profiles, HPS I2C controller timing, MCP supported clock rate, and VGA/SD multiplexed operating profiles. Do not mask these with zero-delay assignments or broad false paths.

This review ran no compiler job and changed no canonical RTL, framework, constraints or release outputs. Parent/final_source_join owns the mapping from the frozen compiled graph to canonical commit 6caf, including the reported MCU/T48/SSG newline normalization; this report does not substitute for that source-epoch integration proof or current-image gameplay/graphics/hardware gates.

Reviewer recovery notes: the first local verification attempt rejected trailing `-qip` text in a flattened SDC assignment; the parser was corrected to read the first quoted path. A second attempt looked for the prior FIT report at a guessed location; it was corrected to the pinned prior manifest path. Both failed before emitting the independent review. Capsule later reported EPERM during supplement execution despite creating its immutable output; a repeated direct check hit the intended preserve-existing assertion. The final freeze verifies the supplement's content and pins without overwriting it. These local tooling receipts do not change either producer's actual native FIT/STA exit status.
