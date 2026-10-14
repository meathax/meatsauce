# Kyros combat reference and native replay

The first combat derivation removed the dump helper when replacing the input
function. MAME exited 0 but the recorder reported a Lua error at its first
snapshot; that one-field capture is invalid and retained with its exact loaded
Lua. The guarded replacement now stops at the dump declaration and preserves
one copy of the helper. This was a recorder error, not a MAME game bug.

The fresh recording completed 3,600 ordered fields, exit 0, no Lua errors,
with default legal DIPs 142. No game RAM/register patches or fabricated CPU
behavior occur. scripts/record_combat_reference.py binds canonical/derived
source hashes and the executable/port-file hashes in its receipts.

Coin is applied at 120–125, start at 160–165. Movement and the planned
punch/second-button sequence begin at 260 and continue across the introduction.
The primary MAME driver macro verifies Up=1, Down=2, Right=4, Left=8,
Button1=16, Button2=32 and Start=128. A 600-field movement period uses Up for
360 fields, Right for 60, Up for 120, then Left for 60. Button1 is held for
14 of every 18 fields; Button2 is pulsed for four fields every 180 after 480.

Visual observations: field 600 still shows PLAYER-1 READY; 1200 shows combat
and score 200; 2400 score 300; 3000 score 500; 3599 score 800. These establish
real game progression and scoring in the reference. Pickup and jump outcomes
are not yet independently established. Do not infer them merely from inputs.
Official PNG normalization produced 66 canonical 256x224 RGB checkpoints.
Evidence: research/kyros_combat3600_v2_exit.json and normalization receipt.

scripts/run_combat_native.py reuses the verified RTL build, takes a dedicated
executable copy, and runs all 3,600 fields with recorded inputs. Its dac-probe
option is read-only tracing: it records accepted sound-memory writes and PCM,
without modifying CPUs, ROMs, game RAM or reset. The primary driver maps the
Kyros DAC to 0xe004 (Stingray 0xc104). Actual board debug bits distinguish
memory writes from I/O, matching the existing probe filter.

The sound comparator now includes ordered DAC writes when sound_bus_events.csv
exists and explicitly reports unavailable DAC capture otherwise. No missing
DAC trace can support a DAC pass. The first 60 combat RTL fields match 100
chip writes and both DAC writes; no main sound commands occur in that window.
This is finite startup evidence, not combat-effect or full audio qualification.
Worker 133634 / simulation 133636 was confirmed live.
Authoritative terminal: research/kyros_combat3600_native_exit.json.

Pickup research lead: the original World Games instruction manual is at
https://www.crazykong.com/manuals/Kyros.man.pdf . Web PDF screenshots returned
Cache miss; its gameplay content remains unread and no mechanics are inferred
from it. Use primary instructions or observed game outcomes for the remaining
pickup target.

Next: diagnose the reset graphics differences, finish the current native
combat/death/reset runs, compare actual effect/DAC streams and canonical
graphics, then establish the remaining pickup/jump outcomes. Quartus remains
disabled; broad fidelity, Stingray, timing/resources and hardware gates remain.
