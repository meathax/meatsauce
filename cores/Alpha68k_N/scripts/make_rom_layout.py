"""Define and materialize the byte-addressed loader contract from audited images."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
SLOTS = {
    'maincpu': (0x00100, 0x20000, 'block RAM; even byte is 68000 D15:8'),
    'audiocpu': (0x20100, 0x10000, 'block RAM'),
    'proms': (0x30100, 0x00300, 'block RAM; R/G/B PROMs in source order'),
    'clut_proms': (0x30400, 0x00200, 'block RAM; low/high nibbles in source order'),
    'color_proms': (0x31000, 0x02000, 'block RAM; absent for Stingray'),
    'mcu': (0x33000, 0x01000, 'block RAM; independent full raw firmware dump'),
    'sprites': (0x40000, 0x60000, 'SDRAM byte addresses 0x00000..0x5ffff'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    source = json.loads((ROOT / 'research/rom_manifest.json').read_text())
    contract = {
        'format_version': 1, 'byte_order': 'raw bytes; a 16-bit transport carries first byte on D7:0',
        'header': {'bytes': 256, 'magic_hex': '4136384e', 'version_offset': 4,
                   'profile_offset': 5, 'profiles': {'kyros': 0, 'kyrosj': 1, 'sstingry': 2}},
        'download_bytes': 0xa0000, 'padding': 0,
        'slots': {name: {'base': base, 'capacity': size, 'storage': storage}
                  for name, (base, size, storage) in SLOTS.items()},
        'limits': ['Kyros full bootleg MCU firmware is a candidate, not an original-board fidelity claim',
                   'The overlapping MAME mcu region is never executed as a clean firmware image'],
        'sets': {},
    }
    for index, (name, info) in enumerate(source.items()):
        assert contract['header']['profiles'][name] == index
        payload = bytearray(contract['download_bytes'])
        payload[:6] = bytes.fromhex('4136384e') + bytes([1, index])
        regions = []
        occupied = []
        for region in info['regions']:
            logical = 'mcu' if region['name'] == 'alpha8511' else region['name']
            path = region['path']
            expected = region['sha256']
            provenance = 'audited MAME region image'
            if logical == 'mcu' and name != 'sstingry':
                full = next(x for x in region['loads'] if x['name'] == 'kyros_68705u3.bin')
                path = full['raw_path']
                raw = (ROOT / path).read_bytes()
                assert hashlib.sha1(raw).hexdigest() == full['sha1'], f'Raw MCU identity changed: {path}'
                expected = digest(raw)
                provenance = 'separate 4096-byte bootleg MCU dump; BAD_DUMP flags retained in ROM manifest'
            data = (ROOT / path).read_bytes()
            assert digest(data) == expected, f'ROM identity changed: {path}'
            base, capacity, storage = SLOTS[logical]
            assert len(data) <= capacity
            assert not any(base < end and start < base+len(data) for start, end in occupied)
            occupied.append((base, base+len(data)))
            payload[base:base+len(data)] = data
            regions.append({'name': logical, 'source_path': path, 'bytes': len(data),
                            'sha256': expected, 'base': base, 'storage': storage,
                            'provenance': provenance})
        target = ROOT / 'roms' / name / 'download.bin'
        target.write_bytes(payload)
        contract['sets'][name] = {'path': target.relative_to(ROOT).as_posix(),
                                  'sha256': digest(payload), 'bytes': len(payload),
                                  'driver_sha256': info['driver_sha256'], 'regions': regions}
        print(name, len(payload), digest(payload))
    (ROOT / 'rom_layout.json').write_text(json.dumps(contract, indent=2)+'\n', encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
