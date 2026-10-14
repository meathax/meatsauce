#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record the isolated conditional RAM phase primitive's actual qualification."""
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    checks = Path('_checks/memory-phases-20261009')
    build = json.loads((checks / 'build-receipt.json').read_text())
    test = json.loads((checks / 'test-receipt.json').read_text())
    assert build['exit_code'] == test['exit_code'] == 0
    assert test['stdout'].strip() == 'PASS master_samples=16000 crystal_edges=6400 includes_CE_holds=1'
    rows = []
    count = serial = divider = 0
    for edge in range(1, 129):
        if edge % 2:
            serial = ((serial << 1) | ((count >> 1) & 1)) & 255
            if not divider:
                count = (count + 1) & 15
            divider ^= 1
        if edge > 64 and edge % 2:
            rows.append({'crystal_edge_from_period_origin': edge - 65,
                         '4I': count, '4A': serial,
                         'raw_CAS_n': 1 ^ ((serial >> 1) & 1),
                         'raw_RAS_n': ((serial >> 1) & (serial >> 3)) & 1,
                         'COMADR_n': 1 ^ ((serial >> 6) & 1),
                         'HREAD_n': 1 ^ ((count >> 2) & 1)})
    assert len(rows) == 32
    report = {
        'scope': 'Isolated conditional related-Bandido clock network; reproducible artificial reset origin',
        'connections': {
            '4A_CLK8': '2A LS160 QA pin14, CK/2 (10.08 MHz), not the raw 20.16 MHz crystal.',
            '4A_A1_B2': '4I QB pin13, traced through the connected lower return wire.',
            '3B_second_half': 'CLK13 from CK/2; J12 high, Kbar14 low, PREbar11 and CLRbar15 high; Q10 toggles.',
            '4I_CLK2': '3B second-half Q10 (5.04 MHz).',
            '4I_controls': 'LOADbar9 and ENT10 high; CLRbar1 joins the high 3B CLRbar15 net. ENP7 joins the derived clock net.',
            'ordering': '4A samples pre-count QB at the CK/2 edge; the downstream 3B Q transition subsequently clocks 4I.',
        },
        'assumptions': [
            'The counter enable is treated as high at its derived rising clock event; electrical ENP setup/hold and propagation margins are not qualified.',
            'Reset initializes all model state to zero. This defines an oracle origin, not physical PCB reset or an absolute CPU/raster phase.',
            'Zero-delay logical stages retain their causal ordering. Analog delays, 4116 access/write/refresh timing and RD-valid windows remain open.',
            'Exact Sheriff revision applicability of related Bandido connections remains conditional.',
        ],
        'sources': [
            {'path': '_checks/manuals/bandido-1980.pdf', 'pdf_pages': [33, 34],
             'url': 'https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Bandido.pdf',
             'sha256': sha('_checks/manuals/bandido-1980.pdf')},
            {'url': 'https://www.ti.com/lit/ds/symlink/sn74ls161a.pdf',
             'document': 'SDLS060, October 1976, revised March 1988',
             'limit': 'Function reference; enable electrical setup/hold is not a pass.'},
        ],
        'viewports': [
            {'page': 33, 'box': [2500, 0, 5088, 2300], 'path': '_checks/manuals/bandido-phase-counter-connected.png'},
            {'page': 33, 'box': [2980, 790, 4600, 2520], 'path': '_checks/manuals/bandido-dram-phase-source-connected.png'},
            {'page': 34, 'box': [0, 500, 2200, 2300], 'path': '_checks/manuals/bandido-horizontal-reset-connected.png'},
        ],
        'test': {'build_exit': 0, 'test_exit': 0, 'master_samples': 16000,
                 'crystal_edges': 6400, 'oracle': 'Closed-form count of CK/2 rising edges and historical pre-count QB; checks all four raw pins and CE holds.',
                 'receipts': [str(checks / 'build-receipt.json'), str(checks / 'test-receipt.json')]},
        'steady_period_crystal_edges': 64,
        'steady_CK2_rising_edge_rows': rows,
        'sha256': {p: sha(p) for p in ['rtl/n8080_memory_phases.sv', 'sim/memory_phases.cpp',
                    str(checks / 'test-receipt.json'), str(checks / 'build-receipt.json'), __file__]},
        'primitive_qualified_for_stated_model': True,
        'integrated_in_board': False,
        'physical_memory_timing_qualified': False,
        'strict_graphics_gate_pass': False,
        'quartus_executed': False,
    }
    out = Path('docs/evidence/sheriff_memory_phases.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'report': str(out), 'primitive_pass': True, 'samples': 16000,
                      'board_integrated': False, 'physical_timing_pass': False}))


if __name__ == '__main__':
    main()
