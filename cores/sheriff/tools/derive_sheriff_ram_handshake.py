#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Derive the related-board LS174 control pair without inventing a RAM schedule."""
import hashlib
import itertools
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    # An event is a change of an external HREAD/CLR input. Q2 feedback can
    # end a positive clock pulse inside the event. Propagation time is not
    # modeled; no electrical pulse-width or board timing qualification follows.
    transition_rows = []
    for q1, q2, clear_n, rising in itertools.product((0, 1), repeat=4):
        actual = (0, 0) if not clear_n else (q2, 1) if rising else (q1, q2)
        expected_ready = 0 if not clear_n else q2 if rising else q1
        expected_valid = 0 if not clear_n else 1 if rising else q2
        assert actual == (expected_ready, expected_valid)
        transition_rows.append({'old_1Q': q1, 'old_2Q': q2, 'CLR_n': clear_n, 'CLK_rising': rising, 'new_1Q': actual[0], 'new_2Q': actual[1], 'RDY_IN': actual[0], '4T_output3': actual[0] ^ actual[1]})

    scenarios = []
    for initial_q1, initial_q2, initial_hread in itertools.product((0, 1), repeat=3):
        q1, q2, hread = initial_q1, initial_q2, initial_hread
        chip_clk = hread ^ q2
        captures = 0
        trace = []
        # Clear overrides any feedback-induced clock rise; releasing clear
        # while CLK is already high does not manufacture a new clock edge.
        events = [(hread, 0), (hread, 1)]
        events += [(initial_hread ^ (index & 1), 1) for index in range(1, 9)]
        for new_hread, clear_n in events:
            before = chip_clk
            if not clear_n:
                q1, q2 = 0, 0
                captures = 0
            chip_clk = new_hread ^ q2
            rising = clear_n and not before and chip_clk
            if rising:
                q1, q2 = q2, 1
                captures += 1
                # Settle Q2-to-XOR feedback before the next external event.
                chip_clk = new_hread ^ q2
            hread = new_hread
            assert q1 == int(captures >= 2)
            assert q2 == int(captures >= 1)
            assert (q1 ^ q2) == int(captures == 1)
            trace.append({'HREAD_n': hread, 'CLR_n': clear_n, 'capture': bool(rising), 'captures_since_clear': captures, '1Q_RDY_IN': q1, '2Q': q2, 'CLK_after_settling': chip_clk, '4T_output3': q1 ^ q2})
        assert captures >= 2
        scenarios.append({'initial_state': {'1Q': initial_q1, '2Q': initial_q2, 'HREAD_n': initial_hread}, 'events': trace})

    sources = [Path('_checks/manuals/bandido-1980.pdf'), Path('_checks/manuals/ti-sn74ls174.pdf')]
    report = {
        'scope': 'Conditional related-Bandido LS174 control-pair and XOR clock derivation; no board transaction timing pass',
        'sources': [
            {'path': sources[0].as_posix(), 'url': 'https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Bandido.pdf', 'pdf_pages': [35, 36], 'sha256': digest(sources[0])},
            {'path': sources[1].as_posix(), 'url': 'https://www.ti.com/lit/ds/symlink/sn74ls174.pdf', 'pdf_page': 1, 'sha256': digest(sources[1])},
        ],
        'corrected_connections': {
            '4F_1D': 'Pin 3 receives 4F 2Q pin 5 feedback, not HREAD_n. The common feedback net also reaches 4T pin 4. HREAD_n separately enters 4T pin 5.',
            '4F_2D': 'Pin 4 tied high; 2Q pin 5 is the first capture flag.',
            '4F_1Q': 'Pin 2 drives RDY IN and 4T pin 1.',
            '4T_clock': 'LS86 pins 4/5 take 2Q/HREAD_n; output pin 6 routes to readback latch CLK pin 9.',
            '4T_output3': 'LS86 pin 1 from 1Q and pin 2 from 2Q; output pin 3 is their XOR.',
            '4F_4G_CLR_n': 'Both LS174 CLR pin 1 inputs share the cross-sheet RAMSTB_n net from 3F LS00 output 3. Page 35 also connects this net to READY 3D CLR pin 13; CPU WR RD and RDY IN are the separate neighboring cross-sheet nets.',
        },
        'equations': {'CLK': 'HREAD_n XOR 2Q', '1Q_next_on_CLK_rise': 'old 2Q', '2Q_next_on_CLK_rise': '1', 'RDY_IN': '1Q', '4T_output3': '1Q XOR 2Q'},
        'control_capture_sequence_after_clear': ['00: RDY_IN=0, XOR=0', '01: RDY_IN=0, XOR=1', '11: RDY_IN=1, XOR=0', '11 on later captures until clear'],
        'transition_cases': len(transition_rows), 'transition_rows': transition_rows,
        'initial_state_scenarios': len(scenarios), 'scenario_traces': scenarios,
        'viewport_recovery': [
            {'original': '_checks/manuals/bandido-page-36.png', 'box': [620, 4320, 2050, 5050], 'viewport': '_checks/manuals/bandido-hread-d1-connected.png'},
            {'original': '_checks/manuals/bandido-page-36.png', 'box': [980, 4850, 2520, 5550], 'viewport': '_checks/manuals/bandido-handshake-bottom-connected.png'},
            {'original': '_checks/manuals/bandido-page-36.png', 'box': [1250, 5080, 1870, 5240], 'inspection_zoom': '4x nearest neighbor', 'viewport': '_checks/manuals/bandido-handshake-crossings-4x.png'},
            {'original': '_checks/manuals/bandido-page-35.png', 'box': [0, 4800, 5088, 6250], 'inspection_zoom': '1/2 scale', 'viewport': '_checks/manuals/bandido-bottom-nets-35.png'},
            {'original': '_checks/manuals/bandido-page-36.png', 'box': [0, 4800, 5088, 6250], 'inspection_zoom': '1/2 scale', 'viewport': '_checks/manuals/bandido-bottom-nets-36.png'},
        ],
        'supersedes': 'The earlier partial observation in sheriff_memory_primary_connections.json incorrectly assigned HREAD_n to 4F 1D. Complete connected viewports show the feedback connection.',
        'limits': [
            'CLR_n connectivity to RAMSTB_n is established on the related board. The external-event model does not generate STSTB or qualify asynchronous-clear pulse widths and READY 3D response, including overlapping low preset/clear.',
            'Functional edge counting excludes real XOR/LS174 propagation, pulse-width/setup/hold limits and RC effects.',
            'RAS/CAS/WE gating, address mux and which RAM byte is valid at each capture remain unqualified.',
            'Related Bandido net applicability to Sheriff remains conditional.',
            'No production READY, video, latch or clock RTL is changed and no MAME mismatch is waived.',
        ],
        'physical_ram_schedule_qualified': False, 'production_rtl_changed': False, 'quartus_executed': False,
        'script_sha256': digest(Path(__file__)),
    }
    output = Path('docs/evidence/sheriff_ram_handshake.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'transition_cases': len(transition_rows), 'initial_state_scenarios': len(scenarios), 'ready_after_capture': 2, 'board_schedule_qualified': False, 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
