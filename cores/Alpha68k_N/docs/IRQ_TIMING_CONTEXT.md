# Kyros IRQ context and backdrop phase

Parent831dfcf. Actual read-only native61 probe and exact-clock MAME361 trace
allow four IRQ observations in fields59/60. Complete raw stack write contexts
and vector timestamps are retained in research/kyros_irq59_60_context_comparison.json.

Field59 IRQ1/2 save PC0x854 in native and0x858 in MAME. Both save SR0x2000
at the same stack bases. Field60 IRQ1 saves0x131C in both, IRQ2 saves0x132E
in both; SR and stack bases match. Thus exception data is identical in field60,
while the earlier idle instruction boundary differs. The diagnostic exits1
for the retained unequal field59 frames; none is silently filtered.

Native-minus-MAME first-vector timestamps: field59 levels1/2=-29 ticks,
field60 levels1/2=+131 ticks. Differences in the local PC-low-store to
first-vector interval: -8/-8/+56/-8 ticks respectively. Absolute run
origins are not declared equal; these local interval differences are direct.
The native first-vector ticks all have remainder26 modulo80; MAME has55.
Both primary CPU implementations synchronize VPA/E-clock activity over10
CPU clocks (6MHz CPU,8 master ticks/clock), consistent with that observed
80-tick grid. Source SHA evidence is in kyros_irq59_60_source_grid.json.
This corroborates a synchronization-related investigation, not a proven
initialization/reset-phase error or a physical-board timing diagnosis.

Native/MAME local work-store to backdrop-store interval remains exactly160
master ticks in both, so the offset predates the identified MOVE.B. Its
finite timed background mismatch is still18 pixels; canonical atomic image
difference remains20,835. Do not change CPU frequency, instruction cycles,
IRQ/VPA timing or fit an E-clock offset merely to force matching pictures.
More accurate startup/IRQ phase qualification or board evidence is needed.

Tools: scripts/diagnose_irq_context.py. Its retained exit1 is expected for
the actual field59 difference, not a failed parser or incomplete stack frame.
Next: retain this scoped timing limit and complete remaining graphics/bug
coverage efficiently; first assess actual simulator performance without
altering any game RTL or accepting narrower CPU tests as whole-game proof.
## Manufacturer E-clock phase constraint, 2026-10-10

The [Motorola M68000 User's Manual](https://www.nxp.com/docs/en/reference-manual/MC68000UM.pdf),
section3.7, printed page3-8 (PDF index35), specifies ten CPU clocks per E
period, with six low and four high. Its internal ring counter can start in
any state; a unique E-to-CLK power-up phase is not guaranteed. E runs
independently of MPU bus state. Section6.3.2, printed6-6 (PDF index96), also
describes pending interrupts being recognized between instruction executions.

These primary facts support the period interpretation of the 80-master-tick
grids; they do not make differing grid residues proof of an incorrect CPU
frequency or identify a unique physically required startup phase. They also
do not establish that the field59 saved-PC difference is caused by that phase.
The current board ties both FX68K reset inputs to held_reset and resets its
CPU-enable phase while held; no phase/reset patch has been made on this
evidence. The field60 residual remains open. Further changes require source
and accepted-edge evidence, not a search for a phase that makes pictures fit.

Bounded source/section and local RTL pins are recorded in
`research/mc68000_e_clock_reference.json`. The web tool exposed the
manufacturer PDF text; a separate native download returned HTTP404. No local
PDF bytes/hash or successful datasheet staging is claimed.

## Qualified native E/VPA observer and sampling boundaries, 2026-10-10

The completed `kyros_irq_e_phase61` replay exits0. Its qualification receipt
reports `observer_fidelity_pass=true`: all19 prior native images and the complete
instruction-event byte stream are unchanged. The1523 retained registered-state
rows cover all ten E-counter states; counter changes are8 master ticks apart,
so the observed E period is80 master ticks. This qualifies the read-only observer,
not complete game graphics or B16 closure.

The four retained IRQ1/2 cycles in fields59/60 assert VMA on E3-to4 and deassert
IACK on E9-to0. Their vector-high program-space request acceptance occurs exactly
109 master ticks after IACK deassertion, at E3. Consequently, the E3 vector-high
rows are a later bus boundary; they do not label the IACK synchronization edge.
The complete event table and source excerpts/hashes are retained in
`research/irq_sampling_edge61_evidence.json`, whose paths intentionally point to
the original recovery capture; evidence is not relocated or silently recomputed.

`rtl/alpha68kn_board.sv:262` counts and supplies an accepted bus request.
`sim/system_main.cpp:227` exports the resulting transaction-counter edge and
pre-edge data bus value. The CPU separately latches IRC/DBIN on qualified Phi2
in `rtl/vendor/fx68k/fx68k.sv:1759`; the donor comments at1701 specify external
S7 and internal T4. Therefore the existing instruction-event timestamp and
pre-edge DIN must not be called a completed CPU data sample. This establishes
an observation-boundary distinction; it does not establish the exact callback
versus CPU-latch delta in the MAME comparison.

MAME0.289 `m68000.cpp:103` schedules VPA synchronization in ten-cycle periods,
and its default CPU-space autovectors at211/212 attach that before-time handler
plus a one-cycle after-delay. The ordinary program-space vector-table tap
cannot by itself expose that CPU-space IACK callback or the RTL input latch.
No CPU clock, reset seed, timing constraint, ROM, input or production RTL changed.

B16 remains open: the time-aware field60 residual is still18 pixels and canonical
atomic graphics failures remain recorded. If further timing qualification is
needed, first observe matched MAME CPU-space IACK accesses and native Phi2
input-latch qualification/data using a minimal read-only probe, then compare
corresponding boundaries and relevant backdrop writes. Do not infer or tune an
E-clock startup phase from the E3 vector rows or fit phase to pictures.

## Completed actual latch and matched CPU-space qualification, 2026-10-10

The private `irq_sampling_edge_latch61` native replay and its qualification
worker have actually completed with exit0. Observer fidelity passes all checks:
61 fields, all19 overlapping native images, instruction events, applied inputs
and the E/VPA trace remain exact against the prior observer. The1523 retained
latch rows include64 qualified IRC captures and31 qualified DBIN captures.
The accepted pre-edge Phi2 value is read from the verified complete packed
s_clks typedef, whose last field is enPhi2; its value also matches the observed
unpaused phase4 enable. This is observed donor input-data capture, not an
assumption based on a vector request timestamp.

The matched real MAME61 CPU-space observer also exits0 and passes all12 checks,
including every original reference frame-state column, exact source/executable/
input pins and actual autovectors25/26. It attaches a read-only tap to the
source-confirmed `cpu_space` map atFFFFF0..FFFFFF. Its source and raw capture
remain separate from the ordinary program-space vector-table tap.

For all8 vector-word reads in fields59/60, native board request acceptance is
followed by qualified DBIN samples at+3,+11,+19 master ticks. Registered DTACK
changes1-to0 at the first sample and stays0; every sampled word equals MAME
exactly. No variable additional ROM-DTACK wait is observed in these8 reads.
This finite observation does not qualify all instruction fetches or all ROM
accesses.

Each native IACK-deassertion-to-final-high-vector-latch interval is128 ticks.
Each MAME CPU-space-IACK-tap-to-program-space-high-vector-tap interval is136
ticks. The8-tick interval difference is one6MHz CPU clock and is source-consistent
with `m68000.cpp:115` returning1 in vpa_after and the after_delay attachment
at211/212. The two lanes still have explicitly different observer boundaries;
this does not prove physical edge equivalence or justify changing donor timing.
Absolute MAME program callback minus final native latch is+10 ticks for all
field59 words and-150 for all field60 words. The field60 phase/path divergence
was already present by IACK; it is not introduced by a variable vector-ROM wait.

Evidence: `research/irq_sampling_edge_latch61_verification.json`,
`research/irq_sampling_edge_mame61_verification.json`,
`research/irq_sampling_edge_latch61_boundaries.json` and
`research/irq_sampling_edge_latch61_interpretation.json`. Paths and hashes
retain the original recovery captures. No production RTL, clock, reset seed,
memory or input state changed; no broad new replay was launched.

Limits: normal-cycle ASn is not a separate latch-trace column; attrs4-to7
observes data-strobe release and must not be relabelled an exact ASn edge.
PC/IR observations at board request acceptance are not automatically MAME
semantic instruction dispatch. The existing18-pixel timed field60 residual,
canonical atomic graphics failures and B16 remain open. Any correction needs
an identified relevant instruction/write timing difference and stronger source
or physical evidence; these measurements alone do not select a phase patch.

## Qualified deferred tile writes and matching tap coverage, 2026-10-10

The finite root join passes8 checks and independent review passes20. The frozen
MAME write tap includes positions and tiles over0x40000..0x41fff without excluding
unchanged values;4023 repeated masked-value observations are present. Corrected
comparison contains10606 writes per trace and10598 ordered matches. The earlier
asymmetric selector receipt is not accepted as coverage evidence.

Two field59 writes at0x411b4/0x41506 occur before MAME's IRQ stack writes but after
the native handler interval. ROM0x854 is MOVE.W #$20,(A0)+;0x858 is DBRA. Actual
savedPC is0x854 native versus0x858 MAME. The MOVEM.L D0-D7/A0-A6 prologue and actual
low/high save words establish A0 differs by2. Common subsequent writes have offset
+75 masterticks compared with-21 at the corresponding stack writes:96 ticks of
relative growth in both cases. Two other identical writes at0x406b0/0x406b2 cross
the59/60 field labels. These are observed software-visible ordering differences;
they do not establish which model matches the physical board or select a phase fix.

Evidence: research/irq_deferred_tile_write.json, irq_deferred_tile_write_review.json,
and irq_main_write_alignment_v2.json. B16, the18-pixel time-aware startup residual,
canonical atomic graphics and whole-game acceptance remain open. Next qualification
observes actual IPL/interrupt-recognition boundaries without changing production RTL.

### Actual IRQ recognition and active-noise reset terminals, 2026-10-10

Source parent: 2313e350d9c200c3fa90eb62919c358f5e71517a. The actual private IPL replay exited 0. Its 69 source
pins, all 19 native RGB images and complete inputs/frames/instruction/bus/E/latch
observations match the frozen reference. All 4,745 read-only observer rows follow
the actual fx68k update rules. Six IRQ assertions have five subsequent paired
IACKs; the last field-60 IRQ1 acknowledgement is outside the finite stop. The
original frame-label coverage predicate is preserved and explicitly superseded
by the tick-paired timeline. The corrected verifier was syntax checked, not rerun.
At the two disputed tile writes, actual pending/inl offsets from assertion are
20/24 and 21/33 master ticks. These observations do not establish a physical
cause, justify a phase change, close B16 or prove full graphics acceptance.

The real-CPU active-noise reset replay also exited 0. Noise and channel-B outputs
each made 70 pre-reset transitions, with 362,880 nonzero channel ticks. Reset was
asserted after field 715 for 64 master ticks, followed by 500,000 checked ticks;
held/post channel samples and post-reset AY2 writes are zero. The original
verification's truthy integer precondition is retained; the separate strict
qualification records its Boolean interpretation and authentic terminal checks.
This is finite active-noise reset coverage, not complete B03 or PCM acceptance.

Evidence: research/irq_ipl_recognition61_{import_manifest,timeline,verification}.json
and the reset import manifest/terminal qualification imported in this phase.
Production RTL, ROMs, clocks and constraints are unchanged. Current full-design
mapping is separate; final fitted resources and timing remain pending.

### Diagnostic helper relocation and interrupt boundary source review, 2026-10-10

Source parent: ad6d6800bee52a64c9a0057cc757d0aa9dde2557. Corrected the three imported IPL helpers' fixed-depth
root assumption for scripts/diagnostics. Probe/verifier now use a validated
absolute ALPHA68KN_EVIDENCE_ROOT or the nearest marked project ancestor within
eight levels; repair shares the guarded probe's resolver. Nine staged checks
cover root lookup, invalid overrides, syntax and immutable runtime provenance.
Parent AST inspection confirms probe/repair main routines are guarded; importing
the resolver does not launch a build or replay. Original receipts retain their
actual runtime hashes and capture paths; adapted helper hashes are distinct.
No past verification was rerun or rewritten.

The pinned MAME0.289 and fx68k source comparison passes five finite checks and
finds all 1,024 microcode words equal. MAME snapshots pending interrupts at
IR-to-IRD transfer; the generated MOVE.W destination write precedes that point.
fx68k separately samples/stabilizes IPL and captures pending state at its enabled
group-one boundary. This is a concrete candidate explanation for the observed
pre/post-MOVE ordering, not proof of a defect in either implementation. Exact
MAME pending state and native dispatch remain outside the retained observer;
internal PC and repeated microcode words cannot uniquely identify dispatch.
Do not use this review to justify a clock/phase adjustment or close B16.

Evidence: research/irq_ipl_recognition61_adapted_import_manifest.json,
irq_ipl_recognition61_adaptation_review.json, irq_mame_fx68k_boundary_review.json;
integration provenance: research/completed_ipl_helper_adaptation.json.
Production RTL/QSF/SDC/ROMs are unchanged; current fitted resource/timing and
all-game acceptance remain pending.
