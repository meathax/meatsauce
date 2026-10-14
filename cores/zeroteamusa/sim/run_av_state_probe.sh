#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime=$(verilator -V | awk '$1=="VERILATOR_ROOT" && $2=="=" {print $3;exit}')
test -n "$runtime"
model_dir=${AV_PROBE_MODEL_DIR:-sim/build/av}
# Link to the already-built real model; do not regenerate RTL or touch its executable.
g++ -std=c++17 -O2 -pthread -I"$model_dir" -I"$runtime/include" -I"$runtime/include/vltstd" \
  sim/av_state_probe.cpp "$model_dir/Vzero_av_top__ALL.a" \
  "$model_dir"/verilated*.o -o "$model_dir/av_state_probe"
"$model_dir/av_state_probe" "$@"
