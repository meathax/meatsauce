#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Derive settled, counter-relative DRAM edges from qualified connected gates."""
from fractions import Fraction
import hashlib
import json
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def pins(counter, serial, cpu_wr_rd):
    hread = 1 ^ ((counter >> 2) & 1)
    disable = hread & (1 ^ cpu_wr_rd)
    return dict(HREAD_n=hread, COMADR_n=1 ^ ((serial >> 6) & 1),
                raw_RAS_n=((serial >> 1) & 1) & ((serial >> 3) & 1),
                raw_CAS_n=1 ^ ((serial >> 1) & 1),
                RAS_n=(((serial >> 1) & 1) & ((serial >> 3) & 1)) | disable,
                CAS_n=(1 ^ ((serial >> 1) & 1)) | disable,
                selector=((1 ^ hread) << 1) | ((serial >> 6) & 1),
                disable=disable)


def main():
    reports=[Path('docs/evidence/sheriff_memory_phases.json'),
             Path('docs/evidence/sheriff_memory_mux_connections.json'),
             Path('docs/evidence/sheriff_video_control_network.json')]
    phases=json.loads(reports[0].read_text())
    assert phases['test']['test_exit']==phases['test']['build_exit']==0
    for path,digest in phases['sha256'].items():
        assert sha(path)==digest,path
    decade=divider=counter=serial=0
    all_rows=[]
    for edge in range(256):
        old_counter,old_serial=counter,serial
        ck2_rise=not (decade & 1)
        counter_rise=ck2_rise and not divider
        decade=0 if decade==9 else decade+1
        if ck2_rise:
            serial=((serial << 1) & 255) | ((counter >> 1) & 1)
            if not divider:
                counter=(counter+1) & 15
            divider ^= 1
        if edge>=128:
            for cpu_wr_rd in [0,1]:
                before=pins(old_counter,old_serial,cpu_wr_rd)
                after=pins(counter,serial,cpu_wr_rd)
                flags={name:before[name]==1 and after[name]==0 for name in ['RAS_n','CAS_n']}
                flags.update({name+'_rise':before[name]==0 and after[name]==1 for name in ['RAS_n','CAS_n']})
                load_candidate=counter_rise and old_counter % 8 == 7
                if any(flags.values()) or counter_rise:
                    all_rows.append(dict(crystal_edge=edge,cpu_WR_RD=cpu_wr_rd,
                                         pre_counter=old_counter,post_counter=counter,
                                         pre_serial=old_serial,post_serial=serial,
                                         counter_clock_rise=bool(counter_rise),
                                         candidate_pre7_clock=bool(load_candidate),
                                         before=before,after=after,events=flags))
    # Both settled periods must match independent of the artificial start.
    for cpu in [0,1]:
        a=[{k:v for k,v in r.items() if k!='crystal_edge'} for r in all_rows if r['cpu_WR_RD']==cpu and r['crystal_edge']<192]
        b=[{k:v for k,v in r.items() if k!='crystal_edge'} for r in all_rows if r['cpu_WR_RD']==cpu and r['crystal_edge']>=192]
        assert a==b
    rows=[r for r in all_rows if r['crystal_edge']<192]
    cycles=[]
    for cpu in [0,1]:
        source=[r for r in all_rows if r['cpu_WR_RD']==cpu]
        for load in [r for r in source if r['candidate_pre7_clock'] and r['crystal_edge']<192]:
            cas=next(r for r in reversed(source) if r['crystal_edge']<load['crystal_edge'] and r['events']['CAS_n'])
            ras=next(r for r in reversed(source) if r['crystal_edge']<cas['crystal_edge'] and r['events']['RAS_n'])
            assert ras['after']['selector']==2 and cas['after']['selector']==3
            assert ras['before']['selector']==ras['after']['selector']
            assert cas['before']['selector']==cas['after']['selector']
            cycles.append(dict(cpu_WR_RD=cpu,pre_counter=load['pre_counter'],
                               RAS_fall=ras['crystal_edge'],CAS_fall=cas['crystal_edge'],
                               candidate_load=load['crystal_edge'],
                               RAS_to_CAS_crystal_edges=cas['crystal_edge']-ras['crystal_edge'],
                               CAS_to_candidate_load_crystal_edges=load['crystal_edge']-cas['crystal_edge'],
                               RAS_to_candidate_load_ns=float(Fraction((load['crystal_edge']-ras['crystal_edge'])*10**9,20160000)),
                               CAS_to_candidate_load_ns=float(Fraction((load['crystal_edge']-cas['crystal_edge'])*10**9,20160000)),
                               candidate_same_edge_CAS_rise=load['events']['CAS_n_rise'],
                candidate_same_edge_RAS_rise=load['events']['RAS_n_rise'],
                               row_selector=2,column_selector=3))
    assert len(cycles)==4
    assert all(c['RAS_to_CAS_crystal_edges']==8 and c['CAS_to_candidate_load_crystal_edges']==4 for c in cycles)
    assert all(c['candidate_same_edge_CAS_rise']==(c['cpu_WR_RD']==0) for c in cycles)
    manufacturer=dict(url='https://bitsavers.org/components/ti/_dataBooks/1982_LCC7061_TI_MOS_Memory_Data_Book.pdf',
                      title='Texas Instruments 1982 MOS Memory Data Book, TMS4116NL, October1977/revisedMay1982',
                      PDF_pages_one_based=[26,30,31],
                      limits_by_grade={'15':dict(RAS_access_max_ns=150,CAS_access_max_ns=100),
                                       '20':dict(RAS_access_max_ns=200,CAS_access_max_ns=135),
                                       '25':dict(RAS_access_max_ns=250,CAS_access_max_ns=165)},
                      RAS_to_CAS_max_for_RAS_access_guarantee_ns={'15':50,'20':65,'25':85},
                      access_note='The derived397ns RAS-to-CAS exceeds these conditional maxima; use CAS-relative access limits, not a RAS-only bound.',
                      exact_Sheriff_memory_grade_known=False,
                      local_PDF_download_status='curl returned HTTP403; online primary table inspected, no local PDF hash claimed.',
                      limit='These data-book limits do not include PCB gate/RC/latch delays and do not certify the actual fitted memory vendor/grade.')
    viewports=[dict(page=33,box=[3690,940,5088,1320],path='_checks/manuals/bandido-counter-clock-right-join.png'),
               dict(page=34,box=[0,800,1700,1380],path='_checks/manuals/bandido-serializer-clock-left-join.png'),
               dict(page=34,box=[0,0,3550,2100],path='_checks/manuals/bandido-serializer-clock-upper-left.png')]
    result=dict(scope='Settled conditional related-Bandido DRAM and connected common-counter serializer clock edges; not exact Sheriff phase qualification.',
                crystal_frequency_hz=20160000,period_crystal_edges=64,rows=rows,video_cycles=cycles,
                finding='Video RAS selects C2, then CAS selects C3, then the pre7 counter clock occurs four crystal periods later.',
                data_book=manufacturer,
                clock_connection='3B Q10 clocks 4I CLK2 and the common horizontal counter clock; adjoining page33/page34 traces continue through 4J/5I/5J CLK2 to 1L CLK11.',
                viewport_recovery=viewports,
                limitations=['Common-clock connectivity is traced on related-Bandido drawings; exact Sheriff net/revision and electrical edge delays remain unqualified.',
                             'HB/VB assumed active; polarity, visible origin and flip-counter wiring still need connected derivation.',
                             'At CPU_WR_RD=0, CAS/RAS gate off at the same ideal counter transition as the candidate load; propagation/hold ordering must be retained, not silently resolved by source order.',
                             'RD buffers DRAM DO continuously; CPU readback registers do not hold the video byte.',
                             'Exact Sheriff versus related-Bandido applicability and actual memory grade remain unqualified.',
                             'No production timing offset, graphics waiver, physical setup/hold, READY response or release pass follows.'],
                evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__),*reports,Path('rtl/n8080_memory_phases.sv'),
                                                           Path('_checks/manuals/bandido-1980.pdf'),
                                                           *[Path(v['path']) for v in viewports]]},
                production_RTL_changed=False,strict_graphics_gate_pass=False,
                physical_memory_timing_qualified=False,quartus_executed=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_dram_cycle_edges.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),video_cycles=cycles,periods_identical=True,
                          physical_memory_timing_qualified=False)))


if __name__=='__main__':
    main()
