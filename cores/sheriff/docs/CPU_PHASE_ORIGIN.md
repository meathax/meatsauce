# Initial CPU phase and timing projection

Observation: the fresh three-field MAME capture fetches PC0 at time0. The saved
native model first raises SYNC at tick52 and DBIN at77; its established
bus-derived T1 tag is50. The first five ordered opcode fetches retain about a
50-master-clock difference. These are different timing observables, not proof
that a physical instruction begins at tick50.

Evidence: `docs/evidence/sheriff_reset_startup.json` pins both actual exit0
receipts, unchanged observer prefixes and the saved model's CPU/harness source
hashes. A source-derived reset-gate model matches all78 recorded SYNC/DBIN
samples through first DBIN. Of25 possible release phases, only phase7 matches
that trace. It agrees with the harness's18,432 ROM-load clocks plus1,000 reset
clocks modulo25. This model covers settled RESET, READY high, HOLD low and
inactive instruction-end/halt/IRQ start terms before first opcode execution.

Hypotheses: an incorrect CPU startup sequence, a reference timing-origin
assumption, or incorrect IRQ sampling could explain a leading epoch gap. The
initial observations and gate model support a timing-origin difference. They
do not establish an incorrect donor reset sequence.

Intel's September1975 8080 user's manual, printed page2-15, Figure2-13, shows
internal RESET recognition and a recovery interval before first M1. It is
consistent with delayed first fetch. It does not specify the Sheriff's
absolute CPU-to-raster origin. The original manufacturer scan is retained
locally under `_checks/manuals/`; its URL/hash/page are in the evidence report.

Selected explanation for the **projection error**: the native tag precedes
SYNC by2 master ticks and sits at counter phase7. The adapter's phi2 gate is
active at phases8 through19. Thus its final sampling edge is12 ticks after the
tag's final-cycle boundary. Earlier reports used19 as that offset, which
incorrectly treated the tag as phase0. The source-model phi1 rise for first M1
is43; observed SYNC/DBIN are52/77. Neither that phi1 rise nor the tag is a
physical PCB measurement.

Smallest change: correct the field66 report's calculated final phi2 from
edge+19 toedge+12. Recorded DBIN, ACK, stack data/timestamps, ISA cycle counts
and the synthesizable RTL remain as captured. Historical +19 tag-offset
projection claims in earlier IRQ evidence/notes are superseded by this audit;
their measured bus events remain evidence. Do not use those derived values
as physical phase qualification or rerun a completed replay to repair a label.

Verification: the source model matches the78 existing native pin samples and
uniquely identifies phase7. The field66 recorder must preserve native RST
tag+25, ACK+27 and stack writes+194/+269 while projecting final phi2+12. No
reference time offset, raster adjustment or graphics tolerance is applied.

Regression scope: reset-gate and field66 observation/projection only. Complete
RTL/MAME lockstep equivalence, physical propagation/READY/DRAM/serializer
timing, current display RTL, audio and final fit/STA/resources are open. The
field2760 pixel remains a failure. No RBF was built.

Known unknowns: exact Sheriff clock/reset wiring applicability, physical reset
release and raster origin, electrical delays and clock rounding, and the
subsequent IRQ/instruction-order changes before field2758. Preserve those
unknowns rather than shifting MAME time to the native tag.
