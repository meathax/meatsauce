#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record connected primary-source RAM wiring, not a production timing pass."""
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    source_specs = [
        ('bandido-1980.pdf', 'https://arcarc.xmission.com/PDF_Arcade_Manuals_and_Schematics/Bandido.pdf', [33, 35, 36]),
        ('ti-sn74ls153.pdf', 'https://www.ti.com/lit/ds/symlink/sn74ls153.pdf', [1]),
        ('ti-sn74ls32.pdf', 'https://www.ti.com/lit/ds/symlink/sn74ls32.pdf', [1]),
        ('ti-sn74ls02.pdf', 'https://www.ti.com/lit/ds/symlink/sn74ls02.pdf', [1]),
        ('ti-sn74ls00.pdf', 'https://www.ti.com/lit/ds/symlink/sn74ls00.pdf', [3]),
    ]
    sources = []
    for name, url, pages in source_specs:
        path = '_checks/manuals/' + name
        sources.append({'path': path, 'url': url, 'pdf_pages': pages, 'sha256': digest(path)})
    columns = [
        [f'A{i}' for i in range(7)],
        [f'A{i}' for i in range(7, 14)],
        ['H0', 'H1', 'H2', 'H3', 'H4', 'V0', 'V1'],
        ['V2', 'V3', 'V4', 'V5', 'V6', 'V7', '0'],
    ]
    report = {
        'scope': 'Conditional related-Bandido RAM address/data/strobe connections; no transaction timing qualification',
        'sources': sources,
        'manufacturer_functions': {
            'LS153': 'With G_n=0, select B:A=00/01/10/11 chooses C0/C1/C2/C3. A pin14, B pin2; 1Y pin7, 2Y pin9; G_n pins1/15 are grounded in the address muxes.',
            'LS02': 'Positive NOR. Tied inputs on 3E pins8/9 give output10=NOT HREAD_n; inputs11/12 give output13=NOT(input11 OR input12).',
            'LS32': 'Positive OR. Negative-input/output AND-style symbols in the schematic do not make the fitted LS32 a positive-logic NAND.',
        },
        'selector_connections': {
            'A_pin14': '4D output8 is NOT CP2 COMADR_n pin29; shared by all four RAM muxes.',
            'B_pin2': '3E output10 is NOT CP2 HREAD_n pin31; shared by all four RAM muxes.',
        },
        'address_input_columns_AR0_to_AR6': {f'C{i}': c for i, c in enumerate(columns)},
        'physical_selector_rows': [
            {'COMADR_n': 1, 'HREAD_n': 1, 'BA': '00', 'selected': 'C0', 'AR0_to_AR6': columns[0]},
            {'COMADR_n': 0, 'HREAD_n': 1, 'BA': '01', 'selected': 'C1', 'AR0_to_AR6': columns[1]},
            {'COMADR_n': 1, 'HREAD_n': 0, 'BA': '10', 'selected': 'C2', 'AR0_to_AR6': columns[2]},
            {'COMADR_n': 0, 'HREAD_n': 0, 'BA': '11', 'selected': 'C3', 'AR0_to_AR6': columns[3]},
        ],
        'address_projection': {
            'convention': 'Treat C0/C2 as row and C1/C3 as column, with CPU byte index row + (column << 7); real RAS/CAS edge ordering is still open.',
            'CPU': 'A[6:0] + (A[13:7] << 7): all 16384 RAM byte positions.',
            'video': 'row = H[4:0] | ((V & 3) << 5); column = V[7:2]; byte index = H[4:0] + (V[7:0] << 5), with CPU A13=0.',
            'limit': 'H/V names are physical CP3 levels. Their counter phase, reset, flip polarity and visible coordinate origin are not inferred here.',
        },
        'read_data_path': {
            'common_input': '4E/4H common AND input net terminates at +5 V through R4 1k. It is a high input, not a phase control.',
            'function': 'RD0..RD7 buffer corresponding DO0..DO7 through LS08 gates. Valid DO timing remains a DRAM-cycle question.',
            'correction': 'Supersedes the earlier assumption of an unqualified common gating waveform in sheriff_memory_primary_connections.json.',
        },
        'strobe_connections': {
            'STSTB': 'CPU 4B LS08 inputs4/5 are CPU SYNC pin19 and inverted CP2 phi1 TTL pin17 through 4D input13/output12. STSTB = SYNC AND NOT phi1_TTL. This is a level equation, not an electrical pulse-width qualification.',
            'RAMSTB_n': 'CPU 3F LS00 input1 is STSTB, input2 is buffered A14, output3 is DRAM STSTB / RAMSTB_n. RAMSTB_n = NOT(A14 AND STSTB). It clears readback 4F/4G and READY 3D; MEMR is a separate neighboring status net.',
            'disable': '3E pin11=CPU WR RD cross-sheet net; pin12=NOT HREAD_n; output13=HREAD_n AND NOT CPU_WR_RD_level.',
            'CAS_n': '5B LS32 pin1=CP2 CAS_n pin25, pin2=disable, output3 to all 4116 CAS pin15: raw_CAS_n OR disable.',
            'RAS_n': '5B LS32 pin12=CP2 RAS_n pin27, pin13=disable, output11 to all 4116 RAS pin4: raw_RAS_n OR disable.',
            'WE_n': 'First mux 1Y pin7 goes to the shared 4116 write input. C0/C2/C3 are high; C1 pin5 comes from 3F LS00 output6. Its inputs4/5 carry inverted CPU WR_n (4D LS04 output4) and buffered A14. Thus WE_n is NOT(A14 AND NOT CPU_WR_n) during BA=01 and high otherwise. Raw mux/strobe phase and DRAM write-edge ordering remain open.',
            'write_predicate': 'At the drawn pin levels: HREAD_n AND NOT COMADR_n AND A14 AND NOT CPU_WR_n. This is a Boolean enable predicate, not the effective DRAM commit edge.',
        },
        'RAMSTB_boolean_rows': [
            {'A14': a, 'SYNC': sync, 'phi1_TTL': phi,
             'STSTB': sync & (1 ^ phi),
             'RAMSTB_n': 1 ^ (a & sync & (1 ^ phi))}
            for a in (0, 1) for sync in (0, 1) for phi in (0, 1)
        ],
        'raw_clock_connections': {
            'CAS_n': 'I/O 4A LS164 QB pin4 -> 4B LS04 input3, output4 -> CP2 pin25. raw_CAS_n = NOT 4A_QB.',
            'RAS_n': 'I/O 4A QB pin4 -> 4F LS00 input5; 4A QD pin6 -> input4; output6 -> 2I LS04 input1, output2 -> CP2 pin27. raw_RAS_n = 4A_QB AND 4A_QD.',
            'COMADR_n': 'I/O 4A QG pin12 -> 4B LS04 input11, output10 -> CP2 pin29. COMADR_n = NOT 4A_QG; CPU-board inversion makes the LS153 A selector equal 4A_QG.',
            'HREAD_n': 'I/O 4I QC pin12 through 2I LS04 input5/output6 -> CP2 pin31, consistent with the earlier serializer derivation.',
            'phase_limit': 'These are connected zero-delay equations at the drawn pins. Complete 4A clock/data and 4I counter initialization/reset order remain to be derived before assigning master ticks or valid-data edges.',
        },
        'viewport_recovery': [
            {'page': 35, 'box': [3000, 3300, 4140, 4790], 'viewport': '_checks/manuals/bandido-first-mux-connected.png'},
            {'page': 35, 'box': [3650, 3340, 5088, 4640], 'viewport': '_checks/manuals/bandido-mux-cpu-left.png'},
            {'page': 36, 'box': [0, 3520, 1680, 4890], 'viewport': '_checks/manuals/bandido-mux-controls.png'},
            {'page': 36, 'box': [1360, 2810, 2410, 3450], 'viewport': '_checks/manuals/bandido-ras-cas-gates.png'},
            {'page': 36, 'box': [1430, 4370, 2320, 5010], 'viewport': '_checks/manuals/bandido-3e-output-rd-start.png'},
            {'page': 36, 'box': [1450, 4040, 3000, 4530], 'viewport': '_checks/manuals/bandido-rd-common-left.png'},
            {'page': 36, 'box': [3000, 4040, 4700, 4650], 'viewport': '_checks/manuals/bandido-rd-common-right.png'},
            {'page': 36, 'box': [4200, 3690, 4930, 4780], 'viewport': '_checks/manuals/bandido-rd-r4-connected.png'},
            {'page': 36, 'box': [0, 4200, 1550, 5550], 'viewport': '_checks/manuals/bandido-3e-cpuwr-connected.png'},
            {'page': 35, 'box': [2600, 3150, 4250, 4550], 'viewport': '_checks/manuals/bandido-write-source-upper.png'},
            {'page': 35, 'box': [2600, 4300, 4250, 5600], 'viewport': '_checks/manuals/bandido-write-source-middle.png'},
            {'page': 35, 'box': [2600, 5300, 4250, 6250], 'viewport': '_checks/manuals/bandido-write-source-bottom.png'},
            {'page': 35, 'box': [1000, 4730, 2700, 6250], 'viewport': '_checks/manuals/bandido-wr-inverter-connected.png'},
            {'page': 35, 'box': [3160, 3520, 3540, 3970], 'viewport': '_checks/manuals/bandido-3f-write-pins.png'},
            {'page': 33, 'box': [1420, 2290, 3440, 2760], 'viewport': '_checks/manuals/bandido-raw-ram-clock-pins.png'},
            {'page': 33, 'box': [3050, 2020, 4480, 2920], 'viewport': '_checks/manuals/bandido-4a-phase-connected.png'},
            {'page': 33, 'box': [3040, 2290, 3740, 2730], 'viewport': '_checks/manuals/bandido-4a-output-pins.png'},
        ],
        'limits': [
            'Related Bandido connectivity remains conditional for the exact Sheriff revision.',
            'Raw COMADR/HREAD/RAS/CAS clock-network phase and CPU WR RD generation remain open.',
            'Boolean WE qualification is derived; effective DRAM write timing, access/refresh and serializer capture/sample ordering remain open.',
            'No physical delay, full READY response, production RTL, MAME graphics or release pass is asserted.',
        ],
        'production_rtl_changed': False,
        'physical_memory_timing_qualified': False,
        'quartus_executed': False,
        'script_sha256': digest(__file__),
    }
    path = Path('docs/evidence/sheriff_memory_mux_connections.json')
    path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'physical_selector_rows': 4, 'RD_common_input': 'R4 1k pull-up', 'physical_memory_timing_qualified': False, 'report': path.as_posix()}))


if __name__ == '__main__':
    main()
