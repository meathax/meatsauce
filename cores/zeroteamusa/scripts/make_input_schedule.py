"""Create repeatable physical coin/start/control inputs; never patch game state."""
from pathlib import Path
import argparse,csv
p=argparse.ArgumentParser()
p.add_argument('--mode',choices=['2p','4p-slots','4p-shared'],default='2p')
p.add_argument('--start-frame',type=int,default=620)
p.add_argument('--end-frame',type=int,default=1800)
p.add_argument('--out',default='sim/inputs/play-2p.csv')
a=p.parse_args()
assert a.start_frame>=4 and a.end_frame>a.start_frame+80
system={'2p':0xffff,'4p-slots':0xfdff,'4p-shared':0xfaff}[a.mode]
players=1 if a.mode=='2p' else 4
state=[0xff]*5+[0xffff,system]
rows={0:state.copy()}
def at(frame,index,value):
    # Events are emitted in ascending order below; equal frames merge ports.
    events.setdefault(frame,[]).append((index,value))
events={}
for player in range(players):
    frame=a.start_frame+player*12
    coinbit=player if a.mode!='4p-shared' else player%2
    at(frame,4,0xff^(1<<coinbit));at(frame+4,4,0xff)
start=a.start_frame+players*12+8
startbits=[0,1,4,5][:players]
pressed=system
for bit in startbits:pressed &= ~(1<<bit)
at(start,6,pressed);at(start+4,6,system)
# Bounded controller exercise: move right, attack repeatedly, then release.
# Completion/progression must be observed in real game state, not inferred
# from these requests or the frame limit.
for frame in range(start+16,a.end_frame,12):
    for player in range(players):
        at(frame,player,0xe7);at(min(frame+6,a.end_frame),player,0xf7)
for player in range(players):at(a.end_frame,player,0xff)
for frame,changes in sorted(events.items()):
    for index,value in changes:state[index]=value
    rows[60+frame*(512*282*12)]=state.copy()
out=Path(a.out);out.parent.mkdir(parents=True,exist_ok=True)
with out.open('w',newline='') as f:
    w=csv.writer(f,lineterminator='\n');w.writerow(['cycle','p1','p2','p3','p4','coin','dips','system'])
    for cycle,values in sorted(rows.items()):w.writerow([cycle]+[hex(x) for x in values])
print(f'{out}: {len(rows)} physical input events, {a.mode}; gameplay remains to be observed')
