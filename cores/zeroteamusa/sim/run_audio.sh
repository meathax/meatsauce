#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/build/audio sim/results
python3 scripts/audio_sources.py
if ! verilator --cc --exe --build -j 4 --top-module ZeroTeam_audio --Mdir sim/build/audio \
    --no-timing -Irtl/sound/jtopl -Irtl/sound/jt6295 \
    -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
    -f sim/audio_sources.f "$PWD/sim/audio_main.cpp" \
    -CFLAGS '-std=c++17 -O2' >sim/results/audio-build.log 2>&1; then
    tail -35 sim/results/audio-build.log
    exit 1
fi
./sim/build/audio/VZeroTeam_audio "$@"
