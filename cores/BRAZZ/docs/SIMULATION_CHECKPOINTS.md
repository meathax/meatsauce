# Native simulation checkpoints

`host_checkpoint` uses the same synthesizable board as `host_boot`, with Verilator's full model serializer. Production architectural state loading stays disabled. It preserves physical SDRAM/DDR contents and command timing, pending transactions, shadow/reference state, observer frames and cabinet sequence/release state. ROM bytes and snapshots stay in private ignored directories.

Build and run once, optionally taking periodic checkpoints:

```powershell
$env:CS_CHECKPOINT_AT='100000000'
$env:CS_CHECKPOINT_PERIOD='100000000'
python -X utf8 scripts/sim.py host_checkpoint 9000000000 0 50000000
```

Each checkpoint is published under the printed run directory's `checkpoints/<next_clock>` only after both files and their manifest are complete. The stored clock is the next iteration to execute. `CS_CHECKPOINT_STOP_AT` saves at the specified next clock and returns successfully as a diagnostic, without declaring game acceptance. A `.partial` directory is incomplete and cannot be used.

Resume the same compiled target, retaining the original cold-boot evidence:

```powershell
$env:CS_CHECKPOINT_RESTORE='sim/obj_dir/boot_probe/activity/<run>/checkpoints/<clock>'
Remove-Item Env:CS_CHECKPOINT_AT -ErrorAction SilentlyContinue
Remove-Item Env:CS_CHECKPOINT_PERIOD -ErrorAction SilentlyContinue
Remove-Item Env:CS_CHECKPOINT_STOP_AT -ErrorAction SilentlyContinue
python -X utf8 scripts/sim.py host_checkpoint --run-only 9000000000 0 50000000
```

The resumed process gets a new activity directory and cabinet command file. Cabinet sequence numbers and any pending release are retained; use a greater sequence for a new command. File paths/log streams are recreated rather than restoring host pointers. ROM transfer is skipped only after a complete checkpoint passes its schema, exact source/build-parameter/ROM identity and file-integrity checks. The independent CPU/readback checks continue. `--run-only` also rejects source or build-parameter changes. Remove `CS_CHECKPOINT_RESTORE` before a new cold boot.

The first qualified pair saves at clock 123,456 and compares uninterrupted and resumed execution at 456,789. Both complete state files are byte-identical after 333,333 further clocks; see [checkpoint_continuation.json](checkpoint_continuation.json). This is early BIOS evidence with no owned bus token at the initial fence. In-flight, audio, attract and gameplay checkpoints still need a continuation comparison before acceptance use. Checkpoints from changed RTL are incompatible; never transplant only architectural CPU/RAM state. Keep a separate final cold-boot route with realistic physical memory timing.

Native Windows Verilator 5.050 opens save/restore descriptors without `O_BINARY`. The checkpoint target sets the native C runtime's default binary mode before opening them; otherwise LF expansion and DOS EOF handling corrupt the stream. Other simulation targets and the installed toolchain are unchanged.


## Timed registered-pin board diagnostic (2026-10-06)

`host_timed_checkpoint` selects `SDRAM_REGISTERED_IO=1` and shares the exact chronological SDRAM helper with `sdram_registered`. Set `CS_SDRAM_TIMING_PROFILE` to the fitted snapshot's `sdram_io_probe/profiles.txt` and `CS_SDRAM_TIMING_PROFILE_NAME` to one of its eight rows. The file SHA/name enters checkpoint and run identity; source/config/profile changes invalidate restore. The existing `CS_CHECKPOINT_AT`, `CS_CHECKPOINT_STOP_AT` and `CS_CHECKPOINT_RESTORE` controls apply. Use `scripts/sim.py host_timed_checkpoint --run-only` only with its matching source/profile build. Genuine host image transfers and complete physical DDR readback still run on cold start.

The archive adds queued nanosecond SDRAM returns, retained DQ and absolute pin-cycle position. The diagnostic accepted/replied memory tail is serialized field-by-field, avoiding uninitialized struct padding. Sound MMIO logs remain private run artifacts. No simulated CPU or memory state is substituted during cold boot.

`docs/timed_checkpoint_continuation.json` records a 123456→456789 early-boot restore that is byte-identical to uninterrupted RTL and complete external state (112861761 bytes). Both saved endpoints had an empty DQ queue. The selected earliest return endpoint works, but the source fit fails latest setup endpoints; this diagnostic is not physical closure or game acceptance. Real pending-DQ, sound, attract and gameplay checkpoints remain to qualify at a closed physical profile.


Current production capture-clock update: `host_timed_checkpoint` now also selects `SDRAM_PHASED_CAPTURE=1` and requires `CS_SDRAM_CAPTURE_PHASE_NS`, taken from the completed fit's `sdram_io_probe/pll_waveforms.txt`/`capture_phase_ns`. The native pin helper drives the capture input at this phase. The phase enters checkpoint identity; the prior unphased continuation proof remains historical. A nominal phase tested against old profiles is prospective, not physical signoff.

## Phased pending-return continuation (2026-10-06)
`host_timed_checkpoint` drives the production capture-clock port, using the chosen fit's profile file, profile name and measured `CS_SDRAM_CAPTURE_PHASE_NS`; these join source/ROM/build identity. `CS_CHECKPOINT_PENDING_DQ=1` defers scheduled saves/stop fences until the physical return queue is nonempty. The actual saved clock may be later than the requested fence. This diagnostic option neither writes memory nor changes RTL execution. Clear it for ordinary fixed fences.
Cold run1791219259193475900 used corner0_input_setup and measured3.175 ns from fit1791216411949065600. Full71487643-clock ROM load/readback passed. At123979 and200408, two SDRAM return beats were pending. Restore run1791219320931693300 starts from123979 and continues76429 clocks to200408; complete RTL, external state and manifest are byte-identical to uninterrupted execution. See `timed_phased_pending_continuation.json` and cold/resume reports for exact handles/hashes. This qualifies pending memory continuation on this exact source; audio/attract/gameplay continuation and formal production timing remain unqualified. The source fit fails setup, despite the functional endpoint tests. Preserve a separate final qualified cold boot.

The scanout observer now archives complete/current per-pixel FIFO source-base vectors and counts. `scanout_complete_fifo_sources.u32le` names actual committed FIFO byte offsets for the word emitted by each ordered pixel; 0xffffffff means the output was blank/not armed/not ready and has no proved memory source. These observer changes invalidate prior checkpoint identities. The transient pre-edge source snapshot is recomputed from restored RTL before every clock; it is not transplanted state. RGB/coordinates are checked against the actual pending word on emission. Full game acceptance still requires paired current-source native frames and qualified physical timing.
