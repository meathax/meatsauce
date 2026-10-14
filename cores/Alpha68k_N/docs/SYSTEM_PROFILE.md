# Actual system simulation profile

Parent revision e99e548. Five real Kyros fields use the same DUT, staged ROM,
legal input stream, Verilator 5.050 generation options and GCC -O3 as the
native instruction observer. The valid v4 run adds compiler-only GNU gprof
instrumentation. Its 15 RGB/RAM assets and frame counters matched the native
baseline before the host-loop experiment.

The sampled flat profile assigns 27.55%, 26.03% and 10.29% to generated
`nba_sequent__TOP__2`, `__0` and `__1`, respectively. These are generated
function partitions, not independently qualified chip bottlenecks. The full
profile is in the ignored capture
`sim/captures/diagnostics/kyros_system_profile5_v4/gprof.txt`; its source/build
receipt is under `research/kyros_system_profile5_v4_*`.

## Invalid attempts and verified cause

Attempts 1, 2 and 3 ran the ELF in an isolated capture working directory
without fx68k's relative `microrom.mem` and `nanorom.mem`. Startup logs explicitly
reported `$readmem file not found`; the CPU issued zero transactions. They are
invalid CPU samples. Early hypotheses about profiling generation flags and
neutral input initialization did not establish the cause. The
`research/*profile5*runtime_rom_failure.json` receipts retain the actual cause.

The launcher now stages and hashes both microcode files before executing the
ELF. The native harness fails before DUT construction when either is missing
or empty. Explicit initialization of all unused pause/rotation/hiscore host
inputs is retained independently; it did not resolve the missing-ROM failures.

## Host evaluation experiment

The falling-edge `eval()` already settles the model. The behavioral SDRAM
then drives its sole input, `sdram_dq`. The second `eval()` is now conditional
on that input changing. Every falling and rising master-clock edge, SDRAM
sample and game action remains present. This changes host evaluation overhead
only; game RTL and clock generation are unchanged.

Attempt 5 uses the same compiler instrumentation and isolated runtime assets.
`scripts/verify_system_profile.py` compares attempts 4 and 5 with the prior
native CPU capture: all five RGB/RAM assets, frame/state counters, accepted
bus and audio events, legal inputs and PCM prefix. Its durable result is
`research/system_profile_pair_verification.json`. Adoption requires that
receipt to pass. Later gameplay fidelity is not established by five boot
fields. A single pair of instrumented wall times does not establish a general
performance gain.

## Qualified result

Both attempts 4 and 5 completed with exit zero. The paired verifier passed
every comparison, including 15 frame assets, all first-five-field bus/audio
events and the complete captured PCM prefix. Instrumented simulation wall
times were 28.105947 s and 17.783467 s, respectively. This single observed
pair supports retaining the redundant-evaluation removal, with the scope
limits above. No FPGA timing or resource result follows from this host change.

Capsule `stats` and `gain` were each attempted once after verification; the
tool-budget hook withheld both calls. No context or tool-cost savings are
claimed.

## Native 61-field qualification

After commit a0ad21d, `scripts/run_system_equivalence61.py` rebuilt the normal
uninstrumented ELF and executed 61 actual Kyros fields with the recorded
legal port stream. Exit0; all 61 fields have 57,344 unique pixels and zero
duplicates, unmapped accesses, deadline misses or row overflows. All 57
baseline frame assets and complete frame/state, accepted bus, epoch,
instruction and audio event files match byte for byte, as do the full WAV,
audio statistics, legal input log and final sprite/work RAM.

Receipt: `research/kyros_system_equivalence61_verification.json`; actual ELF
SHA256 `03c331692e0329865833b84f03869053dc014ff642993c089c74a23fe8f80885`.
The ELF and microcode copies are retained in the ignored capture directory
`sim/captures/rtl/kyros_system_equivalence61`; source inputs and worker/build/
exit receipts are retained under `research/kyros_system_equivalence61_*`.
Simulation wall time was 120.852041 s. This extends equivalence through the
retained field59 IRQ context and field60 backdrop transition. Existing MAME
differences are preserved, not fixed or waived. Longer gameplay and FPGA
timing/resource qualification remain separate requirements.
