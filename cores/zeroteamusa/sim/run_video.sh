#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root=${ZERO_SIM_BUILD_ROOT:-sim/build}
if [[ -z ${ZERO_SIM_BUILD_ROOT:-} && -d /mnt/r/Verilator ]]; then build_root=/mnt/r/Verilator/ZeroTeam; fi
build_dir="$build_root/video"
mkdir -p "$build_dir" sim/results
python3 scripts/video_fixture.py
if ! verilator --cc --exe --build -j 4 --top-module zero_video_top --Mdir "$build_dir" \
  --no-timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING \
  rtl/Raiden2/Raiden2_video_timing.sv rtl/Raiden2/Raiden2_text_renderer.sv \
  rtl/Raiden2/Raiden2_tile_layer.sv rtl/Raiden2/Raiden2_sprite_renderer.sv \
  rtl/Raiden2/spram_dp.sv rtl/Raiden2/tile_rom_arbiter.sv rtl/Raiden2/raiden2_mixer.sv \
  rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv \
  rtl/ZeroTeam_video.sv sim/zero_video_top.sv "$PWD/sim/video_main.cpp" \
  -CFLAGS '-std=c++17 -O2' >sim/results/video-build.log 2>&1; then
    tail -30 sim/results/video-build.log
    exit 1
fi
"$build_dir/Vzero_video_top" "$@"
