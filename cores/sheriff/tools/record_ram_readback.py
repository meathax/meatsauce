#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record the isolated sampled RAM readback/READY primitive qualification."""
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    root = Path('_checks/ram-readback-20261009')
    build = json.loads((root / 'build-receipt.json').read_text())
    test = json.loads((root / 'test-receipt.json').read_text())
    assert build['exit_code'] == test['exit_code'] == 0
    assert test['stdout'].strip() == 'PASS cases=22 capture_feedback=1 clear_release_no_edge=1 READY_Qbar=1'
    files = ['rtl/n8080_ram_readback.sv', 'sim/ram_readback.cpp',
             'docs/evidence/sheriff_ram_handshake.json',
             'docs/evidence/sheriff_memory_mux_connections.json',
             str(root / 'build-receipt.json'), str(root / 'test-receipt.json'), __file__]
    report = {
        'scope': 'Isolated master-clock sampled related-Bandido 4F/4G/4T and READY 3D model',
        'connections': {
            'capture_clock': 'HREAD_n XOR Q2; 4F D1=old Q2, D2=1; Q1=RDY IN.',
            'clear': 'RAMSTB_n clears both LS174 data/flag latches and READY CLR.',
            'READY': 'LS74 D=NOT phi1 TTL; CLK=phi3 TTL; PREbar=RDY IN; CLRbar=RAMSTB_n; CPU uses Qbar.',
        },
        'test': {'build_exit': 0, 'test_exit': 0, 'explicit_function_cases': 22,
                 'covers': ['00->01->11 flag feedback and data capture',
                            'Clear dominance and clear release while capture clock already high',
                            'Held-clock data retention and subsequent captures',
                            'READY Qbar clear/preset behavior, including both async controls low',
                            'Phi3 edge sampling, no phi1-only resampling, preset release with phi3 already high'],
                 'receipts': [str(root / 'build-receipt.json'), str(root / 'test-receipt.json')]},
        'source_function_evidence': ['docs/evidence/sheriff_ram_handshake.json',
                                     'docs/evidence/sheriff_memory_mux_connections.json'],
        'sha256': {p: sha(p) for p in files},
        'primitive_qualified_for_stated_model': True,
        'integrated_in_board': False,
        'physical_memory_timing_qualified': False,
        'strict_graphics_gate_pass': False,
        'quartus_executed': False,
        'limits': ['Inputs are pin levels sampled at the master clock; electrical pulse width, glitches and propagation are not modeled.',
                   'Simultaneous capture/preset-release/phi3 events require physical propagation qualification before integration.',
                   'No valid DRAM DO window, CPU wait count or absolute phase is established.',
                   'Exact Sheriff applicability of related Bandido connections remains conditional.'],
    }
    out = Path('docs/evidence/sheriff_ram_readback.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'build_exit': 0, 'test_exit': 0, 'cases': 22,
                      'board_integrated': False, 'physical_timing_pass': False}))


if __name__ == '__main__':
    main()
