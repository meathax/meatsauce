"""Audit merged ROMs against the supplied driver and save bounded online evidence."""
from pathlib import Path
import concurrent.futures
import hashlib
import html
import json
import re
import subprocess
import urllib.request
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(r'D:\Arcade\AI\mame289\src\mame\alpha\alpha68k_n.cpp')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def audit_roms():
    source = SOURCE.read_text(encoding='utf-8')
    output = {}
    for setname, archive in [('kyros', 'kyros.zip'), ('kyrosj', 'kyros.zip'), ('sstingry', 'sstingry.zip')]:
        block = re.search(r'ROM_START\(\s*' + setname + r'\s*\)(.*?)ROM_END', source, re.S).group(1)
        regions = []
        entries = []
        current = None
        previous = None
        roms = zipfile.ZipFile(ROOT / 'roms' / archive)
        by_crc = {}
        for info in roms.infolist():
            by_crc.setdefault(f'{info.CRC:08x}', []).append(info.filename)
        for line in block.splitlines():
            match = re.search(r'ROM_REGION(?:16_BE)?\s*\(\s*(0x[0-9a-f]+|\d+)\s*,\s*"([^"]+)"', line, re.I)
            if match:
                current = {'name': match[2], 'bytes': int(match[1], 0), 'loads': []}
                regions.append(current)
            match = re.search(r'ROM_LOAD(16_BYTE|16_WORD_SWAP)?\s*\(\s*"([^"]+)"\s*,\s*(0x[0-9a-f]+|\d+)\s*,\s*(0x[0-9a-f]+|\d+)\s*,\s*(?:BAD_DUMP\s*)?CRC\(([0-9a-f]+)\)\s*SHA1\(([0-9a-f]+)\)', line, re.I)
            if match:
                kind, name, offset, length, crc, digest = match.groups()
                candidates = by_crc.get(crc.lower(), [])
                selected = next((n for n in candidates if Path(n).name == name), candidates[0] if candidates else None)
                if selected is None:
                    raise ValueError(f'{setname}: missing {name} CRC {crc}')
                data = roms.read(selected)
                if hashlib.sha1(data).hexdigest() != digest.lower():
                    raise ValueError(f'{setname}: SHA1 mismatch {selected}')
                if f'{zlib.crc32(data):08x}' != crc.lower():
                    raise ValueError(f'{setname}: CRC32 mismatch {selected}')
                previous = {'name': name, 'zip_entry': selected, 'crc32': crc.lower(), 'sha1': digest.lower(),
                            'bytes': len(data), 'kind': 'ROM_LOAD' + (kind or ''), 'offset': int(offset, 0),
                            'length': int(length, 0), 'continuations': [], 'bad_dump': 'BAD_DUMP' in line}
                current['loads'].append(previous)
                entries.append(previous)
            match = re.search(r'ROM_CONTINUE\s*\(\s*(0x[0-9a-f]+|\d+)\s*,\s*(0x[0-9a-f]+|\d+)', line, re.I)
            if match:
                previous['continuations'].append({'offset': int(match[1], 0), 'length': int(match[2], 0)})
            if 'NO_DUMP' in line or 'ROM_RELOAD' in line or 'ROM_COPY' in line:
                raise ValueError(f'Add explicit support for driver directive: {line}')
        dest = ROOT / 'roms' / setname
        dest.mkdir(exist_ok=True)
        # Preserve independent firmware files: MAME deliberately overlays the two Kyros dumps.
        for region in regions:
            if region['name'] in ('mcu', 'alpha8511'):
                rawdir = dest / 'mcu_dumps'
                rawdir.mkdir(exist_ok=True)
                for load in region['loads']:
                    rawpath = rawdir / load['name']
                    rawpath.write_bytes(roms.read(load['zip_entry']))
                    load['raw_path'] = rawpath.relative_to(ROOT).as_posix()
        for region in regions:
            image = bytearray(region['bytes'])
            for load in region['loads']:
                data = roms.read(load['zip_entry'])
                if load['kind'] == 'ROM_LOAD16_WORD_SWAP':
                    data = b''.join(data[i:i+2][::-1] for i in range(0, len(data), 2))
                stride = 2 if load['kind'] == 'ROM_LOAD16_BYTE' else 1
                cursor = 0
                for segment in [{'offset': load['offset'], 'length': load['length']}, *load['continuations']]:
                    end = segment['offset'] + segment['length'] * stride
                    if end - stride + 1 > len(image):
                        raise ValueError(f'{setname} {region["name"]}: region overflow')
                    image[segment['offset']:end:stride] = data[cursor:cursor+segment['length']]
                    cursor += segment['length']
                if cursor != len(data):
                    raise ValueError(f'{setname}: ROM consumption mismatch {load["name"]}')
            target = dest / (region['name'] + '.bin')
            target.write_bytes(image)
            region['path'] = target.relative_to(ROOT).as_posix()
            region['sha256'] = sha(image)
        output[setname] = {'archive': 'roms/' + archive, 'driver_sha256': sha(SOURCE.read_bytes()),
                           'regions': regions, 'roms_checked': len(entries),
                           'region_bytes': sum(r['bytes'] for r in regions),
                           'audit': 'Every required file CRC32, SHA1 and consumed length matched driver'}
        print('ROM_AUDIT', setname, len(entries), 'files', [(r['name'], r['bytes']) for r in regions], flush=True)
    (ROOT / 'research/rom_manifest.json').write_text(json.dumps(output, indent=2) + '\n', encoding='utf-8')


URLS = {
    'mt1148': 'https://mametesters.org/view.php?id=1148',
    'mt1149': 'https://mametesters.org/view.php?id=1149&nbn=1',
    'mt3912': 'https://mametesters.org/view.php?id=3912',
    'mt5959': 'https://mametesters.org/view.php?id=5959&nbn=3',
    'imperfect_timing': 'https://wiki.mamedev.org/index.php/MIT',
    'mame0289_driver': 'https://raw.githubusercontent.com/mamedev/mame/mame0289/src/mame/alpha/alpha68k_n.cpp',
    'mame_master_driver': 'https://raw.githubusercontent.com/mamedev/mame/master/src/mame/alpha/alpha68k_n.cpp',
    'driver_history': 'https://api.github.com/repos/mamedev/mame/commits?path=src/mame/alpha/alpha68k_n.cpp&per_page=100',
    'prior_driver_history': 'https://api.github.com/repos/mamedev/mame/commits?path=src/mame/drivers/alpha68k_n.cpp&per_page=100',
    'mame0138u3': 'https://raw.githubusercontent.com/mamedev/mame/mame0138u3/whatsnew.txt',
    'mame0164': 'https://raw.githubusercontent.com/mamedev/mame/mame0164/whatsnew.txt',
    'mame0242': 'https://www.mamedev.org/?p=511',
    'mame0281': 'https://www.mamedev.org/?p=555',
    'mame0215': 'https://www.mamedev.org/releases/whatsnew_0215.txt',
    'mame0088u7': 'https://wiki.mamedev.org/index.php/MAME_0.88u7',
    'jotego_t48': 'https://www.patreon.com/jotego/posts/extermination-76880945',
    'contributing': 'https://raw.githubusercontent.com/wiki/MiSTer-devel/Wiki_MiSTer/Contributing-a-Core-to-MiSTer-FPGA.md',
}


def fetch(item):
    name, url = item
    target = ROOT / 'research/online' / (name + ('.json' if 'api.github' in url else '.txt'))
    try:
        if target.exists():
            data = target.read_bytes()
        else:
            request = urllib.request.Request(url, headers={'User-Agent': 'Alpha68kN-local-research/1.0'})
            data = urllib.request.urlopen(request, timeout=25).read()
            target.write_bytes(data)
        result = {'id': name, 'url': url, 'path': target.relative_to(ROOT).as_posix(),
                  'sha256': sha(data), 'bytes': len(data), 'status': 'saved'}
        text = data.decode('utf-8', errors='replace')
        if name.endswith('history'):
            rows = json.loads(text)
            matches = [{'sha': x['sha'], 'date': x['commit']['author']['date'], 'subject': x['commit']['message']}
                       for x in rows if re.search('kyros|ssting|stingray|mcu|clock|audio|sprite|palette|flip', x['commit']['message'], re.I)]
            result['relevant_commits'] = matches
            print('HISTORY', name, [(x['sha'][:12], x['subject'].splitlines()[0]) for x in matches], flush=True)
        elif name.startswith('mt'):
            text = html.unescape(re.sub('<[^>]+>', ' ', text))
            text = re.sub(r'\s+', ' ', text)
            start = text.find('Viewing Issue')
            print('ISSUE', name, text[start:start+2700], flush=True)
        elif name in ('mame0289_driver', 'mame_master_driver'):
            result['matches_local_driver'] = text.replace('\r\n', '\n') == SOURCE.read_text(encoding='utf-8')
            print('DRIVER_PIN', name, result['matches_local_driver'], result['sha256'], flush=True)
        else:
            clean = html.unescape(re.sub('<[^>]+>', ' ', text))
            matches = [clean[max(0, m.start()-75):m.end()+320].replace('\n', ' ')
                       for m in re.finditer('kyros|sstingry|Super Stingray|03912|05959|01148', clean, re.I)]
            print('EVIDENCE', name, matches[:8], flush=True)
        return result
    except Exception as e:
        print('FETCH_LIMIT', name, str(e), flush=True)
        return {'id': name, 'url': url, 'status': 'unavailable', 'error': str(e)}


def main():
    audit_roms()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(fetch, URLS.items()))
    (ROOT / 'research/online_manifest.json').write_text(json.dumps(rows, indent=2) + '\n', encoding='utf-8')
    source = SOURCE.read_text(encoding='utf-8')
    print('MACHINE_CONFIGURATION')
    for owner, fn in [('alpha68k_N_state','kyros'), ('sstingray_state','sstingry'), ('alpha68k_N_state','sound_iomap'), ('sstingray_state','sound_map'), ('kyros_state','init_kyros'), ('kyros_state','init_kyrosj')]:
        match = re.search(r'void ' + owner + r'::' + fn + r'\([^)]*\)\s*\{(.*?)\n\}', source, re.S)
        if match:
            print(owner + '::' + fn, re.sub(r'\s+', ' ', match[1]))
    print('GFX_LAYOUTS')
    for match in re.finditer(r'static const gfx_layout\s+(\w+)\s*=\s*\{(.*?)\};', source, re.S):
        print(match[1], re.sub(r'\s+', ' ', match[2]))
    print('INIT_AND_CONFIG_LINES')
    for i, line in enumerate(source.splitlines(), 1):
        if re.search(r'M68000|Z80\(|I8748|set_refresh|set_raw|set_size|set_visarea|periodic_int|set_vblank_int|m_tile_|m_coin_id|m_microcontroller_id|GAME\(', line):
            print(i, line.strip())
    print('SOURCE_VERSION')
    for p in [SOURCE.parents[3]/'src/version.cpp', SOURCE.parents[3]/'makefile']:
        if p.exists():
            print(p, [l for l in p.read_text(errors='replace').splitlines() if re.search('VERSION|0.289|MAME_VERSION', l)][:8])
    print('TOOLS')
    for p in [Path(r'D:\q17\quartus\bin64\quartus_sh.exe'), Path(r'D:\q17\bin64\quartus_sh.exe'), Path(r'D:\Arcade\AI\mame289\mame.exe')]:
        print(str(p), p.exists())
    print('MAME_DIR_TOP', [p.name for p in SOURCE.parents[3].iterdir()][:40])


if __name__ == '__main__':
    main()
