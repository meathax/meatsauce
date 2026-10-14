#!/usr/bin/env bash
# Output-chain bench (native, forced scandoubler, CRT Adjust sweeps) through the real sys arcade_video
# and crt_adjust. Run in Ubuntu WSL; Verilator output goes to the R: RAM disk.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${CRT_BENCH_BUILD:-/mnt/r/Verilator/zero-crt-bench}
rm -rf "$build"; mkdir -p "$build" sim/results
# sys/arcade_video.v leaves video_mixer.HDMI_FREEZE unconnected (GND in Quartus); tie it low for simulation.
sed "s/\.gamma_bus(gamma_bus),/.gamma_bus(gamma_bus), .HDMI_FREEZE(1'b0),/" sys/arcade_video.v > "$build/arcade_video_sim.v"
verilator --binary --timing -Wno-fatal -Wno-PROCASSWIRE -Wno-BLKANDNBLK -Wno-WIDTH -Wno-PINMISSING \
  -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -DSIMULATION --Mdir "$build" --top-module tbc \
  "$build/arcade_video_sim.v" sys/video_mixer.sv sys/video_freezer.sv sys/gamma_corr.sv sys/scandoubler.v \
  sys/hq2x.sv sys/math.sv sim/video_chain/sync_fix.sv sys/video_cleaner.sv sys/scanlines.v \
  rtl/Raiden2/Raiden2_video_timing.sv rtl/Raiden2/crt_adjust.sv sim/video_chain/crt_bench.sv \
  > sim/results/crt-bench-build.log 2>&1 || { grep -E "%Error" sim/results/crt-bench-build.log | head -8; exit 1; }
"$build/Vtbc" | grep CFG | tee sim/results/crt-bench.txt
