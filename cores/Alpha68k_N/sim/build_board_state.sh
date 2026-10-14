#!/usr/bin/env bash
set -euo pipefail
# Run explicitly through bash in Ubuntu WSL, from the repository root.
mkdir -p sim/build
cp rtl/vendor/fx68k/microrom.mem rtl/vendor/fx68k/nanorom.mem sim/build/
workspace="$(pwd)"
# GNU Make rejects a CURDIR containing spaces. This is a disposable build snapshot,
# not a Git checkout; the authoritative RTL remains in the current workspace.
build_root="$(mktemp -d /tmp/alpha68kn-board-state.XXXXXX)"
printf '%s\n' "$build_root" > sim/build/wsl_board_state_build_dir.txt
sha256sum rtl/alpha68kn_board.sv rtl/vendor/fx68k/*.sv \
  rtl/vendor/t80/T80s.v sim/board_state_main.cpp > sim/build/board_state_inputs.sha256
cp rtl/alpha68kn_board.sv rtl/vendor/fx68k/*.sv \
  rtl/vendor/t80/T80s.v sim/board_state_main.cpp "$build_root/"
cd "$build_root"
verilator_bin=/usr/local/bin/verilator
version="$($verilator_bin --version)"
case "$version" in 'Verilator 5.050 '*) ;; *) printf 'Unqualified simulator: %s\n' "$version" >&2; exit 2 ;; esac
printf '%s\n' "$version" > "$workspace/sim/build/verilator_version.txt"
# The donor ALU's zero reset control word matches no unique-case item. Preserve
# explicit assertions; disable only generated unique/priority-case checks.
"$verilator_bin" --cc --exe --build -j 4 -O3 --assert --no-assert-case \
  -Wno-fatal --top-module alpha68kn_board \
  --Mdir obj -o alpha68kn_board_state_sim \
  alpha68kn_board.sv fx68k.sv fx68kAlu.sv uaddrPla.sv T80s.v \
  "$build_root/board_state_main.cpp" \
  -CFLAGS '-O3 -std=c++17'
cp obj/alpha68kn_board_state_sim "$workspace/sim/build/alpha68kn_board_state_sim"
