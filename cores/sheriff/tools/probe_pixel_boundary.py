# SPDX-License-Identifier: GPL-2.0-or-later
"""Report an actual RAM write around one native raster pixel, without waivers.

Uses a narrowly captured real MAME write PC and the existing real-RTL binary
write trace. No ROM data are exported; the opcode is decoded locally only.
"""
import argparse
import csv
import hashlib
import json
import struct
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--mame',type=Path,required=True)
p.add_argument('--rtl',type=Path,required=True)
p.add_argument('--frame',type=int,required=True)
p.add_argument('--x',type=int,required=True)
p.add_argument('--y',type=int,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--prefix-reference',type=Path,help='Verify the focused MAME capture against an existing complete capture')
a=p.parse_args()
assert 'Average speed:' in (a.mame/'stdout.log').read_text()
features=json.loads((a.mame/'capture_features.json').read_text())
assert abs(features['write_probe_frame']-a.frame)<=1
address=0x4000+a.y*32+(a.x>>3)
sample=(a.frame-1)*819200+(((a.y-240)&255)*320+a.x)*10+8
mame=[]
edge=(a.frame-1)*819200
irq_edges={'vblank':edge,'previous_mid_screen':edge-358400}
irq={name:{'edge':tick,'mame':[],'rtl':[]} for name,tick in irq_edges.items()}
for r in csv.DictReader((a.mame/'write_pc.csv').open()):
    tick=float(r['time'])*50400000
    for name,trace in irq.items():
        if 0x7fc0<=int(r['address'])<0x8000 and abs(tick-trace['edge'])<1500:
            trace['mame'].append({'tick':tick,'delta_from_edge':tick-trace['edge'],'address':int(r['address']),'data':int(r['data']),'pc':int(r['pc'])})
    if int(r['address'])==address and abs(tick-sample)<2000:
        mame.append({'tick':tick,'delta_from_sample':tick-sample,'data':int(r['data']),'pc':int(r['pc'])})
rtl=[];done=False
with (a.rtl/'memory_writes.bin').open('rb') as f:
    while not done and (chunk:=f.read(11*65536)):
        # The long replay may still be live, but this window must be complete.
        for tick,addr,data in struct.iter_unpack('<QHB',chunk[:len(chunk)//11*11]):
            if tick>sample+2000:done=True;break
            if addr==address and abs(tick-sample)<2000:
                rtl.append({'tick':tick,'delta_from_sample':tick-sample,'data':data,'master_clock_mod25':tick%25})
            if 0x7fc0<=addr<0x8000:
                for trace in irq.values():
                    if abs(tick-trace['edge'])<1500:trace['rtl'].append({'tick':tick,'delta_from_edge':tick-trace['edge'],'address':addr,'data':data})
assert done, 'Actual RTL trace has not passed the complete pixel window'
rom=(Path(__file__).resolve().parents[1]/'roms/sheriff.bin').read_bytes()[:0x4000]
def boundary_instruction(pc):
    if pc+3>len(rom):return None
    if rom[pc]==0x3a:
        return {'address':pc,'instruction':'LDA address','length':3,'t_states':13}
    if rom[pc] in (0x01,0x11,0x21,0x31):
        pair=('B','D','H','SP')[rom[pc]>>4]
        return {'address':pc,'instruction':f'LXI {pair},immediate','length':3,'t_states':10}
    if rom[pc] in (0xc2,0xca,0xd2,0xda,0xe2,0xea,0xf2,0xfa):
        name=('JNZ','JZ','JNC','JC','JPO','JPE','JP','JM')[(rom[pc]-0xc2)//8]
        return {'address':pc,'instruction':f'{name} address','length':3,'t_states':10}
    return None

irq_return_boundaries=[]
for name,trace in irq.items():
    pairs={}
    for source in ('mame','rtl'):
        rows=trace[source]
        for first,second in zip(rows,rows[1:]):
            if first['delta_from_edge']>=0 and first['address']==second['address']+1:
                pairs[source]={'pc':(first['data']<<8)|second['data'],
                               'stack_write_ticks':[first['tick'],second['tick']]}
                break
    if len(pairs)==2:
        reference_pc=pairs['mame']['pc']
        boundary={'irq':name,**pairs,'cause_qualified':False}
        # Decode at the saved PC, never treat immediate bytes as opcodes.
        for source,other in (('mame','rtl'),('rtl','mame')):
            pc=pairs[source]['pc'];instruction=boundary_instruction(pc)
            if instruction:
                boundary[f'instruction_at_{source}_return']=instruction
                boundary[f'{other}_return_is_after_this_instruction']=pairs[other]['pc']==pc+instruction['length']
        irq_return_boundaries.append(boundary)
irq_call_candidates=[]
reads_path=a.mame/'irq_program_reads.csv'
if reads_path.exists():
    reads=list(csv.DictReader(reads_path.open()))
    for boundary in irq_return_boundaries:
        reference_pc=boundary['mame']['pc'];edge=irq[boundary['irq']]['edge']
        for rows in zip(reads,reads[1:],reads[2:]):
            site=int(rows[0]['address']);tick=float(rows[0]['time'])*50400000
            if abs(tick-edge)>2000 or site+3>len(rom):continue
            if [int(row['address']) for row in rows]!=[site,site+1,site+2]:continue
            if rom[site]!=0xcd or int.from_bytes(rom[site+1:site+3],'little')!=reference_pc:continue
            irq_call_candidates.append({'irq':boundary['irq'],'address':site,
                'instruction':'CALL address','target':reference_pc,'t_states':17,
                'program_read_ticks':[float(row['time'])*50400000 for row in rows],
                'program_read_delta_from_irq':[float(row['time'])*50400000-edge for row in rows],
                'cause_qualified':False})
for r in mame:
    pc=r['pc'];decoded=[]
    if 0<pc<=len(rom):
        op=rom[pc-1]
        if 0x70<=op<=0x77 and op!=0x76:decoded.append({'address':pc-1,'instruction':'MOV M,'+'BCDEHLA'[op-0x70 if op<0x76 else 6],'t_states':7})
        if op in (0x34,0x35):decoded.append({'address':pc-1,'instruction':'INR M' if op==0x34 else 'DCR M','t_states':10})
        if op in (0x02,0x12):decoded.append({'address':pc-1,'instruction':'STAX B' if op==0x02 else 'STAX D','t_states':7})
    if pc>=2 and rom[pc-2]==0x36:decoded.append({'address':pc-2,'instruction':'MVI M,immediate','t_states':10})
    if pc>=3 and rom[pc-3] in (0x32,0x22):decoded.append({'address':pc-3,'instruction':'STA address' if rom[pc-3]==0x32 else 'SHLD address','t_states':13 if rom[pc-3]==0x32 else 16})
    r['local_instruction_candidates']=decoded
report={'scope':'Measured write timing at one native raster pixel; diagnostic only',
        'frame':a.frame,'x':a.x,'y':a.y,'address':address,'sample_tick':sample,
        'mame_capture':str(a.mame),'rtl_capture':str(a.rtl),'mame_writes':mame,'rtl_writes':rtl,
        'preceding_irq_stack_windows':irq,
        'irq_return_boundaries':irq_return_boundaries,
        'irq_call_candidates':irq_call_candidates,
        'strict_graphics_gate_pass':False,
        'limits':['Instruction candidates require source/PC validation before a timing classification',
                  'This report does not waive pixels or establish physical DRAM fetch timing']}
if a.prefix_reference:
    from qualify_input_scheduler_boundary import is_exact_prefix
    prefix={name:is_exact_prefix(a.mame/name,a.prefix_reference/name)
            for name in ('io.csv','video_writes.csv')}
    assert all(prefix.values()), 'Focused observer changed the original MAME trace'
    files=[a.mame/name for name in ('capture_features.json','stdout.log','io.csv',
                                  'video_writes.csv','write_pc.csv','irq_program_reads.csv')]
    files += [a.prefix_reference/name for name in prefix]
    digests={}
    for path in files:
        with path.open('rb') as f:digests[str(path)]=hashlib.file_digest(f,'sha256').hexdigest()
    report['focused_capture_provenance']={'reference':str(a.prefix_reference),
        'exact_byte_prefix':prefix,'capture_features':features,'sha256':digests,
        'mame_process_exit':None,
        'limit':'Terminal capture marker verified; the original launcher did not preserve its child exit code'}
a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
