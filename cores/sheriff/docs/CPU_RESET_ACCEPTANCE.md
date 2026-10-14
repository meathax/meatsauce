# Physical 8080 reset acceptance

Intel1975 Figure2-13 (printed2-15/PDF28) shows external RESET deassertion before a phi1, internal reset clearing at that following phi1, one recovery cycle Tn+i, then first M1T1 at the next phi1. SYNC rises in phi2 of T1 and DBIN in phi2 of T2. RESET must span at least three clock cycles. The figure supports this ordered recovery; it does not specify a universal two-T-state interval from arbitrary external release to a bus-derived tag.

Reuse the completed78-pin-sample reset model: release phase7 uniquely matches among25 phases. The next source phi1 is18 master clocks later; one25-clock recovery cycle puts first M1phi1 at+43. Its rounded phi2 starts at+51, and recorded SYNC is+52/DBIN+77. The established tag isSYNC-2 orDBIN-27, hence+50. That tag is counterphase7, not a physical firstM1phi1 edge. The apparent50-clock gap combines release-phase wait, recovery, phi2 publication and observation semantics.

The vm80a source buffers RESET on f1 then f2 (rtl/n8080_vm80a_ce.v:207-208). Recovery/start and state gating use t953, t1f1 and reset (:405,:430,:444); SYNC/DBIN publication uses the phase-gated intermediates (:260-263). This is an implementation of recovery ordering. Its internal reset node clears under f2, whereas the manufacturer's illustrative internal node is drawn at phi1; internal names alone cannot establish silicon equivalence or a pin timing fault.

MAME's PC0 callback at virtualtime0 does not represent these reset/pin recovery states. The source delay is compatible with the primary diagram at the retained synthetic phase7; neither a donor defect, a MAME defect, nor an offset correction follows. The field66 returnPC0ff3 versus0fef negative remains, as do exact physical reset phase, AC aperture/output delay, CPU/raster origin and connected READY-service qualification.

Evidence: docs/evidence/sheriff_cpu_reset_acceptance.json. Primary scan SHA d5982f96536b1dbecbeff409d2370970638716296dce7b318624d86221597a9e; selected text and inspected full-page PNG are retained in _checks/agent-cpu-reset-acceptance-20261010/. No new native run or RTL/clock/raster/IRQ adjustment was made.
