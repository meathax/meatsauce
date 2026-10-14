#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_root="$(mktemp -d /tmp/alpha68kn-soundchips.XXXXXX)"
mkdir -p sim/build
printf '%s\n' "$build_root" > sim/build/wsl_soundchips_build_dir.txt
sha256sum rtl/alpha68kn_soundchips.sv rtl/vendor/jt12/hdl/*.v \
    rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    sim/soundchips_main.cpp > sim/build/soundchips_inputs.sha256
cp rtl/alpha68kn_soundchips.sv rtl/vendor/jt12/hdl/*.v \
    rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    sim/soundchips_main.cpp "$build_root/"
cd "$build_root"
version="$(/usr/local/bin/verilator --version)"
case "$version" in 'Verilator 5.050 '*) ;; *) printf 'Unqualified simulator: %s\n' "$version" >&2; exit 2 ;; esac
/usr/local/bin/verilator --cc --exe --build -j 4 -O3 --assert --no-assert-case -Wno-fatal \
    --top-module alpha68kn_soundchips --Mdir obj -o alpha68kn_soundchips_sim \
    alpha68kn_soundchips.sv ./*.v "$build_root/soundchips_main.cpp" -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_soundchips_sim "$workspace/sim/build/"
