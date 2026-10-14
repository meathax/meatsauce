"""Locate opaque MAME layers at retained actual RTL combat mismatch pixels."""
from pathlib import Path
import hashlib, json
from pixel_provenance import trace

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / 'sim/captures/kyros/combat3600_v2'
NATIVE = ROOT / 'sim/captures/rtl/kyros_combat3600'
FIELDS = [900, 1020, 2100, 2220, 3180, 3300]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if __name__ == '__main__':
    image_path = ROOT / 'roms/kyros/download.bin'
    image = image_path.read_bytes()
    result = {'scope': 'Offline ownership diagnostic of six retained actual combat fields. Final MAME RAM explains its atomic image, not the native temporal cause.',
              'download_sha256': digest(image_path), 'fields': []}
    for field in FIELDS:
        stem = f'frame_{field:06d}'
        expected_path = REF / (stem + '.display.rgb')
        actual_path = NATIVE / (stem + '.rgb')
        ram_path = REF / (stem + '.sprites.bin')
        expected, actual, ram = expected_path.read_bytes(), actual_path.read_bytes(), ram_path.read_bytes()
        assert len(expected) == len(actual) == 256 * 224 * 3
        pixels = []
        for offset in range(0, len(expected), 3):
            if expected[offset:offset+3] == actual[offset:offset+3]:
                continue
            x, y = (offset // 3) % 256, (offset // 3) // 256
            opaque = [layer for layer in trace(image, ram, x, y + 16) if layer['pen']]
            owner = opaque[-1] if opaque else None
            pixels.append({'x': x, 'display_y': y, 'raw_y': y + 16,
                           'expected_rgb': list(expected[offset:offset+3]),
                           'actual_rgb': list(actual[offset:offset+3]), 'owner': owner,
                           'owner_matches_reference': owner is not None and owner['rgb'] == list(expected[offset:offset+3])})
        result['fields'].append({'field': field, 'mismatch_count': len(pixels),
                                 'all_owners_match_reference': all(p['owner_matches_reference'] for p in pixels),
                                 'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in [expected_path, actual_path, ram_path]},
                                 'pixels': pixels})
    output = ROOT / 'research/combat_hud_ownership.json'
    output.write_text(json.dumps(result, indent=2) + '\n')
    for field in result['fields']:
        owners = sorted({(hex(p['owner']['tile_address']), hex(p['owner']['position_address'])) for p in field['pixels'] if p['owner']})
        print(field['field'], field['mismatch_count'], field['all_owners_match_reference'], owners)
    raise SystemExit(0 if all(f['all_owners_match_reference'] for f in result['fields']) else 1)
