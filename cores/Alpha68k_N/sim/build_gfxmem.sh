#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_root="$(mktemp -d /tmp/alpha68kn-gfxmem.XXXXXX)"
mkdir -p sim/build
printf '%s\n' "$build_root" > sim/build/wsl_gfxmem_build_dir.txt
sha256sum rtl/alpha68kn_gfxmem.sv rtl/vendor/jtframe_sdram/*.v sim/gfxmem_main.cpp > sim/build/gfxmem_inputs.sha256
cp rtl/alpha68kn_gfxmem.sv rtl/vendor/jtframe_sdram/*.v sim/gfxmem_main.cpp "$build_root/"
cd "$build_root"
/usr/local/bin/verilator --cc --exe --build -j 4 -O3 --assert -Wno-fatal \
    --top-module alpha68kn_gfxmem --Mdir obj -o alpha68kn_gfxmem_sim \
    alpha68kn_gfxmem.sv jtframe_sdram64*.v "$build_root/gfxmem_main.cpp" \
    -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_gfxmem_sim "$workspace/sim/build/"
