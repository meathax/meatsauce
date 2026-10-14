#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_space="${ALPHA_BUILD_TMP:-/tmp}"
mkdir -p "$build_space"
build_root="$(mktemp -d "$build_space/alpha68kn-system-profile.XXXXXX")"
mkdir -p sim/build
cp rtl/vendor/fx68k/microrom.mem rtl/vendor/fx68k/nanorom.mem sim/build/
printf '%s\n' "$build_root" > sim/build/wsl_system_profile_build_dir.txt
sha256sum rtl/alpha68kn_*.sv rtl/vendor/fx68k/*.sv rtl/vendor/t80/T80s.v \
    rtl/vendor/jtframe_sdram/*.v rtl/vendor/jt12/hdl/*.v \
    rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    sim/system_main.cpp sim/sdram_model.h > sim/build/system_profile_inputs.sha256
cp rtl/alpha68kn_board.sv rtl/alpha68kn_renderer.sv rtl/alpha68kn_video_rom.sv \
    rtl/alpha68kn_gfxmem.sv rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv \
    rtl/alpha68kn_soundchips.sv rtl/alpha68kn_mixer.sv rtl/vendor/fx68k/*.sv \
    rtl/vendor/t80/T80s.v rtl/vendor/jtframe_sdram/*.v rtl/vendor/jt12/hdl/*.v \
    rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    sim/system_main.cpp sim/sdram_model.h "$build_root/"
cd "$build_root"
version="$(/usr/local/bin/verilator --version)"
case "$version" in 'Verilator 5.050 '*) ;; *) printf 'Unqualified simulator: %s\n' "$version" >&2; exit 2 ;; esac
/usr/local/bin/verilator --cc --exe --build --prof-c --prof-cfuncs -j 4 -O3 --assert --no-assert-case -Wno-fatal \
    --top-module alpha68kn_system --Mdir obj -o alpha68kn_system_profile_sim \
    alpha68kn_board.sv alpha68kn_renderer.sv alpha68kn_video_rom.sv alpha68kn_gfxmem.sv \
    alpha68kn_system.sv alpha68kn_audio.sv alpha68kn_soundchips.sv alpha68kn_mixer.sv \
    fx68k.sv fx68kAlu.sv uaddrPla.sv ./*.v \
    "$build_root/system_main.cpp" -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_system_profile_sim "$workspace/sim/build/"
