#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Derive related Bandido serializer gates; do not guess the RAM load phase."""
import hashlib
import itertools
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manual = Path('_checks/manuals/bandido-1980.pdf')
    nand = lambda a, b: not (a and b)
    modes = []
    for hb, vb, qa, qb, qc, reverse in itertools.product((False, True), repeat=6):
        # Page 34: 5T LS20 output 6, 5B LS32 output 3, 1K LS00 outputs 3/6.
        # TP4/TP5 name the high-blank Q outputs. 5T takes Qbar6/Qbar8.
        load_n = not ((not hb) and (not vb) and qa and qb) or not qc
        normal = not reverse
        s0 = nand(normal, load_n)
        s1 = nand(load_n, reverse)
        load = (not hb) and (not vb) and qa and qb and qc
        expected = (True, True) if load else (True, False) if reverse else (False, True)
        assert (s0, s1) == expected
        modes.append({'HB': int(hb), 'VB': int(vb), '4I_QA': int(qa), '4I_QB': int(qb), '4I_QC': int(qc), 'NOR': int(normal), 'REV': int(reverse), 'load_n': int(load_n), 'S0': int(s0), 'S1': int(s1)})
    ends = []
    for normal, qa, qh in itertools.product((False, True), repeat=3):
        reverse = not normal
        video = nand(nand(qa, normal), nand(qh, reverse))
        assert video == (qa if normal else qh)
        ends.append({'NOR': int(normal), 'REV': int(reverse), '1L_QA': int(qa), '1L_QH': int(qh), 'selected_bit': int(video)})
    # From the settled 2A/3A network: QB is low at counter 0/1;
    # QE is low at 3/4, so its positive edge is at 5. RC delays excluded.
    ready_clock = [{'2A_count': count, 'phi1_ttl_QB': int(count not in (0, 1)), 'phi3_ttl_QE': int(count not in (3, 4)), '3D_D_before_RC': int(count in (0, 1))} for count in range(10)]
    source_chips = json.loads(Path('_checks/manuals/video-control-chip-sources.json').read_text())
    report = {
        'scope': 'Ideal connected serializer logic and conditional READY observations on related Bandido drawings',
        'manual': {'url': 'https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Bandido.pdf', 'path': manual.as_posix(), 'sha256': sha(manual), 'io_pdf_pages': [33, 34], 'cpu_pdf_pages': [35, 36]},
        'manufacturer_sources': source_chips,
        'viewport_recovery': {
            'mode_connections': {'original': '_checks/manuals/bandido-page-34.png', 'box': [2660, 820, 3520, 2070], 'viewport': '_checks/manuals/bandido-mode-connections.png'},
            'load_inputs': {'original': '_checks/manuals/bandido-page-34.png', 'box': [2000, 800, 2700, 1940], 'viewport': '_checks/manuals/bandido-load-gate-pins.png'},
            'ttl_clock': {'original': '_checks/manuals/bandido-page-33.png', 'box': [1630, 1140, 4700, 2420], 'viewport': '_checks/manuals/bandido-clock-ttl-connected.png'},
            'ready': {'original': '_checks/manuals/bandido-page-35.png', 'box': [1720, 5000, 3650, 6150], 'viewport': '_checks/manuals/bandido-ready-connected.png'},
            'HB_output': {'original': '_checks/manuals/bandido-page-34.png', 'box': [1350, 380, 2700, 1320], 'viewport': '_checks/manuals/bandido-hb-output-connected.png'},
            'blanking_input_joins': {'original': '_checks/manuals/bandido-page-34.png', 'box': [2120, 1240, 2450, 1890], 'viewport': '_checks/manuals/bandido-blank-load-input-joins.png', 'viewport_scale': 2},
            'QC_fanout': {'original': '_checks/manuals/bandido-page-33.png', 'box': [3990, 1050, 4670, 2240], 'viewport': '_checks/manuals/bandido-4i-output-clock-pin-trace.png'},
        },
        'serializer_connections': {
            '1L': '198: CLK pin 11; S0 pin 24 from 1K output 3; S1 pin 1 from 1K output 6; QA pin 4, QH pin 20; A=RD7 .. H=RD0',
            '5T': 'LS20 pin1 takes4G Qbar6 (inverse TP4 HB), pin2 takes4G Qbar8 (inverse TP5 VB); pins4/5 take4I QA/QB; pin6 is their four-input NAND',
            '5B': 'LS32 pin 2 from 5T pin 6; pin 1 from HREAD_n; output pin 3 is load_n; C6 220 pF shunts this net',
            'HREAD_n': '4I QC pin 12 inverted by 2L LS04 pins 5/6 on page 33',
            '1K_mode': 'LS00 NANDs: pins 1=NOR, 2=load_n -> 3=S0; pins 4=load_n, 5=REV -> 6=S1. OR-shaped negative-input symbols still implement NAND.',
            '1K_end': 'QA and NOR -> NAND output 8; QH and REV -> NAND output 11; these feed 2K NAND pins 12/13, output 11',
        },
        'blanking_polarity': 'HB=4G Q5/TP4 and VB=4G Q9/TP5 are high-blank test-point outputs; load gates take their complementary active-high Qbar outputs.',
        'ideal_load_predicate': '~HB & ~VB & 4I_QA & 4I_QB & 4I_QC',
        'polarity_correction': 'Supersedes earlier ambiguous active-input HB/VB labels; connected test-point/output joins establish the inversions.',
        'counter_relative_load': 'The three low counter outputs must all be high. This is a pre-edge signal predicate, not an x-coordinate or established DRAM sample time.',
        'mode_derivation_cases': len(modes), 'mode_table': modes,
        'end_selection_cases': len(ends), 'end_selection_table': ends,
        'conditional_streams': {'NOR': 'S1:S0=10, toward QA, A then B .. H (RD7 .. RD0)', 'REV': 'S1:S0=01, toward QH, H then G .. A (RD0 .. RD7)', 'load': 'S1:S0=11; both direction flags can select parallel load'},
        'ready_connections': {
            '3D': 'CPU page 35 LS74 second half: D pin 12 from inverted phi1 TTL through 4D pins 13/12; CLK pin 11 from CP2 pin 23 phi3 TTL; PRE_n pin 10 from RDY IN; Qbar pin 8 to CPU READY pin 23',
            'phi1_ttl': '3A QB pin 4 buffered by XOR 4K with its other input grounded',
            'phi3_ttl': '3A QE pin 10 buffered by XOR 4K with its other input grounded; this is distinct from physical CPU phi2',
            'RC': 'C34/C35 120 pF appear on D/CLK nets; digital zero-delay tables do not qualify their analog delays',
            'conditional_normal_cycle': 'If PRE_n and CLR_n remain high, the ideal QE rise at count 5 samples D=0, yielding Qbar=READY=1. This does not prove those asynchronous inputs remain high during actual RAM service.',
            'async_controls': 'RDY IN low asserts PRE_n and forces READY low when CLR_n is high. CLR_n low with PRE_n high forces READY high. Both low give the manufacturer unstable condition with both outputs high; do not model Qbar as inverse Q in that condition.',
        },
        'ideal_ready_clock_table': ready_clock,
        'limits': [
            'Related Bandido connectivity is conditional for Sheriff; the own-parts drawing establishes a 198 at 1L but not every net/revision.',
            'HB/VB gate polarity is connected; counter reset/visible origin and absolute clock phase still need complete counter/blanking derivation.',
            'The DRAM address held when 1L loads, 4F/4G read-latch schedule, RAMSTB and RDY IN waveforms are not yet reconstructed.',
            'Register/gate propagation and C6/C34/C35 electrical effects are not qualified.',
            'No production serializer, READY, counter or IRQ RTL is changed by this derivation.',
            'No load offset is fitted to MAME pixels and no existing mismatch is waived.',
        ],
        'production_video_integrated': False, 'physical_byte_fetch_qualified': False,
        'quartus_executed': False, 'script_sha256': sha(Path(__file__)),
    }
    output = Path('docs/evidence/sheriff_video_control_network.json')
    prior=Path('_checks/horizontal-video-path-20261010/previous-video-control-network.json')
    if output.exists() and not prior.exists():
        prior.write_bytes(output.read_bytes())
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'mode_cases': len(modes), 'end_selection_cases': len(ends), 'relative_load': report['ideal_load_predicate'], 'physical_byte_fetch_qualified': False, 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
