"""Produce compact reference evidence; never classify these MAME runs as RTL passes."""
from pathlib import Path
import array
import csv
import hashlib
import json
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    report = {'kind': 'MAME reference evidence, not RTL verification', 'runs': [],
              'renderer_decision': 'Start with live strip RAM reads per line; visible writes forbid an unqualified whole-frame latch',
              'pending': ['Late-stage/ending fixtures', 'Non-default DIP and cocktail fixtures',
                          'Physical IRQ edges and unresolved board timing/analog/watchdog questions']}
    script_hash = hashlib.sha256((ROOT/'sim/mame/capture.lua').read_bytes()).hexdigest()
    for game in ['kyros', 'kyrosj', 'sstingry']:
        for mode in ['attract', 'gameplay']:
            root = ROOT/'sim/captures'/game/mode
            manifest = json.loads((root/'manifest.json').read_text())
            assert manifest['frames'] == 1800 and manifest['script_sha256'] == script_hash
            for item in manifest['artifacts']:
                data = (root/item['path']).read_bytes()
                assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
            timing = {}
            for row in csv.DictReader((root/'write_histogram.csv').open()):
                assert 0 <= int(row['scanline']) < 264
                if row['segment'] != 'post_start':
                    continue
                area = timing.setdefault(row['area'], {'visible': 0, 'blank': 0})
                area['visible' if 16 <= int(row['scanline']) < 240 else 'blank'] += int(row['count'])
            with wave.open(str(root/'audio.wav')) as wav:
                assert wav.getnchannels() == 1 and wav.getsampwidth() == 2
                samples = array.array('h', wav.readframes(wav.getnframes()))
                if sys.byteorder != 'little':
                    samples.byteswap()
                audio = {'rate': wav.getframerate(), 'samples': len(samples),
                         'peak': max(abs(s) for s in samples),
                         'full_scale_samples': sum(s in (-32768, 32767) for s in samples)}
            states = list(csv.DictReader((root/'frame_states.csv').open()))
            assert len(states) == 1800
            report['runs'].append({'set': game, 'mode': mode, 'frames': 1800,
                'manifest': (root/'manifest.json').relative_to(ROOT).as_posix(),
                'manifest_sha256': hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest(),
                'snapshot_count': len(manifest['snapshots']),
                'unique_snapshot_hashes': len({x['rgb_sha256'] for x in manifest['snapshots']}),
                'main_pc_samples': len({x['main_pc'] for x in states}),
                'dip_state': manifest['dip_state'], 'write_timing': timing, 'audio': audio})
    target = ROOT/'research/reference_capture_manifest.json'
    target.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8', newline='\n')
    print('Verified six 1800-frame MAME recordings, all artifact identities, beam bins and audio.')
    print('Evidence:', target)


if __name__ == '__main__':
    main()
