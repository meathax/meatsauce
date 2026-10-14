"""Generate physical coin/start/action stimulus for real two/four-player combat."""
import argparse
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--players', type=int, choices=(2, 4), required=True)
    p.add_argument('--end-frame', type=int, default=3600)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    assert a.end_frame > 1900
    assert not a.output.exists(), 'Retain existing input evidence; choose a new file'
    rows = ['cycle,p1,p2,p3,p4,coin,dips,system']
    previous = None
    for frame in range(a.end_frame + 1):
        pads = [0xff] * 4
        coin = 0xff
        system = 0xfdff if a.players == 4 else 0xffff
        for player in range(a.players):
            if 620 + 12 * player <= frame < 624 + 12 * player:
                coin &= ~(1 << player)
            if 680 <= frame < 684:
                system &= ~(1 << (0, 1, 4, 5)[player])
            if 692 <= frame < 836 and (frame - 692) % 12 < 6:
                pads[player] &= ~0x18  # right + attack during character select
            if 900 <= frame < a.end_frame:
                pads[player] &= ~0x08  # advance naturally toward the enemies
                pads[player] &= ~(0x02 if (frame // 60 + player) % 2 else 0x01)
                if (frame - 900 + player * 9) % 18 < 6:
                    pads[player] &= ~0x10  # repeated presses, not a held attack
                if (frame - 900 + player * 45) % 240 < 4:
                    pads[player] &= ~0x20  # jump
                if 1800 + player * 12 <= frame < 1804 + player * 12:
                    pads[player] &= ~0x40  # special, with the game's normal cost
        ports = (*pads, coin, 0xffff, system)
        if ports != previous:
            cycle = frame * 1732608 + (60 if frame else 0)
            rows.append(str(cycle) + ',' + ','.join(f'0x{x:04x}' for x in ports))
            previous = ports
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text('\n'.join(rows) + '\n', newline='\n')
    print(f'{a.players} active players, {len(rows)-1} physical-port events: {a.output}')


if __name__ == '__main__':
    main()
