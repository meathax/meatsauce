"""Independent timed MAME-write replay for the bitmap board's live scanout.

MAME's whole-frame renderer and the PCB's raster have different semantics
when the CPU writes after the affected row has passed. This oracle consumes
MAME transactions, never FPGA-generated RAM or prerecorded FPGA pixels.
"""
from pathlib import Path
import argparse
import csv
import heapq
import json
import struct
import time
from datetime import datetime, timezone

parser=argparse.ArgumentParser()
parser.add_argument('--mame',type=Path,required=True)
parser.add_argument('--rtl',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--watch-receipt',type=Path)
parser.add_argument('--watch-launch',type=Path)
parser.add_argument('--final-frame',type=int)
args=parser.parse_args()
watch=bool(args.watch_receipt)
if watch and (not args.watch_launch or not args.final_frame):
    parser.error('Watch mode requires receipt, launch identity and final field')
if not watch and (args.watch_launch or args.final_frame):
    parser.error('Watch launch/final field require --watch-receipt')

def producer_live():
    # Query the owned Windows wrapper, including exact creation FILETIME. Never
    # infer liveness from a PID file, unchanged output or an observation timeout.
    import ctypes
    from ctypes import wintypes
    launch=json.loads(args.watch_launch.read_text(encoding='utf-8-sig'))
    if not isinstance(launch,dict):raise ValueError('Expected one launch identity')
    raw=launch['started'];base=datetime.fromisoformat(raw[:19]).replace(tzinfo=timezone.utc)
    fraction=raw[20:].rstrip('Z') if '.' in raw else ''
    delta=base-datetime(1601,1,1,tzinfo=timezone.utc)
    expected=(delta.days*86400+delta.seconds)*10000000+int((fraction+'0000000')[:7])
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
    kernel.OpenProcess.restype=wintypes.HANDLE
    kernel.GetProcessTimes.argtypes=[wintypes.HANDLE]+[ctypes.POINTER(wintypes.FILETIME)]*4
    kernel.GetExitCodeProcess.argtypes=[wintypes.HANDLE,ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    handle=kernel.OpenProcess(0x1000,False,int(launch['pid']))
    if not handle:return False
    try:
        times=[wintypes.FILETIME() for _ in range(4)];code=wintypes.DWORD()
        if not kernel.GetProcessTimes(handle,*[ctypes.byref(t) for t in times]):
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.GetExitCodeProcess(handle,ctypes.byref(code)):
            raise ctypes.WinError(ctypes.get_last_error())
        actual=(times[0].dwHighDateTime<<32)|times[0].dwLowDateTime
        return actual==expected and code.value==259
    finally:kernel.CloseHandle(handle)

def wait_for_export(file):
    while not file.exists() or file.stat().st_size<256*224*3+15:
        if args.watch_receipt.exists():
            raise RuntimeError(f'Producer terminal before complete export: {file}')
        if not producer_live():
            raise RuntimeError('Owned producer missing before terminal receipt')
        time.sleep(2)

def save_progress(reason):
    result={'scope':'Diagnostic observation of exported native fields against stored timed MAME writes; not live frame-gated MAME equivalence',
        'checks':checks,'total_mismatch_pixels':sum(c['mismatch_count'] for c in checks),
        'expected_fields':expected_fields,'exit_reason':reason,'native_receipt':str(args.watch_receipt),
        'native_launch':str(args.watch_launch),'reference_uses_fpga_ram_or_pixels':False,
        'limits':['Only completed exported images are observed; no intermediate-field or all-domain acceptance.',
            'Native execution is not controlled by this observer; archived boundary RAM remains available.',
            'Physical RAM/READY/serializer and absolute CPU/raster phase remain unqualified.']}
    temporary=args.output.with_suffix(args.output.suffix+'.tmp')
    temporary.write_text(json.dumps(result,indent=2)+'\n')
    temporary.replace(args.output)
root=Path(__file__).resolve().parents[1]
prom=(root/'roms/sheriff/82s137.3l').read_bytes()
def chronological_events(path, kind):
    """Read one ordered CPU stream without storing a long capture in memory."""
    previous=None
    with path.open() as f:
        for ordinal,row in enumerate(csv.DictReader(f)):
            address=int(row['address'])&0x7fff
            if kind==0:
                if not 0x4000<=address<0x6000:continue
                event=(float(row['time'])*50400000,0,address-0x4000,int(row['data']))
            else:
                if row['kind']!='out' or (address&7)!=6:continue
                event=(float(row['time'])*50400000,1,0,int(row['data']))
            if previous is not None and event<previous:
                raise ValueError(f'Nonchronological stream: {path}, row {ordinal+2}')
            previous=event
            yield event

# Both streams use the same CPU-local time. Merge with the former tuple-sort
# tie ordering, while checking each source rather than silently reordering it.
events=heapq.merge(chronological_events(args.mame/'video_writes.csv',0),
                  chronological_events(args.mame/'io.csv',1))
event=next(events,None)
ram=bytearray(8192); control=0; checks=[]
if watch:
    expected_fields=sorted(set([n for n in range(1,min(4,args.final_frame)+1)]
        +list(range(60,args.final_frame+1,60))+[args.final_frame]))
    files=[args.rtl/f'frame_{number:05d}.ppm' for number in expected_fields]
else:files=sorted(args.rtl.glob('frame_*.ppm'))
for file in files:
    if watch:wait_for_export(file)
    number=int(file.stem.split('_')[1]); pixels=file.read_bytes().split(b'\n',3)[3]
    if len(pixels)!=256*224*3:raise ValueError(f'Incomplete frame: {file}')
    mismatch=[]
    for y in range(16,240):
        for x in range(256):
            # Initial beam y=240. ce_pixel is emitted on phase 9 and consumes
            # the synchronous RAM read registered on phase 8 of that pixel.
            sample=(number-1)*819200+(((y-240)&255)*320+x)*10+8
            while event is not None and event[0]<=sample:
                _,kind,address,data=event
                if kind==0:ram[address]=data
                else:control=data
                event=next(events,None)
            mask=255 if control&32 else 0
            sx=x^mask;sy=y^mask
            color=prom[(sy>>3)*32+(sx>>3)]
            mode=(control>>3)&3
            if mode==2 or (mode==1 and not color&8):color=(control&7)^7
            if mode==3:color=7
            if not ram[sy*32+(sx>>3)]&(1<<(sx&7)):color=0
            expected=bytes((255 if color&1 else 0,255 if color&2 else 0,255 if color&4 else 0))
            offset=((y-16)*256+x)*3
            if pixels[offset:offset+3]!=expected:
                mismatch.append((x,y,pixels[offset:offset+3].hex(),expected.hex()))
    checks.append({'frame':number,'mismatch_count':len(mismatch),'first_mismatches':mismatch[:8]})
    if watch:
        reason='first_captured_rgb_mismatch' if mismatch else 'observing'
        save_progress(reason)
        print(json.dumps({'frame':number,'mismatch_count':len(mismatch),'status':reason}),flush=True)
        if mismatch:raise SystemExit(1)
if watch:
    while not args.watch_receipt.exists():
        if not producer_live():raise RuntimeError('Owned producer missing before terminal receipt')
        time.sleep(2)
    receipt=json.loads(args.watch_receipt.read_text(encoding='utf-8-sig'))
    if receipt['exit_code']!=0 or receipt['frames_requested']!=args.final_frame or receipt['source_changed_during_run']:
        raise RuntimeError('Native receipt failed source/exit/final-field checks')
    save_progress('complete_exported_fields_match')
    raise SystemExit(0)
result={
    'scope':'Independent live bitmap/PROM scanout comparison from timed MAME CPU writes',
    'master_hz':50400000,'pixel_hz':5040000,'frame_master_ticks':819200,
    'inputs':str(args.mame),'rtl_pixels':str(args.rtl),
    'reference_uses_fpga_ram_or_pixels':False,
    'checks':checks,'total_mismatch_pixels':sum(c['mismatch_count'] for c in checks),
    'limits':['Does not establish the physical DRAM byte-fetch/arbitration schedule beyond this functional streaming model',
              'Only captured native frames are compared; other release acceptance items remain separate'],
}
args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'frames':len(checks),'total_mismatch_pixels':result['total_mismatch_pixels'],
                  'nonzero_frames':sum(bool(c['mismatch_count']) for c in checks),
                  'first_nonzero':[c for c in checks if c['mismatch_count']][:8],
                  'report':str(args.output)},indent=2))
