#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_root="$(mktemp -d /tmp/alpha68kn-render.XXXXXX)"
mkdir -p sim/build
printf '%s\n' "$build_root" > sim/build/wsl_renderer_build_dir.txt
sha256sum rtl/alpha68kn_renderer.sv rtl/alpha68kn_video_rom.sv rtl/alpha68kn_gfxmem.sv \
    rtl/vendor/jtframe_sdram/*.v sim/render_fixture.sv sim/render_fixture_main.cpp \
    sim/sdram_model.h > sim/build/renderer_inputs.sha256
cp rtl/alpha68kn_renderer.sv rtl/alpha68kn_video_rom.sv rtl/alpha68kn_gfxmem.sv \
    rtl/vendor/jtframe_sdram/*.v sim/render_fixture.sv sim/render_fixture_main.cpp \
    sim/sdram_model.h "$build_root/"
cd "$build_root"
/usr/local/bin/verilator --cc --exe --build -j 4 -O3 --assert -Wno-fatal \
    --top-module alpha68kn_render_fixture --Mdir obj -o alpha68kn_render_fixture_sim \
    render_fixture.sv alpha68kn_renderer.sv alpha68kn_video_rom.sv alpha68kn_gfxmem.sv \
    jtframe_sdram64*.v "$build_root/render_fixture_main.cpp" -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_render_fixture_sim "$workspace/sim/build/"
