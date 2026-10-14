#!/usr/bin/env bash
# Actual-RTL check of the 48 kHz output path: run the isolated sound model for
# 96M clocks (1 s), then compare out_l against an ideal band-limited resample of
# the native-rate mix. Run in Ubuntu WSL; Verilator output goes to the R: RAM disk.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${AUDIO48_BUILD:-/mnt/r/Verilator/zero-audio48}
mkdir -p "$build" sim/results
python3 scripts/audio_sources.py
verilator --cc --exe --build -j 4 --top-module ZeroTeam_audio --Mdir "$build" \
    --no-timing -Irtl/sound/jtopl -Irtl/sound/jt6295 \
    -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
    -f sim/audio_sources.f "$PWD/sim/audio48_main.cpp" \
    -CFLAGS '-std=c++17 -O2' >sim/results/audio48-build.log 2>&1 || { tail -30 sim/results/audio48-build.log; exit 1; }
"$build/VZeroTeam_audio" 96000000
echo "Now run (Windows Python with numpy+scipy): python scripts/check_audio48.py"
