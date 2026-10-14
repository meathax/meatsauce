#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Record related Bandido sound-enable connectivity without inventing delays."""
import hashlib
import json
from pathlib import Path
from PIL import Image


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    base = Path('_checks/manuals')
    views = []
    for page, box, name in [
        (37, [500, 2200, 4300, 5000], 'bandido-monostable-enable-connected.png'),
        (38, [2750, 4800, 4200, 5300], 'bandido-sound-title.png'),
    ]:
        source = base/f'bandido-sound-{page}.png'
        path = base/name
        Image.open(source).crop(box).save(path)
        views.append({'page': page, 'box': box, 'original': source.as_posix(),
                      'viewport': path.as_posix()})
    report = {
        'scope': 'Related Exidy Bandido audio drawing, conditional connectivity only; not exact Sheriff propagation or trigger qualification.',
        'drawing': {'title': 'BANDIDO AUDIO BOARD', 'owner_printed': 'EXIDY INC.',
                    'date_printed': '1-6-80', 'number_printed': '77-3368-11',
                    'local_pdf': (base/'bandido-1980.pdf').as_posix()},
        'connections': {
            'U5_second_half': '74123 B10 from J12-6; A9 grounded; CLR_n11 high; timing R2 33K and C4 33uF; Q5/Qbar12.',
            'U5_first_half': '74123 B2 from J12-4; A1 grounded; CLR_n3 from J12-6; timing R3 33K and C5 33uF; Qbar4.',
            'SN_enable': 'U7 pin9 at R4 10K pullup-to-5V node, clamped by CR6 to U5 Qbar12 and CR5 to U5 Qbar4.',
            'SN_VCO_mode': 'U5 Q5 reaches U7 pin22.',
            'SN_mixer_B': 'U5 Q5 through U6 inverter9->8 reaches U7 pin25.',
            'SN_external_VCO_voltage': 'U5 Qbar4 through U6 inverter5->6 reaches U7 pin16.',
        },
        'viewports': views,
        'evidence_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), base/'bandido-1980.pdf',
                          *[Path(v['original']) for v in views], *[Path(v['viewport']) for v in views]]},
        'limitations': ['Shared trigger/clear wire and diode combination do not establish an enable pulse or its duration.',
                       'Actual Sheriff board revision, connector signal polarity, 74123 trigger edges, diode thresholds and propagation remain to be qualified.',
                       'Do not transplant the MAME zero-duration stop/start setter pulse into RTL from this drawing alone.',
                       'No production RTL edit, native replay or whole-audio pass.'],
        'physical_enable_pulse_qualified': False,
    }
    output = Path('docs/evidence/sheriff_sound_enable_network.json')
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': output.as_posix(), 'physical_enable_pulse_qualified': False}))


if __name__ == '__main__':
    main()
