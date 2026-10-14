# Independent first-IRQ FX68K source contract review

The actual donor is **FX68K**, not TG68K. The first extra eight master ticks are localized within autovector service, but the retained source and primary manual do not establish a CPU/PCB defect or justify an RTL correction. Keep E phase, IRQ delivery, clock enables and bus termination unchanged.

The primary comparison is the corrected actual MAME VPA consumer (`ee8d02512cfa2123b17589706f7d986e335c4019495dbb0681e28e30f03066f4`) and the old69 native57 compact cause (`42241e6f7f07e770150465b7579dedddbd8459b2b27ae3ea65b94f50e9e16a9d`). These are historical diagnostic epochs, not current43b gameplay qualification. MAME's first actual request is CPU time 5716578, returning 5716590: twelve CPU cycles, with the IACK post-VPA callback at local-machine tick 45732719. The callback is not the request/bus-start event. The new consumer proof supplies the actual request/return phase; older callback-only conclusions remain limited.

Native PC-low AS 45732633 to IACK AS 45732665 takes 32 master ticks, matching MAME's corresponding PC-low callback 45732591 to actual request 45732623 interval. Native IACK AS to SR AS 45732841 takes 176 ticks versus MAME request to SR callback 45732791 taking 168. That is a localized eight-tick difference between those particular endpoint pairs, not a universal IRQ delay. The endpoint types and E-clock origins still differ. A second retained service has zero extra ticks; absent later raw windows and a later divergence prevent inferring a sum of three identical eight-tick IRQ errors.

## Responsible source and physical contracts

Pinned donor `rtl/vendor/fx68k/fx68k.sv` SHA256 `797566aa6c1dfb308d88a458550d55f86e0d023e670ab179cc39f594d9d4f73d`:

- Lines 229-231 sample external VPAn into Vpai on Phi1.
- Lines 468-503 advance Ecounter modulo ten on Phi2, generate six-low/four-high E, assert registered VMA at old counter 3 with address output enabled and sampled VPA active, and release VMA at counter zero on Phi1.
- Line 475 derives xVma at counter 8. Lines 555-558 register iStop on Phi2. Line 2350 holds waitBusCycle until bus completion; line 466 joins that wait into the microclock gate.

The pinned board contract uses `iack = !mas_n && fc0 && fc1 && fc2`, `.VPAn(!iack)`, `.DTACKn(!(bus_done && !iack))`, and Phi1/Phi2 enables at CPU phase 0/4 of the eight-master-tick CPU period. VPA therefore follows actual AS plus FC111 decode, and DTACK stays inactive during VPA autovector service. No board-added VPA register or ordinary RAM completion delay is responsible for this retained interval.

The retained native sequence matches those source stages: IACK AS asserts at 45732665 with counter 3; Phi2 gate 45732669 still sees old Vpai=1 and misses this VMA window; Vpai becomes active at 45732673. The next counter-3 window asserts VMA at 45732749. xVma spans 45732781-789; registered stop/completion releases wClk at 45732793; AS terminates at 45732797, the source's E falling boundary. VMA/Vpai release at 45732801. SR AS begins at 45732841. The observed late stop is not an unexplained extra RAM wait.

Primary source: [NXP-hosted Motorola M68000 User Manual](https://www.nxp.com/docs/en/reference-manual/MC68000UM.pdf), pinned document SHA256 `89b690b1923f8a3cff508567090bcab0bcd07511c2deff8ffa393a08efda18e1`; manual manifest `89b21154749869faa0ea49e07bcca96964363d1690e99dc3eca7003122ed1401`. Section 3.7 gives a free-running ten-processor-clock E period and unspecified power-on E/CLK phase. Appendix B.1 describes phase-sensitive VPA recognition and E synchronization. Visually reviewed Figures B-4/B-5 (retained PDF page 187 image Im31) distinguish best and worst E wait; Figure B-6 (page 189 Im33) retains VMA during an E-synchronized autovector cycle and terminates AS around the E falling boundary with DTACK inactive. Reset section 5.5 establishes no deterministic E-origin alignment to MAME's arithmetic time origin.

## Correction decision and limits

**No minimal RTL correction candidate is physically supported by this evidence.** Sampling external VPAn directly at the missed counter-3 gate would bypass the donor's Phi1 input contract. Advancing the xVma/iStop completion pipeline merely to remove eight ticks risks ending autovector AS before the required E falling boundary. Changing reset counter phase, IRQ delay, or CPU cadence would fit a software-origin trace without establishing the PCB phase. None is approved or staged.

The smallest responsible-layer conclusion is to retain the actual board decode and FX68K sampling/E handshake, and classify the remaining comparison as an unresolved E-phase/event-placement contract. Any future code change requires a demonstrated violation at an equivalent physical recognition/termination event; callback timing or PNG agreement alone is insufficient. The manual establishes the allowable phase-dependent mechanism, not Kyros's actual initial E phase or a unique correspondence between MAME request time and FX68K external AS. No extra run, build, simulation, RTL edit, or phase adjustment was performed for this review.
