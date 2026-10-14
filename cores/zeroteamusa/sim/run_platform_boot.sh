#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root=${ZERO_SIM_BUILD_ROOT:-sim/build}
if [[ -z ${ZERO_SIM_BUILD_ROOT:-} && -d /mnt/r/Verilator ]]; then build_root=/mnt/r/Verilator/ZeroTeam; fi
build_dir="$build_root/platform-boot"
mkdir -p "$build_dir" sim/results
python3 scripts/board_sources.py
if ! verilator --cc --exe --build -j 4 --top-module zero_platform_boot --Mdir "$build_dir" \
  --no-timing -Irtl/ucore -DCE_HALF_PLUS2 -DREADY_FIXED_HIGH -DCE_STALL_ON \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
  -f sim/board_sources.f rtl/Raiden2/Raiden2_video_timing.sv rtl/ZeroTeam_rom_bridge.sv \
  sim/zero_platform_boot.sv "$PWD/sim/platform_boot.cpp" \
  -CFLAGS '-std=c++17 -O3' >sim/results/platform-boot-build.log 2>&1; then
  tail -30 sim/results/platform-boot-build.log
  exit 1
fi
"$build_dir/Vzero_platform_boot"
