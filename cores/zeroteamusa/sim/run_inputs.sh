#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root=${ZERO_SIM_BUILD_ROOT:-sim/build}
if [[ -z ${ZERO_SIM_BUILD_ROOT:-} && -d /mnt/r/Verilator ]]; then build_root=/mnt/r/Verilator/ZeroTeam; fi
build_dir="$build_root/inputs"
mkdir -p "$build_dir" sim/results
if ! verilator --cc --exe --build -j 4 --top-module zero_inputs_top --Mdir "$build_dir" \
  --no-timing -Wno-fatal -CFLAGS '-std=c++17 -O2' \
  rtl/ZeroTeam_inputs.sv sim/zero_inputs_top.sv "$PWD/sim/inputs_main.cpp" \
  >sim/results/inputs-build.log 2>&1; then
    tail -30 sim/results/inputs-build.log
    exit 1
fi
"$build_dir/Vzero_inputs_top"
