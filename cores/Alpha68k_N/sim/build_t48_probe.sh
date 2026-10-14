#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_root="$(mktemp -d /mnt/d/vibes/fpga/temp/alpha68kn-t48.XXXXXX)"
mkdir -p sim/build
printf '%s\n' "$build_root" > sim/build/wsl_t48_probe_build_dir.txt
sha256sum rtl/alpha68kn_mcu.sv rtl/vendor/t48/t48_core.v sim/t48_probe_top.sv sim/t48_probe_main.cpp > sim/build/t48_probe_inputs.sha256
cp rtl/alpha68kn_mcu.sv rtl/vendor/t48/t48_core.v sim/t48_probe_top.sv sim/t48_probe_main.cpp "$build_root/"
cd "$build_root"
/usr/local/bin/verilator --cc --exe --build -j 4 --top-module t48_probe_top --assert --no-assert-case -Wno-fatal -O3 -CFLAGS "-O3" alpha68kn_mcu.sv t48_core.v t48_probe_top.sv t48_probe_main.cpp
cp obj_dir/Vt48_probe_top "$workspace/sim/build/alpha68kn_t48_probe"
