#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
build_space="${ALPHA68KN_BUILD_ROOT:-/var/tmp}"
mkdir -p "$build_space"
snapshot="$(mktemp -d "$build_space/alpha68kn-wrapper.XXXXXX")"
output="${ALPHA_WRAPPER_OUTPUT:-$workspace/sim/build}"
mkdir -p "$snapshot/sys" "$output"
printf '%s\n' "$snapshot" > "$output/wrapper_build_dir.txt"
cp Alpha68k_N.sv sim/wrapper_main.cpp sim/sdram_model.h "$snapshot/"
cp sys/video_freak.sv sys/math.sv sys/emu_ports.vh sys/hps_io.sv sys/arcade_video.v sys/video_mixer.sv \
    sys/gamma_corr.sv sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv "$snapshot/sys/"
awk '/^module sync_fix/{emit=1} emit{print} emit && /^endmodule/{exit}' \
    sys/sys_top.v > "$snapshot/sys/sync_fix.v"
python3 sim/normalize_framework_scope.py "$snapshot/sys/video_mixer.sv" "$output/wrapper_scope_adapter.json"
cp rtl/alpha68kn_crt.sv rtl/vendor/mister_features/*.v rtl/vendor/mister_features/*.sv rtl/alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer,mcu}.sv \
    rtl/vendor/fx68k/*.sv rtl/vendor/t80/T80s.v rtl/vendor/t48/t48_core.v rtl/vendor/jtframe_sdram/*.v \
    rtl/vendor/jt12/hdl/*.v rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    credits/rtl/credits_overlay.sv credits/generated/credits_rom.sv credits/generated/credits_layout.vh "$snapshot/"
# Read-only credit state accessor; neither RTL nor its input/output timing changes.
printf '`verilator_config\npublic_flat_rd -module "credits_overlay" -var "active"\n' > "$snapshot/wrapper_observer.vlt"
cp rtl/vendor/fx68k/microrom.mem rtl/vendor/fx68k/nanorom.mem "$snapshot/"
cp rtl/vendor/fx68k/microrom.mem rtl/vendor/fx68k/nanorom.mem "$output/"
printf '`define BUILD_DATE "simulation"\n' > "$snapshot/build_id.v"
sha256sum rtl/alpha68kn_crt.sv rtl/vendor/mister_features/*.v rtl/vendor/mister_features/*.sv Alpha68k_N.sv sim/wrapper_main.cpp sim/sdram_model.h sim/build_wrapper.sh \
    sim/normalize_framework_scope.py rtl/alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer,mcu}.sv \
    rtl/vendor/fx68k/*.sv rtl/vendor/fx68k/*.mem rtl/vendor/t80/T80s.v rtl/vendor/t48/t48_core.v rtl/vendor/jtframe_sdram/*.v \
    rtl/vendor/jt12/hdl/*.v rtl/vendor/jt12/jt49/hdl/*.v rtl/vendor/ay49/hdl/*.v \
    credits/rtl/credits_overlay.sv credits/generated/credits_rom.sv credits/generated/credits_layout.vh \
    sys/video_freak.sv sys/math.sv sys/emu_ports.vh sys/hps_io.sv sys/arcade_video.v sys/video_mixer.sv \
    sys/gamma_corr.sv sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv sys/sys_top.v \
    > "$output/wrapper_inputs.sha256"
cd "$snapshot"
case "$(/usr/local/bin/verilator --version)" in 'Verilator 5.050 '*) ;; *) exit 2 ;; esac
TMPDIR=/var/tmp CCACHE_DISABLE=1 /usr/local/bin/verilator --cc --exe --build -j "${ALPHA_WRAPPER_JOBS:-2}" -O3 --assert --no-assert-case \
    -Wno-fatal -Wno-PROCASSWIRE --top-module emu --Mdir obj -o alpha68kn_wrapper_sim \
    -I. -DALPHA_EMU_SIM -DMISTER_FB -DMISTER_FB_PALETTE wrapper_observer.vlt Alpha68k_N.sv \
    credits_overlay.sv credits_rom.sv alpha68kn_crt.sv crt_adjust.sv crt_vsize.sv alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer,mcu}.sv \
    fx68k.sv fx68kAlu.sv uaddrPla.sv ./*.v sys/*.v sys/*.sv \
    "$snapshot/wrapper_main.cpp" -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_wrapper_sim "$output/"

# Retain the exact generated model for host-only relinks after WSL exits.
tar -cf "$output/generated_model.tar" -C "$snapshot" .
sha256sum "$output/generated_model.tar" > "$output/generated_model.sha256"
