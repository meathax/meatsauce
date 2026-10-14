# Independent STANDARD FIT review — 2026-10-11

**Recommendation: retain this fit as the current constrained-path baseline, integrate the reviewed core-specific clock-group correction, and continue external I/O qualification. No reset, CPU, video or audio pipeline edit is justified by the new result.** The overall timing/release gate remains open because external endpoints lack constraints.

The investigator independently verified all **108** metadata/report files in the producer manifest `fb9e62a0013236e248a6f4be11f056171755dabe7bfe52cd66ca43689fecfb90`. `standard_fit_independent_review.json` SHA256 `8ffa4f08b5e1c509272259ebddc5b2dc539e70d7b457de238d5934f361d100ba` pins the original eight-corner detailed reports and exact path rows. Native FIT and detailed STA both completed successfully; this review launched no compiler job.

| Check | Minimum slack, ns | Operating condition | Exact path |
| --- | ---: | --- | --- |
| Setup | +0.060 | Slow 1100mV -40C | HDMI OSD `de_out` → VGA/scaler conversion `pb_1r[15]` |
| Hold | +0.074 | Fast 1100mV -40C | Game-clock framework `pll_hdmi_adj.i_delay[13]` → itself |
| Recovery | +3.033 | Slow 1100mV 100C | HDMI scaler `o_reset_na` → `o_readdataack_sync` |
| Removal | +0.291 | Fast 1100mV -40C | HDMI scaler `o_reset_na` → `o_hsp` |
| Same-game setup | +4.066 | Slow 1100mV 100C | T80 `n2098_q[6]` → `n2137_q[9]` |
| Same-audio setup | +14.002 | Slow 1100mV -40C | Framework IIR `inp[6]` → tap `intreg[1][35]` |
| Same-audio hold | +0.165 | Fast 1100mV -40C | Framework `pal_req` → itself |

The +0.060 ns path is a **real same-HDMI-clock path**, not a clock crossing. Its source/destination clock is `pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk`; relationship 6.732 ns, skew -0.096 ns, data delay 6.376 ns. It ends in the existing Pb conversion register. Frozen `sys/vga_out.sv:44` computes `pb_1r <= 32768 - ((red<<5)+(red<<3)+(red<<1))` in its ordinary clocked pipeline. The margin is positive but small. Preserve it as measured; review fresh timing after relevant RTL/constraints/HDMI configuration changes. No broadening to untested runtime HDMI clock profiles or physical-board readiness follows from this nominal fitted image.

## Source and exception integrity

`standard_binding_independent_review.json` SHA256 `238c2bb80494e7ad0ee70deea0fa9dc9635843a5982658595f31fd22f3efa447` independently verifies:

- All **114 HDL assignments** in the flattened QSF have identical source bytes between the failed Fast Fit and successful Standard Fit, including the guarded sound-ROM board override.
- All **161 broader frozen source-file closure** entries match both independent source trees and prepared manifest `476213d608867386bacf71dd4c5832d4d62f05cfb80982714f960cd7460816f5`. The unassigned original board retained in that closure is distinct from the actual assigned guarded board.
- Both original SDC files remain byte-identical. The only QSF changes after workspace rebasing are removal of three FAST effort overrides and one additional SDC assignment.
- The added SDC is byte-identical to the root-reviewed candidate `8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a`.

The overlay restores the missing game boundary using native collection-count guards. Exactly two related outputs—game 48 MHz/0ps and forwarded SDRAM 48 MHz/10416ps—remain together; eight original framework groups each contain one expected active clock. Pairwise asynchronous groups add only game-to-existing-framework exclusions. Existing framework-to-framework exceptions are unchanged. There is no endpoint false path, CE multicycle or reset waiver. Same-game setup/hold and same-game asynchronous-reset recovery remain timed and now pass. The game-to-forwarded-SDRAM relationship remains intact; actual **external SDRAM I/O** setup/hold is still unqualified.

This result combines corrected clock-boundary intent and Standard Fit, so it does not separately measure either change's contribution. It does establish that gameplay/reset latency changes are unnecessary to close the currently constrained paths. Leave the optional cold-reset predictor and audio CE proposal unintegrated.

## Open gates and integration limits

Every corner still reports **zero illegal/unconstrained clocks**, but **20 unconstrained input ports / 30 input paths** and **85 unconstrained output ports / 149 output paths**. These include SDRAM data/command/address and HDMI audio/video interfaces. The external I/O investigator owns device/module/traces, source-synchronous clock alternatives, real delays and legitimate async endpoint classification. Do not replace those requirements with blanket false paths.

The eight-corner positive internal recovery/removal proves the analyzed reset arcs meet timing. It does not prove physical PLL lock behavior, metastability, glitch-free combinational reset generation, all HPS/OSD/DDR/palette bundled-data crossings, full-game replay or hardware qualification. Retain existing synchronous input/reset handling and its finite wrapper evidence; runtime and physical gates stay separate. Reviewed legacy empty-group warning is superseded by the additive core grouping, but all remaining critical warnings must retain explicit review in the release receipt.

Integrate only the reviewed core SDC boundary and its source-bound progress/evidence. Preserve pinned `sys/`, the 48 MHz master/CE schedule and forwarded SDRAM phase. Use the Standard Fit settings for meaningful timing qualification; the original fast placement was routing-dominated. Refit after required future RTL joins, including Super Stingray MCU integration, rather than transferring this image's timing to changed hardware. RBF generation and MiSTer tests remain behind the user's complete simulation, bug, resource, I/O and release gates.
