#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/build/crypt sim/results
python3 scripts/cipher_reference.py
if ! verilator --cc --exe --build -j 4 --top-module zero_crypt_top --Mdir sim/build/crypt \
  --no-timing -Wno-fatal -Wno-TIMESCALEMOD \
  rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv sim/zero_crypt_top.sv "$PWD/sim/crypt_main.cpp" \
  -CFLAGS "-std=c++20 -O2 -I$PWD/sim -I$PWD/sim/results" >sim/results/cipher-build.log 2>&1; then
    tail -25 sim/results/cipher-build.log
    exit 1
fi
./sim/build/crypt/Vzero_crypt_top
