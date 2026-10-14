"""Bounded opcode/bus evidence around a native Sheriff raster IRQ boundary."""
from pathlib import Path
import argparse,csv,json
p=argparse.ArgumentParser()
p.add_argument('--frame',type=int,required=True)
p.add_argument('--mame',type=Path,required=True)
p.add_argument('--rtl',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();edge=a.frame*819200
rtl=[];mame=[]
with (a.rtl/'bus.csv').open() as f:
    for r in csv.DictReader(f):
        tick=int(r['tick'])
        if edge-800<=tick<=edge+800:rtl.append(r)
with (a.mame/'irq_program_reads.csv').open() as f:
    for r in csv.DictReader(f):
        tick=round(float(r['time'])*50400000)
        if edge-800<=tick<=edge+800:mame.append({**r,'master_tick':tick})
report={'scope':'first-divergence diagnostic, not an IRQ or release pass',
        'frame':a.frame,'raster_edge_master_tick':edge,'rtl_bus':rtl,'mame_program_reads':mame}
a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
