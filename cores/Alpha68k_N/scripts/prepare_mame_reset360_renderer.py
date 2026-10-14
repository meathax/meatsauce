"""Prepare a timed diagnostic from MAME's recorded emulated master ticks."""
from pathlib import Path
import csv,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'sim/captures/kyros/reset_raster361_v4'
out=ROOT/'sim/captures/diagnostics/reset360_mame_timed_renderer'
out.mkdir(parents=True,exist_ok=True)
clocks={int(x['frame']):x for x in csv.DictReader((source/'raster_clock.csv').open())}
start,end=int(clocks[330]['master_ticks']),int(clocks[360]['master_ticks'])
assert end-start==30*811008
assert all((int(clocks[f]['vpos']),int(clocks[f]['hpos']))==(240,0) for f in [330,360])
ram=bytearray((source/'frame_000330.sprites.bin').read_bytes())
writes=[]
unknown=[]
with (source/'events.csv').open() as f:
 for x in csv.DictReader(f):
  t,addr=int(x['master_ticks']),int(x['address'])
  if not(start<t<=end and 0x40000<=addr<0x42000):continue
  if x['area'] not in ['positions','tiles1','tiles2','tiles3']:
   unknown.append(x);continue
  off=(addr-0x40000)&~1;mask=int(x['mask']);value=int(x['data'])
  if mask&0xff00:ram[off]=(value>>8)&255
  if mask&0xff:ram[off+1]=value&255
  writes.append((t-start,off//2,ram[off]*256+ram[off+1]))
assert not unknown
assert all(a[0]<b[0] for a,b in zip(writes,writes[1:]))
assert bytes(ram)==(source/'frame_000360.sprites.bin').read_bytes()
native=ROOT/'sim/captures/rtl/kyros_reset_background421'
assert (source/'frame_000330.sprites.bin').read_bytes()==(native/'frame_000330.sprites.bin').read_bytes()
assert (source/'frame_000360.sprites.bin').read_bytes()==(native/'frame_000360.sprites.bin').read_bytes()
with (out/'writes.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['step','word_address','merged_word']);w.writerows(writes)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
meta={'source_parent':'fb5f1c8','scope':'Recorded MAME CPU writes projected onto unchanged actual renderer; no actual native CPU acceptance','source':str(source),'mame_start_tick':start,'mame_end_tick':end,'write_count':len(writes),'final_ram_reconstructed_equal':True,'native_start_end_ram_equal':True,'clock_projection':'Absolute MAME machine.time.as_ticks(48000000) (integer floor) minus recorded frame330 notifier tick; no pixel/frame shifts or fitted phase. Sub-master-clock fractions are not recorded.','elapsed_start':24330233,'elapsed_end':48660473,'elapsed_scope':'The same recorded native330 counter phase used by the successful native timed fixture; duration exactly30 fields. MAME notifier and native boundary both start blanking at240,0.','background':64,'background_scope':'Fixed target snapshot background64, not replayed background history','refresh_scope':'Same isolated fixture/controller cadence; not restored full native controller state','sha256':{str(p):sha(p) for p in [source/'events.csv',source/'raster_clock.csv',source/'frame_000330.sprites.bin',source/'frame_000360.sprites.bin',out/'writes.csv']}}
(ROOT/'research/kyros_reset360_mame_timed_renderer_preparation.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({k:meta[k] for k in ['write_count','mame_start_tick','mame_end_tick','final_ram_reconstructed_equal','native_start_end_ram_equal']}))
