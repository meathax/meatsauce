# Private MAME interrupt-cutoff observation

This is a source overlay and build plan, not a completed MAME observation. The official pinned 61-field reference remains authoritative. No existing custom exporter/build receipt is available, and its debugger entries cannot expose pending/next state.

The private overlay exports seven internal values through `.readonly()` debugger entries and logs immediately before/after the existing IR-to-IRD snapshot, plus input application. Sampling only at a Lua memory tap or frame boundary would still miss the execution cutoff. Both CPU local time and machine time are retained because scheduler coordinates are not interchangeable. The two narrow windows must actually contain both assertions and bracketing cutoffs; otherwise the probe fails coverage.

Create a separate complete source copy, apply `observer.patch`, regenerate the four handler variants using the commands in the JSON, and freeze every compiled source before the one minimal-driver build. The local GCC16.1/Make4.4.1 tools exist and answered version commands; dependency/link readiness remains untested. Official build instructions support the driver subset command in the JSON. The original source tree and live RTL4401 remain untouched.

After a successful private build, clone the qualified recorder into a separate capture namespace, preserve its first61 legal inputs/profile/ROMs, and use the newly pinned executable with `-log`. Require the existing state, frame and bus-event parity before interpreting internal records. Retain the actual absolute ticks and source distinctions. Native cutoff evidence is already direct; MAME cutoff runtime and physical PCB fidelity remain unknown. No CPU/clock patch or B16 closure follows from this preparation.

Sources: [MAME0.289 build documentation](https://docs.mamedev.org/initialsetup/compilingmame.html), [official Windows toolchain](https://www.mamedev.org/tools/). Exact local hashes and executable/recorder receipts are in `observer_build_plan.json`.
