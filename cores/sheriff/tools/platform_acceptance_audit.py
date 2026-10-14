#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Validate current Sheriff MRA and identify retained platform evidence source scope.

Read-only for ROMs, MRA, RTL and saved evidence. Exit zero means the static
MRA contract passes; it never means full simulation, timing or release passes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SUFFIXES = {'.sv', '.v', '.vhd', '.qip', '.qsf', '.qpf', '.sdc'}
EVIDENCE = [
    'sheriff_controls_protocol.json', 'sheriff_display_features.json',
    'sheriff_gamma_guard.json', 'sheriff_hiscore_powerup.json',
    'sheriff_wrapper_analog_boot.json',
    'sheriff_current_wrapper_centered_gameplay.json',
]

def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_identity(root):
    rows = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    hashes = {name: digest(root / name) for name in sorted(rows)
              if name and Path(name).suffix.lower() in SOURCE_SUFFIXES}
    require(hashes and 'Nintendo8080.sv' in hashes, 'Git core source scope is missing')
    return hashes


def validate_mra(root, xml):
    manifest = json.loads((root / 'docs/evidence/rom_manifest.json').read_text(encoding='utf-8-sig'))
    require(manifest['set'] == 'sheriff' and manifest['parent'], 'Wrong ROM manifest')
    chips = manifest['chips']
    for tag, expected in {'setname': 'sheriff', 'parent': 'sheriff', 'mameversion': '0289',
                          'rbf': 'Nintendo8080', 'rotation': 'vertical (ccw)',
                          'players': '2 (alternating)', 'num_buttons': '1'}.items():
        require(xml.findtext(tag) == expected, 'MRA metadata mismatch: ' + tag)
    roms = xml.findall('rom')
    require(len({r.get('index') for r in roms}) == len(roms), 'Duplicate ROM download index')
    require({r.get('index') for r in roms} == {'0', '3'}, 'Unexpected ROM download indices')
    rom = xml.find("rom[@index='0']")
    require(rom.get('zip') == 'sheriff.zip', 'Wrong parent archive')
    parts = list(rom)
    expected_names = [c['name'] for c in chips]
    require([p.get('name') for p in parts if p.get('name')] == expected_names,
            'ROM order differs from verified parent manifest')
    require(len(parts) == 12, 'Wrong ROM part count')
    require(parts[9].attrib == {'repeat': '7168'} and (parts[9].text or '').strip() == '00',
            'CPU-to-sound gap must be explicit 7168 zero bytes')
    payload = bytearray()
    layout = []
    lookup = {c['name']: c for c in chips}
    for part in parts:
        start = len(payload)
        if part.get('name'):
            name = part.get('name')
            require(Path(name).name == name, 'Unsafe chip name')
            chip = lookup[name]
            data = (root / 'roms/sheriff' / name).read_bytes()
            require(len(data) == chip['size'] == 1024, 'Wrong chip size: ' + name)
            require(part.get('crc') == chip['crc32'] == f'{zlib.crc32(data):08x}',
                    'CRC mismatch: ' + name)
            require(hashlib.sha1(data).hexdigest() == chip['sha1'], 'SHA1 mismatch: ' + name)
            payload.extend(data)
            layout.append(dict(name=name, offset=start, bytes=len(data), crc32=chip['crc32']))
        else:
            payload.extend(bytes.fromhex(part.text) * int(part.get('repeat', '1'), 0))
            layout.append(dict(padding=True, offset=start, bytes=len(payload)-start))
    require(len(payload) == 0x4800, 'Wrong packed ROM length')
    require(payload == (root / 'roms/sheriff.bin').read_bytes(), 'Packed simulation ROM differs')
    require(layout[10]['offset'] == 0x4000 and layout[11]['offset'] == 0x4400,
            'Sound/PROM load offsets differ from board contract')
    descriptor = xml.find("rom[@index='3']")
    require(descriptor.attrib == {'index': '3', 'md5': 'none'} and len(descriptor) == 1,
            'Wrong high-score download descriptor')
    config = bytes.fromhex(descriptor.findtext('part'))
    expected_header = (50400000, 255, 2, 2, 1, 255, 4, 0)
    require(len(config) == 24 and struct.unpack('>IHHHHHBB', config[:16]) == expected_header,
            'Wrong high-score configuration header')
    require(struct.unpack('>IBBBB', config[16:]) == (0x60f1, 3, 0, 0, 0),
            'Wrong high-score signature/address/length')
    require(xml.find('nvram').attrib == {'index': '4', 'size': '3'}, 'Wrong NVRAM upload contract')
    wrapper = (root / 'Nintendo8080.sv').read_text(encoding='utf-8-sig')
    menu = re.search(r'"J,([^";]+);"', wrapper)
    require(menu and xml.find('buttons').get('names') == menu.group(1),
            'MRA buttons differ from actual HPS menu order')
    require('P1O[9:8],Lives,3,4,5,6;' in wrapper and
            'P1O[10],Cabinet,Upright,Cocktail;' in wrapper,
            'Lives/cabinet menu is absent')
    require('wire [7:0] input3={!status[10],~status[40:36],status[9:8]};' in wrapper,
            'DIP input port differs from audited mapping')
    require('ioctl_index==0' in wrapper and 'ioctl_index==3 || ioctl_index==4' in wrapper,
            'Wrapper ROM/persistence reset contract differs')
    return dict(static_contract_pass=True, parent='sheriff', mameversion='0289',
                payload_bytes=len(payload), payload_sha256=hashlib.sha256(payload).hexdigest(),
                layout=layout, buttons=menu.group(1).split(','),
                lives_defaults=3, cabinet_default='Upright',
                mod_contract='Sheriff-only static board; no mod input or index1 download is consumed.',
                hiscore=dict(config_bytes=24, address='0x60f1', bytes=3, upload_index=4),
                limitation='CRC/layout and static HPS metadata validation; no fresh FPGA execution.')


def evidence_bridge(root, name, current):
    path = root / 'docs/evidence' / name
    doc = json.loads(path.read_text(encoding='utf-8-sig'))
    maps = []
    def visit(value, location=''):
        if isinstance(value, dict):
            found = {k: v for k, v in value.items() if k in current and isinstance(v, str)
                     and re.fullmatch('[0-9a-f]{64}', v)}
            if found:
                maps.append((location, found))
            for key, nested in value.items():
                if isinstance(nested, (dict, list)):
                    visit(nested, location + '/' + str(key))
        elif isinstance(value, list):
            for index, nested in enumerate(value):
                if isinstance(nested, (dict, list)):
                    visit(nested, location + '/' + str(index))
    visit(doc)
    summaries = []
    for location, saved in maps:
        mismatches = [key for key, sha in saved.items() if current[key] != sha]
        summaries.append(dict(location=location, saved_source_files=len(saved),
                              current_source_matches=not mismatches, mismatches=mismatches))
    return dict(path=path.relative_to(root).as_posix(), sha256=digest(path),
                scope=doc.get('scope'), source_maps=summaries,
                full_source_match=any(len(saved) == len(current) and
                                      all(current[k] == v for k, v in saved.items())
                                      for _, saved in maps),
                acceptance_extended=False,
                limitation='Matching hashes preserve only the saved evidence scope; no new runtime coverage.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = ROOT.resolve()
    output = args.output.resolve()
    require(output.is_relative_to(root), 'Evidence output must remain inside core workspace')
    output.parent.mkdir(parents=True, exist_ok=True)
    report = dict(scope='Current Sheriff static MRA/platform evidence audit',
                  checked_utc=datetime.now(timezone.utc).isoformat(),
                  audit_script_sha256=digest(__file__), exit_code=1,
                  full_wrapper_acceptance_pass=False, timing_resource_pass=False,
                  release_gate_pass=False, simulation_executed=False, quartus_used=False, rbf_built=False)
    try:
        current = source_identity(root)
        report['source_sha256'] = current
        report['source_identity'] = hashlib.sha256(json.dumps(current, sort_keys=True).encode()).hexdigest()
        report['mra_sha256'] = digest(root / 'releases/Sheriff.mra')
        report['manifest_sha256'] = digest(root / 'docs/evidence/rom_manifest.json')
        report['mra'] = validate_mra(root, ET.parse(root / 'releases/Sheriff.mra').getroot())
        report['retained_evidence'] = [evidence_bridge(root, name, current) for name in EVIDENCE]
        require(current == source_identity(root), 'Source changed during bounded audit; receipt is invalid')
        report['exit_code'] = 0
    except (ValueError, OSError, KeyError, ET.ParseError, struct.error) as exc:
        report['error'] = str(exc)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('scope', 'source_identity', 'exit_code',
                      'full_wrapper_acceptance_pass', 'timing_resource_pass', 'rbf_built') if key in report}
                     | dict(evidence=output.as_posix(), error=report.get('error'))))
    return report['exit_code']


if __name__ == '__main__':
    sys.exit(main())
