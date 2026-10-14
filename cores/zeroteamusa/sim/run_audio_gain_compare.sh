#!/usr/bin/env bash
# Compare actual sound-CPU/OPL/OKI waveforms for an isolated RTL timing candidate.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python3 scripts/audio_sources.py
python3 - <<'PY'
from pathlib import Path
candidate=Path('sim/results/audio-gain-candidate')
baseline=Path('sim/results/audio-gain-baseline')
candidate.mkdir(parents=True,exist_ok=True)
baseline.mkdir(parents=True,exist_ok=True)
pipeline='''// Register the rhythm/gain result before the accumulator carry chain.
// Operator state is stable between cenop pulses; target gains are constant.
reg signed [13:0] op2x_g_q;
always @(posedge clk) op2x_g_q <= op2x_g;

'''
s=Path('rtl/sound/jtopl/jtopl_acc.v').read_text()
if pipeline in s:
    assert s.count(pipeline)==1 and s.count('( op2x_g_q  )')==1
    s=s.replace(pipeline,'').replace('( op2x_g_q  )','( op2x_g    )')
assert s.count('// Continuous output')==1 and s.count('( op2x_g    )')==1
(baseline/'jtopl_acc.v').write_text(s)
s=s.replace('// Continuous output',pipeline+'// Continuous output')
s=s.replace('( op2x_g    )','( op2x_g_q  )')
(candidate/'jtopl_acc.v').write_text(s)
f=Path('sim/audio_sources.f').read_text()
needle='rtl/sound/jtopl/jtopl_acc.v'
assert f.count(needle)==1
for path in [baseline,candidate]:
    (path/'sources.f').write_text(f.replace(needle,(path/'jtopl_acc.v').as_posix()))
PY
for mode in baseline candidate; do
    build="/mnt/r/Verilator/zero-audio-gain-$mode"
    work="$root/sim/results/audio-gain-$mode"
    mkdir -p "$build" "$work/sim/results"
    [[ -e "$work/roms" ]] || ln -s "$root/roms" "$work/roms"
    [[ -e "$work/rtl" ]] || ln -s "$root/rtl" "$work/rtl"
    sources="sim/results/audio-gain-$mode/sources.f"
    verilator --cc --exe --build -j 4 --top-module ZeroTeam_audio \
        --Mdir "$build" --no-timing -Irtl/sound/jtopl -Irtl/sound/jt6295 \
        -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-PINMISSING \
        -f "$sources" "$root/sim/audio_main.cpp" -CFLAGS '-std=c++17 -O2' \
        >"$work/build.log" 2>&1
    (cd "$work"; "$build/VZeroTeam_audio" 96000000 >run.log 2>&1)
    tail -1 "$work/run.log"
done
cmp sim/results/audio-gain-baseline/sim/results/audio-isolated.pcm \
    sim/results/audio-gain-candidate/sim/results/audio-isolated.pcm
echo 'Actual 96M-clock audio candidate PCM comparison: byte-identical'
