#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/build/audioreplay sim/results
python3 scripts/audio_sources.py
if ! verilator --cc --exe --build -j 4 --top-module ZeroTeam_audio --Mdir sim/build/audioreplay \
    --no-timing -Irtl/sound/jtopl -Irtl/sound/jt6295 \
    -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
    -f sim/audio_sources.f "$PWD/sim/audio_replay_main.cpp" \
    -CFLAGS '-std=c++17 -O3' -MAKEFLAGS 'OPT_FAST=-O3' >sim/results/audio-replay-build.log 2>&1; then
    tail -25 sim/results/audio-replay-build.log;exit 1
fi
./sim/build/audioreplay/VZeroTeam_audio "$@"
