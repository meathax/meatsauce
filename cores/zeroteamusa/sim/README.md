# Simulation

Use Ubuntu WSL to compile and run Linux executables:

```powershell
wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\zero\sim --exec make cpu-run
```

The initial CPU probe runs the real pinned V30 `ucore` and its demultiplexed
bus adapter against the US program image. It checks actual reset-vector
fetches, instruction addresses and work-RAM writes with explicit memory
latency. Unknown devices are recorded as open bus. This proves the CPU seam,
not working protection, video, sound, attract or gameplay. The next stage
adds those real board blocks to the same simulation infrastructure.

External ROM waits freeze the CPU CE, matching the integrated donor's
contract; READY alone is insufficient for that adapter's early read sample.
Internal work RAM uses a two-system-cycle read latency. Keep this distinction
when extending the harness to the actual SDRAM toggle request/acknowledge path.

Do not run `sim/build/**/V*` from Windows PowerShell. They are Linux ELF
programs. Simulation results and binaries are ignored by Git; source and
small checkpoint/evidence descriptions are tracked.

`bash sim/run_video.sh` renders the saved actual RTL boot buffers through
the real text/tile/sprite engines, ROM arbiter and target mixer. This isolated
fixture verifies graphics without repeating CPU startup. Its graphics memory
responses preserve the donor bus packing: tile/text `{first_LE16,second_LE16}`,
sprite native LE32. `scripts/analyze_video.py` converts the captured RGB file
and compares it against the pristine MAME frame-60 logo. Full CPU-driven
video and later scenes remain separate gates.

The next seam, `bash sim/run_board.sh [system_cycles]` from the repository
root in Ubuntu WSL, compiles the actual V30/COP/CRTC/main-memory hierarchy.
It supplies latency-aware ROM transactions and raw 512×282 timing at 8 MHz
pixels. Its audio input is still open bus and its renderer outputs are
inspected as DMA buffers; this is not yet the full audiovisual board model.
Ignored `sim/results/board-*.bin` snapshots expose actual RTL memory without
injecting state. `scripts/record_board.py` saves hashes and explicit limits.
