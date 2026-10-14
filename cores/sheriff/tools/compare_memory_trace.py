"""Stream the complete Sheriff RAM write sequence against MAME, retaining first divergence.

MAME timestamps instruction-atomic writes; FPGA timestamps real bus edges.
Address/data/order must still match. Timing offsets are reported separately.
"""
from pathlib import Path
from collections import Counter, deque
import argparse, csv, hashlib, json, struct
p=argparse.ArgumentParser()
p.add_argument('--mame',type=Path,required=True)
p.add_argument('--rtl',type=Path,required=True)
p.add_argument('--report',type=Path,required=True)
a=p.parse_args()
history=deque(maxlen=6);first=None;differences=0;matched=0;count=0;offsets=Counter();addresses=Counter()
sequences={name:{} for name in ('mame','rtl')}
byte_values=[bytes([value]) for value in range(256)]
def sequence(name,address,data):
    digest,number=sequences[name].get(address,(None,0))
    if digest is None: digest=hashlib.sha256()
    digest.update(byte_values[data])
    sequences[name][address]=(digest,number+1)
with (a.mame/'video_writes.csv').open() as mf, (a.rtl/'memory_writes.bin').open('rb') as rf:
    rows=csv.DictReader(mf)
    for m in rows:
        sequence('mame',int(m['address']),int(m['data']))
        raw=rf.read(11)
        if len(raw)!=11:
            first=first or {'index':count,'kind':'RTL trace ended early'}
            differences+=1
            count+=1
            continue
        tick,address,data=struct.unpack('<QHB',raw)
        sequence('rtl',address,data)
        expected_tick=round(float(m['time'])*50400000)
        record={'index':count,'rtl_tick':tick,'mame_tick':expected_tick,
                'rtl_address':hex(address),'mame_address':hex(int(m['address'])),
                'rtl_data':data,'mame_data':int(m['data'])}
        if (address,data)!=(int(m['address']),int(m['data'])):
            differences+=1
            addresses[(hex(address),hex(int(m['address'])))]+=1
            first=first or {'index':count,'kind':'address/data/order','before':list(history),'actual':record}
        else: matched+=1
        offsets[tick-expected_tick]+=1;history.append(record);count+=1
    remainder=rf.read()
    trailing=len(remainder)//11
    for tick,address,data in struct.iter_unpack('<QHB',remainder):sequence('rtl',address,data)
sequence_differences=[]
for address in sorted(sequences['mame'].keys()|sequences['rtl'].keys()):
    values={}
    for name in sequences:
        digest,number=sequences[name].get(address,(None,0))
        values[name]={'writes':number,'sha256':digest.hexdigest() if digest else None}
    if values['mame']!=values['rtl']:sequence_differences.append({'address':hex(address),**values})
report={'scope':'RAM write address/data/order comparison; not complete Sheriff release acceptance',
        'mame_writes':count,'matched_writes':matched,'different_or_missing_writes':differences,
        'extra_rtl_writes':trailing,'first_divergence':first,
        'differences_by_address_pair':[{'rtl_address':address,'mame_address':reference,'writes':number}
            for (address,reference),number in addresses.most_common()],
        'common_bus_vs_instruction_time_offsets_ticks':offsets.most_common(12),
        'per_address_sequences':{'scope':'Diagnostic only; does not waive global write-order differences',
            'addresses':len(sequences['mame'].keys()|sequences['rtl'].keys()),
            'different_addresses':len(sequence_differences),'differences':sequence_differences},
        'pass':differences==0 and trailing==0 and count>0}
a.report.parent.mkdir(parents=True,exist_ok=True)
a.report.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({key:report[key] for key in ('scope','mame_writes','matched_writes','different_or_missing_writes','extra_rtl_writes','pass')}|
    {'first_divergence':first,'per_address_different':len(sequence_differences),
     'first_per_address_differences':sequence_differences[:8],'report':str(a.report)},indent=2))
raise SystemExit(0 if report['pass'] else 1)
