#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim/results/timing
python3 scripts/board_sources.py
mdir=${ZERO_IRQ_PHASE_MDIR:-/mnt/r/Verilator/zero-irq-phase-20261005}
verilator --cc --exe --build -j 4 --top-module zero_irq_phase_top \
  --Mdir "$mdir" --no-timing -Irtl/ucore \
  -DCE_HALF_PLUS2 -DREADY_FIXED_HIGH -DCE_STALL_ON \
  -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING \
  -f sim/board_sources.f sim/zero_irq_phase_top.sv "$PWD/sim/irq_phase_main.cpp" \
  >sim/results/timing/irq-phase-build.log 2>&1
"$mdir/Vzero_irq_phase_top" >sim/results/timing/irq-phase-run.log 2>&1
cat sim/results/timing/irq-phase-run.log
