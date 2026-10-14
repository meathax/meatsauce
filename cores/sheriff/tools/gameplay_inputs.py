"""Emit normal coin/start and independent movement/aim/fire inputs.

No game RAM/state is modified. MAME qualifies coverage before the expensive
RTL replay; these are controller actions, not a replacement game simulation.
"""
from pathlib import Path
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--restart',action='store_true')
parser.add_argument('--cocktail',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
target=root/('sim/inputs_cocktail.csv' if args.cocktail else 'sim/inputs_restart.csv' if args.restart else 'sim/inputs_extended.csv')
aims=(0x10,0x50,0x40,0x60,0x20,0xa0,0x80,0x90)
moves=(1,4,2,8)
rows=['frame,p0,p1,p2,dip','0,0,0,0,252','600,0,0,128,252',
      '605,0,0,0,252','690,0,0,4,252','750,0,0,0,252']
if args.cocktail:
    rows=['frame,p0,p1,p2,dip','0,0,0,0,124','600,0,0,128,124',
          '605,0,0,0,124','620,0,0,128,124','625,0,0,0,124',
          '690,0,0,8,124','750,0,0,0,124']
for frame in range(1000,6000,4):
    elapsed=frame-1000
    aim=aims[(elapsed//24)%8]
    movement=moves[(elapsed//30)%4] if elapsed<1500 else 0
    fire=1 if (elapsed//4)%2==0 else 0
    if args.cocktail:
        other=aims[(elapsed//24+4)%8]|moves[(elapsed//30+2)%4]
        rows.append(f'{frame},{aim|movement},{other},{3*fire},124')
    else:
        rows.append(f'{frame},{aim|movement},0,{fire},252')
rows.append(f'6000,0,0,0,{124 if args.cocktail else 252}')
if args.restart:
    rows.extend(['6200,0,0,128,252','6205,0,0,0,252',
                 '6290,0,0,4,252','6350,0,0,0,252'])
    for frame in range(6450,7200,4):
        elapsed=frame-6450
        rows.append(f'{frame},{aims[(elapsed//24)%8]},0,{int((elapsed//4)%2==0)},252')
    rows.append('7200,0,0,0,252')
target.write_text('\n'.join(rows)+'\n')
print(f'{target}: {len(rows)-1} normal input events; scoring/round coverage still to qualify')
