# SE3208 final-reply hand-off

The aligned bus adapter previously registered every completed reply in RESULT before the CPU could consume it. A reply arriving on an enabled CPU edge therefore incurred an additional hand-off delay even though its data was already valid.

The adapter now presents the final reply directly to the waiting CPU. If the CPU does not consume that edge, RESULT retains the full data/error until it does. The first successful beat of a crossing access still collects its bytes and issues the second request. An error on either beat completes with the same visible error. Reset clears all held state. Request sequencing, real memory accesses and the production clock/CE remain unchanged.

| Changed-path check | Previous clocks | New clocks | Result |
|---|---:|---:|---|
| Independent CPU | 4,778,800 | 4,471,122 | 239,536 comparisons, 62,048 encodings, 1,210 IRQ/NMI cases; reset, delays/backpressure, unaligned accesses, visible bus fault |
| CP transport | 9,665 | 8,854 | All 64 canonical transfers; 128 success / 64 device-error cases; held/immediate/delayed replies, paused CE, reset |

The isolated CPU workload uses about 6.44% fewer clocks. Its 383,670 physical requests include the bench's next-fetch cancellation between isolated cases; this is not an original-game throughput or physical timing claim.

The integrated production-state-loading-disabled diagnostic also passes: 4,788 matched CPU instructions; 26 sound MMIO / eight SPU reads; all 24 independently checked stereo outputs; both IRQ2 entries/returns and channel acknowledgements; live DIP reads; all three main-RAM alias snapshots; 1,760 scanout reads with no fault/deadline miss. Cache activity is 4,773 hits / 44 misses, with two CP transfers and CPU-stored CR6 status 80A04B01.

Evidence is in `simulation_cpu.json`, `simulation_cpu_control.json` and `simulation_bios_sound.json`. The concurrently running original-ROM complete-frame model was compiled before this adapter change; its result must retain that older source qualification. Original-game performance, realistic memory timing and the complete gameplay gate still need verification.

The hand-off-only reports above are source-qualified in commit `aee5c87`. Latest reports subsequently include ALU execution-edge retirement: 4,346,038 CPU clocks / 383,668 requests, 8,402 CP-transport clocks, and 4,847 integrated diagnostic CPU comparisons / 4,832 cache hits. All the same acceptance conditions pass. Together, these two changes use about 9.05% fewer isolated CPU-test clocks than the earlier fetch-launch revision; this still does not establish original-game physical speed.

An ALU operation commits its actual result/status/extension state and may retire/launch the next sequential halfword fetch on that execution edge. Eligibility uses its updated interrupt-enable flag, including enable/disable instructions. Pending IRQ/NMI retains the existing stack/vector path. Memory, branches, stack and CP operations retain their existing completion paths. The next fetch is a real bus transaction at the architectural boundary, with normal backpressure; no instruction or interrupt is skipped.
