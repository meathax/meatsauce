#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build="/mnt/r/Verilator/zero-cop-sort"
mkdir -p "$build" sim/results
if ! verilator --cc --exe --build -j 4 --top-module zero_cop_math_top --Mdir "$build" \
    --no-timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    rtl/common/savestate.sv rtl/common/savestate_ram.sv \
    rtl/Raiden2/raiden2_addr_main.sv rtl/Raiden2/Raiden2_cop3.sv sim/zero_cop_math_top.sv "$PWD/sim/cop_sort_main.cpp" \
    -CFLAGS '-std=c++17 -O3' >sim/results/cop-sort-build.log 2>&1; then
    tail -25 sim/results/cop-sort-build.log;exit 1
fi
"$build/Vzero_cop_math_top" "$@"
