"""Compare the first naturally executed RTL GPU packet with unchanged MAME bodies."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
def require(value,message):
    if not value:raise RuntimeError(message)
def sha(data):return hashlib.sha256(data).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--run-id');args=parser.parse_args()
    activity=json.loads((ROOT/'docs/boot_activity_report.json').read_text())
    run_id=args.run_id or activity['run_id']
    require(run_id==activity['run_id'] and activity['terminal_snapshot'],'terminal activity report must identify this run')
    private=ROOT/'sim/obj_dir/boot_probe/activity'/run_id
    before=private/'first_gpu_request';after=private/'first_gpu_packet'
    state=json.loads(before.joinpath('state.json').read_text())
    require(state['gpu_packets']==0 and state['gpu_trace_requests']==0,'first request snapshot only')
    first_end=json.loads(after.joinpath('state.json').read_text())
    for name,counter in [('gpu_bus.csv','gpu_trace_requests'),('video_mmio.csv','video_trace_writes'),
                         ('concurrent_graphics_writes.csv','concurrent_trace_writes')]:
        require(activity['graphics_context_traces'][name]['records']==first_end[counter],
                'context extends past first drawing packet; use a bounded-context model or first-packet probe')
    gpu=list(csv.DictReader((private/'gpu_bus.csv').open()))
    concurrent=list(csv.DictReader((private/'concurrent_graphics_writes.csv').open()))
    for name in ['gpu_bus.csv','video_mmio.csv','concurrent_graphics_writes.csv']:
        data=private.joinpath(name).read_bytes();expected=activity['graphics_context_traces'][name]
        require(len(data)==expected['bytes'] and sha(data)==expected['sha256'],'trace changed: '+name)
    memories={0x03800000:bytearray(before.joinpath('texture.bin').read_bytes()),
              0x04000000:bytearray(before.joinpath('framebuffer.bin').read_bytes())}
    require(all(len(m)==8*1024*1024 for m in memories.values()),'complete pre-GPU RAM')
    packet_address=int(gpu[0]['address'],16)
    require(packet_address==0x03800000,'qualified first queue packet at index zero')
    packet=[int.from_bytes(memories[0x03800000][i*2:i*2+2],'little') for i in range(32)]
    first_fb=next(r for r in gpu if int(r['address'],16)>=0x04000000)
    lane=0 if int(first_fb['strobe'],16)==3 else 2
    draw_dest=int(first_fb['address'],16)+lane-0x04000000-((packet[1]&1023)+(packet[2]&511)*1024)*2
    # This first boot packet is an untextured fill; concurrent texture uploads cannot change its pixels.
    require(packet[0]==0x1110 and draw_dest==0x400000,'qualified first fill and bank-one destination')
    require(all(int(r['address'],16)>=0x03800040 and int(r['address'],16)<0x04000000 for r in concurrent),
            'concurrent writes must not modify first packet or framebuffer')
    events=[(int(r['clock']),0,r) for r in concurrent]+[(int(r['clock']),1,r) for r in gpu]
    stores=[];reads=0
    for clock,kind,r in sorted(events,key=lambda x:x[:2]):
        require(r['error']=='0','captured memory error')
        address=int(r['address'],16);base=0x03800000 if address<0x04000000 else 0x04000000
        off=address-base;memory=memories[base];strobe=int(r['strobe'],16)
        require(0<=off<=len(memory)-4 and off%4==0,'aligned mapped request')
        write=kind==0 or r['write']=='1';value=int(r['data' if kind==0 else 'value'],16)
        if write:
            for i in range(4):
                if strobe&(1<<i):memory[off+i]=(value>>(i*8))&255
            if kind==1:
                require(base==0x04000000 and strobe in (3,12),'GPU halfword framebuffer store')
                lane=0 if strobe==3 else 2;stores.append((off+lane,(value>>(lane*8))&65535))
        else:
            require(value==int.from_bytes(memory[off:off+4],'little'),'read context mismatch at clock '+str(clock))
            reads+=1
    for base,name in [(0x03800000,'texture.bin'),(0x04000000,'framebuffer.bin')]:
        require(memories[base]==after.joinpath(name).read_bytes(),'trace replay terminal '+name)
    out=ROOT/'sim/obj_dir/gpu_boot_compare'/run_id;out.mkdir(parents=True,exist_ok=True)
    subprocess.run([sys.executable,'-X','utf8',str(ROOT/'scripts/gpu_reference.py')],cwd=ROOT,check=True,capture_output=True,text=True)
    compiler=Path(r'D:\vibes\fpga\toolchains\msys64\ucrt64\bin\g++.exe')
    exe=out/'gpu_boot_oracle.exe'
    subprocess.run([str(compiler),'-std=c++17','-O2','-fwrapv',str(ROOT/'sim/video/gpu_boot_oracle.cpp'),'-o',str(exe)],cwd=ROOT,check=True)
    result=subprocess.run([str(exe),str(before),str(out),'0',str(draw_dest)],cwd=ROOT,check=True,capture_output=True,text=True)
    expected=[tuple(map(int,line.split())) for line in out.joinpath('mame_stores.txt').read_text().splitlines()]
    require(stores==expected,'exact ordered MAME stores differ from natural RTL')
    expected_frame=out.joinpath('mame_framebuffer.bin').read_bytes()
    require(expected_frame==after.joinpath('framebuffer.bin').read_bytes(),'full MAME framebuffer differs from natural RTL')
    report={'run_id':run_id,'result':'pass','packet_flags':packet[0],'draw_destination':draw_dest,
            'gpu_requests':len(gpu),'verified_reads':reads,'exact_ordered_pixel_stores':len(stores),
            'concurrent_texture_writes':len(concurrent),'framebuffer_bytes':len(expected_frame),
            'framebuffer_sha256':sha(expected_frame),'oracle':'unchanged pinned MAME drawing bodies',
            'source_sha256':sha((ROOT/'sim/video/gpu_boot_oracle.cpp').read_bytes()),
            'script_sha256':sha(Path(__file__).read_bytes()),'reference':json.loads((ROOT/'docs/gpu_reference.json').read_text()),
            'acceptance':'first natural original-ROM GPU packet only; not attract/gameplay or physical memory timing'}
    (ROOT/'docs/gpu_boot_comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS natural boot GPU:',len(stores),'exact MAME stores;',reads,'verified reads; full 8MiB framebuffer; concurrent texture writes',len(concurrent))
    return 0
if __name__=='__main__':raise SystemExit(main())
