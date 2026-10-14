#!/usr/bin/env bash
set -euo pipefail
workspace="$(pwd)"
snapshot="$(mktemp -d /tmp/alpha68kn-framework-video.XXXXXX)"
mkdir -p "$snapshot/sys" sim/build
printf '%s\n' "$snapshot" > sim/build/framework_video_build_dir.txt
cp sim/framework_video.sv sim/framework_video.cpp "$snapshot/"
cp sys/arcade_video.v sys/video_mixer.sv sys/gamma_corr.sv sys/scandoubler.v \
    sys/hq2x.sv sys/video_freezer.sv "$snapshot/sys/"
awk '/^module sync_fix/{emit=1} emit{print} emit && /^endmodule/{exit}' \
    sys/sys_top.v > "$snapshot/sys/sync_fix.v"
case "${1:-original}" in
    original) ;;
    scope-adapter) python3 sim/normalize_framework_scope.py "$snapshot/sys/video_mixer.sv" \
        sim/build/framework_video_scope_adapter.json ;;
    *) exit 2 ;;
esac
sha256sum sim/framework_video.sv sim/framework_video.cpp sim/build_framework_video.sh \
    sim/normalize_framework_scope.py \
    sys/arcade_video.v sys/video_mixer.sv sys/gamma_corr.sv sys/scandoubler.v \
    sys/hq2x.sv sys/video_freezer.sv sys/sys_top.v > sim/build/framework_video_inputs.sha256
cd "$snapshot"
case "$(/usr/local/bin/verilator --version)" in 'Verilator 5.050 '*) ;; *) exit 2 ;; esac
/usr/local/bin/verilator --cc --exe --build -j 4 -O3 --assert --no-assert-case \
    -Wno-fatal -Wno-PROCASSWIRE --top-module alpha68kn_framework_video \
    --Mdir obj -o alpha68kn_framework_video_sim framework_video.sv sys/*.v sys/*.sv \
    "$snapshot/framework_video.cpp" -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_framework_video_sim "$workspace/sim/build/"
