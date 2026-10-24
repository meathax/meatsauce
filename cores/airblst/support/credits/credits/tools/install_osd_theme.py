"""Remove the retired MEATCORES menu artwork using its original source backup."""
import argparse
from pathlib import Path

def remove(core):
    core = core.resolve()
    source = core/'sys/osd.v'
    source.resolve().relative_to(core)
    if '// MEATCORES_MAIN_OSD_THEME' not in source.read_text(encoding='utf-8'):
        print('Stock OSD already active.')
        return
    backup = source.with_name('osd.v.meatcores-original')
    if not backup.is_file():
        raise ValueError(f'Missing original OSD backup: {backup}; restore the matching stock sys/osd.v')
    original = backup.read_bytes()
    if b'MEATCORES_MAIN_OSD_THEME' in original:
        raise ValueError('Backup also contains artwork; restore the matching stock OSD')
    source.write_bytes(original)
    print(f'Restored stock OSD: {source}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, default=Path.cwd())
    parser.add_argument('--remove', action='store_true', help='Compatibility flag; removal is now the only operation')
    args = parser.parse_args()
    try:
        remove(args.core)
    except (OSError, ValueError) as error:
        parser.exit(1, f'OSD restoration: {error}\n')
