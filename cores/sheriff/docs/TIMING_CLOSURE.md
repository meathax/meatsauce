# Sheriff timing closure

Retained production 66f53ed9 passes all seven resource limits but fails
all-corner setup at -0.008 ns in Slow 1100mV -40C. The real failing scaler
path is ascal:ascal|o_hacc_next[2] to ascal:ascal|o_hacc_next[13], on the
148.5 MHz HDMI clock (6.732 ns relationship, 6.432 ns data delay, -0.108 ns skew).
No game-clock change, false path or sys/ modification is supported by that failure.

The existing placement experiment changes only QSF SEED 1 to 2 and reuses
baseline synthesis. Its 564 source inputs and 483 model inputs are manifest-bound.
GENERATE_RBF_FILE stays OFF. Its source and receipts are retained at
D:/Arcade/AI/aCORES/meatsauce/cores/sheriff/_checks/agent-platform-seed2-66f53ed9-20261010.
This historical canonical directory differs from the present workspace, which
has no Git metadata. A copied baseline fit summary does not establish trial
completion: its actual fit.json exit receipt is required before consuming the
routed database.

The read-only tools/observe_timing_trial.py verifies source inputs and actual
receipts without launching or interrupting Quartus. Its first observation is
D:/Arcade/AI/aCORES/sherrif/_checks/timing-trial-observation-20261010/observed.json.
At identification the live fitter was PID 66160, with PowerShell parent PID 27712,
whose command writes fit.json after the actual fitter exits. Other jobs remain untouched.

The user stopped work on 2026-10-10. The owned fitter was terminated before qualification; `_checks/stop-request-20261010.json` records its identity and successful stop. The trial remains incomplete and must not be consumed as a passing fit. No further compiler stages were launched.

If the user later resumes this trial, first obtain a successful actual fit receipt, then collect all eight operating conditions and
use tools/timing_corner_gate.py. Complete numeric setup, hold, recovery,
removal and minimum pulse width must be nonnegative, and all seven measured
resource limits must pass. Successful process exits alone are insufficient.
Historical trial closure applies only to its pinned production source; changes
to final production RTL require fresh qualification.

The retained docs/PLATFORM_IO_REVIEW.md explains all 114 unconstrained external
path rows, with no unexplained synchronous Sheriff CPU/RAM/video endpoints and
all 12 reported clocks constrained. Real external HDMI/audio/expander and other
interface budgets and inherited CDC exceptions remain unqualified. No invented
external delay or blanket exception is introduced.

## Actual trial outcome

The existing SEED2 fitter ended with actual exit -1 at2026-10-10T05:41:25Z.
Its log ends after routing and timing analysis, without a final success/failure
summary; stderr is empty. Its output fit summary/report timestamps04:35Z
predate the04:56Z launch and remain copied baseline artifacts. No trialSTA
or timing pass follows. The user-requested termination is established by `_checks/stop-request-20261010.json` (owned PID66160 stopped at05:41:23Z). Preserve the incomplete trial;
combine the next placement attempt with changed production source checks.
Numeric external requirements and inheritedCDC limits are documented in
TIMING_EXTERNAL_INTERFACES.md; no constraints orRTL were weakened.
