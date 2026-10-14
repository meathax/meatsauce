#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Derive the related Bandido CPU-clock logic, without fitting it to MAME.

This is a zero-delay Boolean circuit calculation, not an electrical timing
measurement. Sheriff applicability and absolute raster phase remain separate.
"""
import hashlib
import json
from fractions import Fraction
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def edge(count, shift, phi2_q):
    # 2A LS160 and 3A LS164 see the same crystal edge. The register captures
    # the pre-edge QD through 4H's inverter, not the new counter value.
    new_count = (count + 1) % 10
    new_shift = ((shift << 1) | int(count < 8)) & 255
    # 3B first half: /PRE=1, J=/K=1; /CLR follows inverted 2A QD.
    # Its CLK is 3A QC (pin 5), and output /Q (pin 7) feeds 5A input 3.
    if new_count >= 8:
        phi2_q = 0
    elif (new_shift & 4) and not (shift & 4):
        phi2_q = 1
    # 5A SN75361A common E is drawn high; each output is NAND(A,E).
    phi1 = int(not (new_shift & 2))   # input 1 is 3A QB, pin 4
    phi2 = phi2_q                    # NAND(/Q,1) = Q
    return new_count, new_shift, phi2_q, phi1, phi2


cases = 0
for initial_count in range(10):
    for initial_shift in range(256):
        for initial_q in range(2):
            count, shift, q = initial_count, initial_shift, initial_q
            for _ in range(32):
                count, shift, q, _, _ = edge(count, shift, q)
            for _ in range(10):
                count, shift, q, f1, f2 = edge(count, shift, q)
                # Independent closed-form waveform after the shift chain settles.
                assert f1 == int(count in (0, 1))
                assert f2 == int(3 <= count <= 7)
                assert not (f1 and f2)
            cases += 1

count, shift, q = 9, 0, 0
trace = {}
for _ in range(60):
    count, shift, q, f1, f2 = edge(count, shift, q)
    trace[count] = {'counter': count, 'qd': int(count >= 8),
                    'qb': (shift >> 1) & 1, 'qc': (shift >> 2) & 1,
                    'phi2_ff_q': q, 'phi1': f1, 'phi2': f2}
xtal_ns = Fraction(1_000_000_000, 20_160_000)
master_ns = Fraction(1_000_000_000, 50_400_000)
samples = [{'phase': p, 'crystal_interval': (2 * p) // 5,
            'phi1': trace[(2 * p) // 5]['phi1'],
            'phi2': trace[(2 * p) // 5]['phi2']} for p in range(25)]
assert [r['phase'] for r in samples if r['phi1']] == list(range(5))
assert [r['phase'] for r in samples if r['phi2']] == list(range(8, 20))
sources = json.loads((root / '_checks/manuals/cpu-phase-sources.json').read_text())
for row in sources:
    assert sha(root / row['path']) == row['sha256']
report = {
    'scope': 'Zero-delay connected CPU clock derivation for related Bandido I/O drawing 77-3367-11',
    'sources': sources,
    'schematic': {'path': '_checks/manuals/bandido-1980.pdf',
                  'sha256': sha(root / '_checks/manuals/bandido-1980.pdf'),
                  'pdf_page_one_based': 33,
                  'viewport': '_checks/manuals/bandido-cpu-phase-connected.png',
                  'viewport_sha256': sha(root / '_checks/manuals/bandido-cpu-phase-connected.png'),
                  'crop_of_page_33': [1850, 900, 4030, 2710]},
    'connections': [
        '20.160 MHz crystal -> 2A LS160 decade CK and 3A LS164 CK',
        '2A QD pin11 -> 4H inverter -> 3A A/B pins1/2 and 3B /CLR pin1',
        '3A QB pin4 -> 5A input1; 3A QC pin5 -> 3B CLK pin4',
        '3B J pin2 and /K pin3 and /PRE pin5 tied high',
        '3B /Q pin7 -> 5A input3; 5A common E pin2 drawn high',
        '5A output7 -> P9 phi1 pin10; output6 -> P9 phi2 pin21',
    ],
    'initial_state_cases': cases,
    'settling_crystal_edges': 32,
    'steady_state_nonoverlap': True,
    'crystal_hz': 20_160_000, 'cpu_hz': 2_016_000,
    'counter_waveform': [trace[c] for c in range(10)],
    'ideal': {'phi1_high_crystal_intervals': [0, 1],
              'phi2_high_crystal_intervals': [3, 4, 5, 6, 7],
              'phi1_high_ns': float(2 * xtal_ns),
              'phi2_high_ns': float(5 * xtal_ns),
              'cycle_ns': float(10 * xtal_ns)},
    'master_hz': 50_400_000, 'samples': samples,
    'sampling_error': {'phi1_edge_ns': 0,
                       'phi2_rise_late_ns': float(8 * master_ns - 3 * xtal_ns),
                       'phi2_fall_ns': 0,
                       'phi2_sampled_high_ns': float(12 * master_ns)},
    'previous_adapter': {'phi1_high_master_clocks': 12,
                         'phi2_high_master_clocks': 13, 'nonoverlap_master_clocks': 0},
    'sheriff_connected_wiring_qualified': False,
    'electrical_propagation_delays_qualified': False,
    'absolute_pixel_cpu_phase_qualified': False,
    'first_pixel_cause_qualified': False, 'strict_graphics_gate_pass': False,
    'limits': 'Sheriff own parts positions support the related clock topology but are not a complete net schematic. The zero-delay network captures pre-edge QD; analog propagation, supply thresholds and raster-origin/counter coupling are unqualified. The 50.4 MHz samples round the ideal phi2 rise to the next master edge, 9.920635 ns late. No IRQ offset or reference waiver is derived here.',
}
target = root / 'docs/evidence/sheriff_clock_network.json'
target.write_text(json.dumps(report, indent=2) + '\n')
print(f'Clock circuit: {cases} initial-state cases; phi1=20%, phi2=50%, non-overlap; 50.4MHz phi2 rise error {report["sampling_error"]["phi2_rise_late_ns"]:.6f} ns')
