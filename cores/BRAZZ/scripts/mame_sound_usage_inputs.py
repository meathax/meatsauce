import random,sys
N=int(sys.argv[1]); r=random.Random(20261006)
ev={}
def put(f,tag,name,v): ev.setdefault(f,[]).append((tag,name,v))
P=":P1_P2"; S=":SYSTEM"
put(900,S,"Coin 1",1); put(908,S,"Coin 1",0)
put(940,S,"1 Player Start",1); put(948,S,"1 Player Start",0)
f=1000
dirs=["P1 Left","P1 Right","P1 Up","P1 Down"]
while f<N:
    d=r.choice([None,"P1 Right","P1 Right","P1 Left","P1 Up","P1 Down"])
    L=r.randint(8,40)
    if d: put(f,P,d,1); put(f+L,P,d,0)
    # buttons: mash A,B,C pattern
    b=r.choice(["P1 Button 1","P1 Button 1","P1 Button 2","P1 Button 3"])
    put(f+2,P,b,1); put(f+6,P,b,0)
    if r.random()<0.1:  # A+B (emergency / magic)
        put(f+8,P,"P1 Button 1",1); put(f+8,P,"P1 Button 2",1); put(f+12,P,"P1 Button 1",0); put(f+12,P,"P1 Button 2",0)
    f+=L+r.randint(2,10)
# periodic coin + starts (continue/restart/2P join)
for k in range(1500,N,1700):
    put(k,S,"Coin 1",1); put(k+8,S,"Coin 1",0); put(k+30,S,"1 Player Start",1); put(k+38,S,"1 Player Start",0)
for k in range(5000,N,6000):
    put(k,S,"Coin 1",1); put(k+8,S,"Coin 1",0); put(k+30,S,"2 Players Start",1); put(k+38,S,"2 Players Start",0)
for fr in sorted(ev):
    for tag,name,v in ev[fr]:
        print(fr,tag,name,v)
