"""Bounded retained-audio inventory; no simulation, state changes or PCM-phase requirement."""
from pathlib import Path
import json,hashlib,wave,struct,math
R=Path(__file__).resolve().parents[1]
C=Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def path_of(s):
 s=s.replace("\\","/")
 if s.startswith("/mnt/d/"):s="D:/"+s[7:]
 p=Path(s)
 if not p.is_absolute():p=R/p
 return p
def strings(v):
 if isinstance(v,str):yield v
 elif isinstance(v,list):
  for x in v:yield from strings(x)
 elif isinstance(v,dict):
  for x in v.values():yield from strings(x)
receipts=[R/"research/kyros_sound_acceptance_contract_audit.json"]
for pattern in ["kyros_punch*1081*.json","kyros_*combat3301*.json","kyros_*idle_death3601*.json","kyros*sound*qualification*.json"]:
 hits=sorted((R/"research").glob(pattern));assert len(hits)<=30,pattern
 receipts.extend(hits)
receipts=list(dict.fromkeys(receipts))
dirs={R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive",
R/"sim/captures/kyrosj/kyrosj_sound_fulltap720",
R/"sim/captures/kyros/gameplay",R/"sim/captures/kyrosj/gameplay"}
pins=[];refs=[]
for p in receipts:
 if not p.exists():continue
 j=json.loads(p.read_text());pins.append({"path":str(p),"sha256":sha(p)})
 for v in strings(j):
  if len(v)>350 or not any(t in v for t in ["captures/","captures\\"]):continue
  q=path_of(v)
  if q.is_dir():dirs.add(q)
  elif q.is_file():dirs.add(q.parent)
  refs.append(v)
sources={}
for rel in ["rtl/alpha68kn_mixer.sv","rtl/alpha68kn_soundchips.sv","rtl/alpha68kn_audio.sv","sim/system_main.cpp"]:
 p=C/rel;ls=p.read_text().splitlines()
 matches=[i for i,l in enumerate(ls) if any(t in l.lower() for t in ["pcm","wav","48000","satur","clip","gain","route","/10","/20","3*","6*","sample_rate"])]
 if rel.endswith("mixer.sv"):matches=list(range(len(ls)))
 elif rel.endswith("system_main.cpp"):matches=matches[:16]
 chosen=set()
 for i in matches:
  chosen.update(range(max(0,i-2),min(len(ls),i+4)))
 sources[rel]={"sha256":sha(p),"lines":[{"line":i+1,"text":ls[i]} for i in sorted(chosen)]}
inventory=[]
for d in sorted(dirs,key=str):
 if not d.exists():continue
 for p in sorted(d.iterdir()):
  if not p.is_file() or p.suffix.lower() not in [".wav",".pcm",".raw"]:continue
  e={"path":str(p),"bytes":p.stat().st_size,"sha256":sha(p)}
  if p.suffix.lower()==".wav":
   try:
    with wave.open(str(p),"rb") as w:
     e.update({"channels":w.getnchannels(),"sample_width_bytes":w.getsampwidth(),"sample_rate":w.getframerate(),"samples":w.getnframes(),"duration_seconds":w.getnframes()/w.getframerate()})
     b=w.readframes(w.getnframes())
    if e["sample_width_bytes"]==2:
     a=struct.unpack("<"+"h"*(len(b)//2),b);e.update({"minimum":min(a),"maximum":max(a),"endpoint_saturation_samples":sum(v in [-32768,32767] for v in a),"nonzero_samples":sum(v!=0 for v in a),"rms":math.sqrt(sum(v*v for v in a)/len(a))})
   except Exception as ex:e["reader_error"]=str(ex)
  inventory.append(e)
out={"scope":"Bounded known-run retained audio inventory and actual route-source excerpts. No waveform phase identity, semantic action closure or new replay.","input_receipts":pins,"capture_directories_checked":[str(p) for p in sorted(dirs,key=str)],"retained_audio":inventory,"source":sources,"retained_reference_paths":sorted(set(refs))[:80],"fullP5pass":False}
p=R/"research/kyros_audio_recordings_inventory.json";p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"receipts":len(pins),"directories":len(dirs),"audio":inventory,"sources":sources,"receipt_sha256":sha(p)}))
