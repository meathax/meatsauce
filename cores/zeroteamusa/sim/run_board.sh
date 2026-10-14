#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/results sim/build/board
python3 scripts/board_sources.py
if ! verilator --cc --exe --build -j 4 --top-module zero_board_top \
  --Mdir sim/build/board --no-timing -Irtl/ucore \
  -DCE_HALF_PLUS2 -DREADY_FIXED_HIGH -DCE_STALL_ON \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
  -f sim/board_sources.f "$PWD/sim/board_main.cpp" \
  -CFLAGS '-std=c++17 -O2' >sim/results/board-build.log 2>&1; then
    tail -35 sim/results/board-build.log
    exit 1
fi
./sim/build/board/Vzero_board_top "$@"
