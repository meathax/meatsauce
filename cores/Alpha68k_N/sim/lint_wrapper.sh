#!/usr/bin/env bash
# Check real board/framework wiring; vendor stubs qualify elaboration only.
set -euo pipefail
workspace="$(pwd)"
snapshot="$(mktemp -d /tmp/alpha68kn-wrapper-lint.XXXXXX)"
mkdir -p "$snapshot/sys" sim/build
cp Alpha68k_N.sv sim/wrapper_lint_stubs.sv "$snapshot/"
cp sys/video_freak.sv sys/math.sv sys/emu_ports.vh sys/arcade_video.v sys/video_mixer.sv sys/gamma_corr.sv \
    sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv "$snapshot/sys/"
# sync_fix is defined in the full top-level framework. Use its exact source,
# rather than elaborating unrelated PLL/DDR/HPS peripherals for this boundary.
awk '/^module sync_fix/{emit=1} emit{print} emit && /^endmodule/{exit}' \
    sys/sys_top.v > "$snapshot/sys/sync_fix.v"
cp rtl/alpha68kn_crt.sv rtl/vendor/mister_features/*.v rtl/vendor/mister_features/*.sv rtl/alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer}.sv \
    rtl/vendor/fx68k/*.sv rtl/vendor/t80/T80s.v rtl/vendor/jtframe_sdram/*.v \
    rtl/vendor/jt12/hdl/*.v rtl/vendor/jt12/jt49/hdl/*.v \
    rtl/vendor/ay49/hdl/*.v "$snapshot/"
printf '`define BUILD_DATE "lint-only"\n' > "$snapshot/build_id.v"
sha256sum rtl/alpha68kn_crt.sv rtl/vendor/mister_features/*.v rtl/vendor/mister_features/*.sv Alpha68k_N.sv files.qip rtl/alpha68kn_audio.qip sim/wrapper_lint_stubs.sv \
    sim/lint_wrapper.sh rtl/alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer}.sv \
    sys/video_freak.sv sys/math.sv sys/emu_ports.vh sys/arcade_video.v sys/video_mixer.sv sys/gamma_corr.sv \
    sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv sys/sys_top.v \
    > sim/build/wrapper_lint_inputs.sha256
cd "$snapshot"
case "$(/usr/local/bin/verilator --version)" in
    'Verilator 5.050 '*) ;; *) exit 2 ;;
esac
for mode in native framebuffer; do
    defines=()
    if [[ "$mode" == framebuffer ]]; then defines=(-DMISTER_FB -DMISTER_FB_PALETTE); fi
    # The pinned framework declares hq2x Result as an implicit output net
    # despite its procedural assignment. Match legacy elaboration leniency;
    # do not alter pinned sys/, stub the function, or disable RTL assertions.
    /usr/local/bin/verilator --lint-only --assert --no-assert-case -Wno-fatal -Wno-PROCASSWIRE \
        --top-module emu --Mdir "obj_$mode" -I. "${defines[@]}" \
        Alpha68k_N.sv wrapper_lint_stubs.sv alpha68kn_crt.sv crt_adjust.sv crt_vsize.sv alpha68kn_{board,system,renderer,video_rom,gfxmem,audio,soundchips,mixer}.sv \
        fx68k.sv fx68kAlu.sv uaddrPla.sv ./*.v sys/arcade_video.v sys/video_mixer.sv \
        sys/video_freak.sv sys/math.sv sys/gamma_corr.sv sys/scandoubler.v sys/hq2x.sv sys/video_freezer.sv sys/sync_fix.v \
        > "$workspace/sim/build/wrapper_lint_$mode.log" 2>&1
    printf '%s elaboration exit 0\n' "$mode"
done
