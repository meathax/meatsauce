"""Explain the two measured Sheriff IRQ corners without changing RTL or traces.

This narrow 70-frame fixture retains the raw memory comparison as a failure.
It checks MAME clock quantization, independent ISA timing and the actual bus
edges; it is not a blanket stack-byte exemption or a complete IRQ gate.
"""
import argparse
import csv
import hashlib
import json
import struct
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec=40
p=argparse.ArgumentParser()
p.add_argument('--mame',type=Path,required=True)
p.add_argument('--rtl',type=Path,required=True)
p.add_argument('--report',type=Path,required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
rom=(root/'roms/sheriff.bin').read_bytes()
mame=list(csv.DictReader((a.mame/'video_writes.csv').open()))
raw=(a.rtl/'memory_writes.bin').read_bytes()
assert len(raw)%11==0
rtl=list(struct.iter_unpack('<QHB',raw))
assert len(mame)==len(rtl)==23916, 'Fixture must be the matching complete 70-frame RAM trace'
startup=list(csv.DictReader((a.rtl/'cpu_startup.csv').open()))
sync=min(int(r['tick']) for r in startup if int(r['sync']))
dbin=min(int(r['tick']) for r in startup if int(r['dbin']))
assert dbin-sync==25
epoch=sync-13  # sustained phi2 starts at phase 12; registered SYNC follows
assert epoch==18, 'This fixture must use the observed startup clock epoch'
cpu_as=10**18//2016000
pixel_as=10**18//5040000
different=[i for i,(m,(_,address,data)) in enumerate(zip(mame,rtl))
           if (int(m['address']),int(m['data']))!=(address,data)]
assert len(different)==2, 'Do not silently exempt other memory differences'
corners=[]
for i in different:
    m=mame[i];tick,address,data=rtl[i]
    assert address==int(m['address'])==0x7ffc
    assert rtl[i-1][1]==int(mame[i-1]['address'])==0x7ffd
    time_as=Decimal(m['time'])*10**18
    m_tick=round(Decimal(m['time'])*50400000)
    frame=m_tick//819200
    edges=[frame*819200,frame*819200+460800,(frame+1)*819200]
    edge=min(edges,key=lambda t:abs(t-m_tick))
    assert m_tick-edge==250
    cycles=edge//25
    irq_as=(edge//10)*pixel_as
    boundary_as=(cycles-1)*cpu_as
    delta_as=irq_as-boundary_as
    assert 0<delta_as<cpu_as  # schedule.cpp skips this sub-cycle residual
    assert abs(time_as-(cycles+10)*cpu_as)<=Decimal(500500)
    assert Decimal(mame[i-1]['time'])==Decimal(m['time'])
    m_pc=(int(mame[i-1]['data'])<<8)|int(m['data'])
    # Decode only locally; never export game ROM bytes in this report.
    assert rom[m_pc-1]==0xa7 and rom[m_pc]==0xc2  # ANA A; JNZ target
    target=int.from_bytes(rom[m_pc+1:m_pc+3],'little')
    assert int(mame[i+2]['address'])==0x7ffa
    assert not (int(mame[i+2]['data'])&0x40), 'JNZ must be taken'
    # ANA is four T states. IRQ occurs after its final phi2 aperture;
    # a taken 8080 JNZ is ten T states. RST is five+three+three T states.
    ana_phi1=epoch+(cycles-5)*25
    last_phi2=ana_phi1+3*25+24
    rst_phi1=ana_phi1+4*25+10*25
    pch_tick=rst_phi1+7*25+1
    pcl_tick=rst_phi1+10*25+1
    assert last_phi2<edge
    assert (rtl[i-1][0],tick)==(pch_tick,pcl_tick)
    assert (rtl[i-1][2]<<8)|data==target
    corners.append({
        'index':i,'raster_edge_tick':edge,'raster_v':240 if edge%819200==0 else 128,
        'mame_push_tick':m_tick,'mame_implied_rst_start_tick':edge-25,
        'cpu_cycle_as':cpu_as,'pixel_cycle_as':pixel_as,
        'scheduler_delta_as':delta_as,'sub_cycle_deficit_as':cpu_as-delta_as,
        'push_timestamp_prediction_error_as':str(time_as-(cycles+10)*cpu_as),
        'mame_return_pc':hex(m_pc),'expected_hardware_return_pc':hex(target),
        'ana_last_phi2_tick':last_phi2,'predicted_rst_phi1_tick':rst_phi1,
        'predicted_stack_write_ticks':[pch_tick,pcl_tick],
        'actual_stack_write_ticks':[rtl[i-1][0],tick],'explanation_pass':True})
report={
    'scope':'Exact two-corner MAME scheduling/physical-bus explanation for this 70-frame fixture',
    'mame':str(a.mame),'rtl':str(a.rtl),'startup_phi1_epoch':epoch,
    'ram_events':len(rtl),'raw_memory_trace_pass':False,
    'boundary_explanation_pass':True,'complete_irq_gate':False,
    'reference_uses_fpga_data_for_expected_pc':False,
    'clock_epoch_observed_from_startup_bus':True,'corners':corners,
    'source_evidence':{
        'schedule':'MAME 0.289 src/emu/schedule.cpp: cpu_timeslice requires delta >= attoseconds_per_cycle before execution; timers run after m_basetime advances',
        'cpu':'MAME 0.289 src/devices/cpu/i8085/i8085.cpp: execute_run checks pending interrupts before its instruction loop; execute_one charges RST 11 cycles before stack writes',
        'driver':'MAME 0.289 src/mame/nintendo/n8080.cpp: rst1/rst2 scanline timers 128/240, CPU 2.016 MHz, pixels 5.04 MHz',
        'manual':'Intel Intellec 8 Mod 80 Reference Manual, Feb 1975, Interrupt Sequences/Figure 2-8: enabled INT is reclocked with phi2 in the final instruction state',
        'manual_url':'https://bitsavers.org/components/intel/MCS80/Intellec_8_Mod_80/Intel_Intellec_8_Mod_80_Reference_Manual_Feb75.pdf'},
    'input_sha256':{str(path):hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (a.mame/'video_writes.csv',a.rtl/'memory_writes.bin',a.rtl/'cpu_startup.csv')},
    'limits':['Only these two ANA/JNZ corners and this startup epoch are qualified',
              'The original MAME and RTL traces remain unchanged and their strict mismatch remains visible',
              'This does not qualify full-game IRQs, analog hardware delays or another clock phase']}
a.report.parent.mkdir(parents=True,exist_ok=True)
a.report.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'report':str(a.report),'corners':corners,'boundary_explanation_pass':True},indent=2))
