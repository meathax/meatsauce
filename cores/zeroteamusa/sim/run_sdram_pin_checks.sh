#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
name=${ZERO_SDRAM_CHECK_TAG:-baseline}
source=${ZERO_SDRAM_CHECK_SOURCE:-rtl/sdram.sv}
build="/mnt/r/Verilator/zero-sdram-pin-$name"
mkdir -p "$build" sim/results
verilator --cc --exe --build -j 4 --top-module zero_sdram_checks \
    --Mdir "$build" --no-timing -DSIMULATION -Wno-fatal \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    "$source" sim/zero_sdram_checks.sv "$PWD/sim/sdram_pin_checks.cpp" \
    -CFLAGS '-std=c++17 -O2' >"sim/results/sdram-pin-$name-build.log" 2>&1
# Include forwarded-clock/input-pad returns, with a latest-arrival and
# earliest-disable profile. Physical min/max pin timing is qualified by STA.
{
    "$build/Vzero_sdram_checks" 8000 5000
    "$build/Vzero_sdram_checks" 13000 4500
    # A model omitting pad/clock returns must not approve this phase.
    if "$build/Vzero_sdram_checks" 6000 3000 >"sim/results/sdram-pin-$name-zero-pad.log"; then
        echo 'SDRAM zero-pad model unexpectedly passed' >&2
        exit 1
    else
        result=$?
        if [[ $result -ne 2 ]]; then exit "$result"; fi
    fi
    echo 'SDRAM zero-pad model rejected at the valid-window assertion as expected'
} | tee "sim/results/sdram-pin-$name-run.log"
