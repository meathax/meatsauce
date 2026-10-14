#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/build/av sim/results
python3 scripts/board_sources.py
python3 scripts/audio_sources.py
if ! verilator --cc --exe --build -j 4 --top-module zero_av_top --Mdir sim/build/av \
  --no-timing --savable -Irtl/ucore -Irtl/sound/jtopl -Irtl/sound/jt6295 -DCE_HALF_PLUS2 -DREADY_FIXED_HIGH -DCE_STALL_ON \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
  -f sim/board_sources.f -f sim/audio_sources.f rtl/Raiden2/Raiden2_video_timing.sv \
  rtl/Raiden2/Raiden2_text_renderer.sv rtl/Raiden2/Raiden2_tile_layer.sv \
  rtl/Raiden2/Raiden2_sprite_renderer.sv rtl/Raiden2/spram_dp.sv \
  rtl/Raiden2/tile_rom_arbiter.sv rtl/Raiden2/raiden2_mixer.sv \
  rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv \
  rtl/ZeroTeam_video.sv sim/zero_av_top.sv "$PWD/sim/board_main.cpp" \
  -CFLAGS '-std=c++17 -O3 -DFULL_VIDEO' -MAKEFLAGS 'OPT_FAST=-O3' >sim/results/av-build.log 2>&1; then
    tail -30 sim/results/av-build.log
    exit 1
fi
python3 scripts/snapshot_av_sources.py "$@"
if [[ ${ZERO_SIM_BUILD_ONLY:-0} == 1 ]]; then
    echo 'Built and stamped immutable AV model; no simulation requested.'
    exit 0
fi
python3 scripts/validate_av_resume.py "$@"
./sim/build/av/Vzero_av_top "$@"
