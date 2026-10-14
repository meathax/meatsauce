# SPDX-License-Identifier: GPL-2.0-or-later
"""Use exact reference callbacks and retained native bus phases at field66."""
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    root = Path('_checks/first-irq66-boundary-20261010')
    terminal = root/'terminal.json'
    receipt = json.loads(terminal.read_text())
    assert receipt['child_exit_codes']==dict(native=0,mame=0) and receipt['native_OS_exit']==0
    prefixes = root/'prefix-comparison.json'
    assert json.loads(prefixes.read_text())['all_equal']
    binding = root/'source-binding.json'
    assert all(sha(Path(p))==h for p,h in json.loads(binding.read_text())['source_sha256'].items())
    reset_path = Path('docs/evidence/sheriff_reset_startup.json')
    reset = json.loads(reset_path.read_text())
    origin = reset['source_reset_model']
    tag_phase = origin['sampled_T1_tag_counter_phase']
    phi2_offset = origin['last_phi2_gate_sample_offset_from_final_cycle_T1_tag']
    assert origin['matched_pre_opcode_pin_samples']==78
    assert origin['phase_at_pin_reset_release']==tag_phase==7
    assert phi2_offset==19-tag_phase==12
    # Reuse the exact CPU; bridge only the observer's two added input initializers.
    for relative in ('rtl/n8080_cpu.sv','rtl/n8080_vm80a_ce.v'):
        p = Path(relative).resolve()
        assert sha(p)==reset['sources'].get(relative,reset['sources'].get(p.as_posix()))
    harness_path = Path('sim/board_harness.cpp')
    harness = harness_path.read_bytes()
    audit_initializer = b'b.reset=1;b.pause=0;b.debug_req=0;b.debug_freeze=0;b.debug_wr=0;b.debug_dout=0;'
    current_initializer = b'b.reset=1;b.pause=0;b.flip_screen=0;b.debug_req=0;b.debug_freeze=0;b.debug_wr=0;b.debug_addr=0;b.debug_dout=0;'
    assert harness.count(current_initializer)==1
    specialized_harness = harness.replace(current_initializer,audit_initializer)
    assert hashlib.sha256(specialized_harness).hexdigest()==reset['sources'][harness_path.as_posix()]
    previous = Path('docs/evidence/sheriff_first_irq_return_difference.json')
    earlier = json.loads(previous.read_text())
    assert earlier['equal_prefix_count']==82 and earlier['first_difference']['native']['frame']==66
    edge = 66*819200
    bus_path = root/'native/bus.csv'
    with bus_path.open(newline='') as f:
        bus = list(csv.DictReader(f))
    opcode_reads = [r for r in bus if r['kind']=='read' and int(r['status'])&32
                    and not int(r['status'])&1 and int(r['address'])<0x4000]
    exact_path = root/'mame/observations_exact.csv'
    with exact_path.open(newline='') as f:
        exact = list(csv.DictReader(f))
    def master(r):
        return (Decimal(r['time_seconds'])+Decimal(r['time_attoseconds'])/10**18)*50_400_000
    reference = [r for r in exact if r['kind']=='program_read']
    assert reference
    rom_path = Path('roms/sheriff.bin')
    rom = rom_path.read_bytes()
    assert rom[0xfef:0xff6] == bytes.fromhex('3ac060a7c2ef0f')
    native_loop, reference_loop = [], []
    for pc, name in [(0xfef,'LDA 60c0'),(0xff2,'ANA A'),(0xff3,'JNZ 0fef')]:
        nr = [r for r in opcode_reads if int(r['address'])==pc and edge-1000<int(r['tick'])-27<edge+400]
        mr = [r for r in reference if int(r['address'])==pc and edge-1000<master(r)<edge+400]
        native_loop += [dict(PC=pc,instruction=name,fetch_tick=int(r['tick']),T1_tick=int(r['tick'])-27,
                             T1_delta_request=int(r['tick'])-27-edge) for r in nr]
        reference_loop += [dict(PC=pc,instruction=name,sequence=int(r['sequence']),
                                T1_tick=str(master(r)),T1_delta_request=str(master(r)-edge)) for r in mr]
    native_ana = next(r for r in native_loop if r['PC']==0xff2 and r['T1_delta_request']==-75)
    ref_ana = next(r for r in reference_loop if r['PC']==0xff2 and abs(Decimal(r['T1_delta_request'])+125)<Decimal('.001'))
    ref_branch = next(r for r in reference_loop if r['PC']==0xff3 and abs(Decimal(r['T1_delta_request'])+25)<Decimal('.001'))
    assert not any(r['PC']==0xff3 and r['T1_delta_request']>=-75 for r in native_loop)
    ack = next(r for r in bus if r['kind']=='ack' and edge<=int(r['tick'])<edge+300)
    assert int(ack['tick'])==edge+27 and int(ack['address'])==0xff3
    native_stack = [r for r in bus if r['kind']=='write' and edge<int(r['tick'])<edge+400
                    and int(r['address']) in (0x7ffd,0x7ffc)]
    assert [(int(r['tick'])-edge,int(r['data'])) for r in native_stack]==[(194,15),(269,243)]
    reference_stack = [r for r in exact if r['kind']=='ram_write' and edge<master(r)<edge+600
                       and int(r['address']) in (0x7ffd,0x7ffc)]
    assert [int(r['data']) for r in reference_stack]==[15,239]
    assert all(abs(master(r)-edge-500)<Decimal('.001') for r in reference_stack)
    phase_cases=[]
    for c in earlier['compared_cases']:
        n=c['native']; m=c['reference_candidates'][0]
        delta=Decimal(m['tick'])-275-(n['tick']-2)
        phase_cases.append(dict(frame=n['frame'],y=n['y'],return_PC_equal=c['return_PC_equal'],
                                reference_minus_native_RST_T1=str(delta)))
    assert all(abs(Decimal(c['reference_minus_native_RST_T1'])+50)<Decimal('.001') for c in phase_cases[:-1])
    assert abs(Decimal(phase_cases[-1]['reference_minus_native_RST_T1'])-200)<Decimal('.001')
    source_files=[Path(__file__),previous,terminal,prefixes,binding,bus_path,exact_path,rom_path,reset_path,
                  Path('rtl/n8080_cpu.sv'),Path('rtl/n8080_vm80a_ce.v'),harness_path,
                  root/'native-exit-code.txt',root/'mame/irq_program_reads.csv']
    report=dict(scope='First83 observed IRQ return-PC boundaries and actual native/exact-reference wait-loop timing at field66; main-board diagnostic, not physical reset/raster or current audio qualification.',
                receipts=receipt,equal_IRQ_return_PC_prefix=82,first_difference_field=66,
                request_edge=edge,native_loop=native_loop,reference_loop=reference_loop,
                clock_projection=dict(origin_evidence=reset_path.as_posix(),
                                      sha256=sha(reset_path),tag_counter_phase=tag_phase,
                                      last_phi2_tag_offset=phi2_offset,
                                      harness_bridge=dict(current_sha256=sha(harness_path),
                                                          reset_audit_sha256=reset['sources'][harness_path.as_posix()],
                                                          specialization='Remove only flip_screen=0 and debug_addr=0 from initial inputs; entire remaining harness is byte-identical to reset audit.'),
                                      native_T1_observable='Bus-derived tag: DBIN minus27 or SYNC minus2; not physical phi1 rise.',
                                      reference_T1_observable='Atomic opcode callback time; not physical bus pins.'),
                native_ANA_end_T1=native_ana['T1_tick']+4*25,
                native_final_ANA_phi2=native_ana['T1_tick']+3*25+phi2_offset,
                native_RST_T1=int(ack['tick'])-2,native_return_PC=0xff3,
                reference_ANA_end_T1=str(Decimal(ref_ana['T1_tick'])+4*25),
                reference_JNZ_end_T1=str(Decimal(ref_branch['T1_tick'])+10*25),
                reference_return_PC=0xfef,native_stack=native_stack,reference_stack=reference_stack,
                prior_IRQ_RST_epoch_cases=phase_cases,
                explanation='The reference ANA callback is50 master clocks earlier than the native bus-derived T1 tag. Reference JNZ begins25 clocks before the request and completes225 after; native final ANA phi2 is12 clocks after the request, followed by the RST tag25 after. The differing saved PC follows this observed timing-origin split, not an ANA flag error. The existing reset audit explains the startup tag gap without establishing a donor reset fault.',
                next_required='Reuse the completed reset audit. Qualify actual CPU/raster/IRQ and memory-service timing before any phase change; the source reset model does not establish physical Sheriff power-up origin. Do not fit field2760 or repeat its unchanged long run.',
                evidence_sha256={p.as_posix():sha(p) for p in source_files},
                graphics_gate_pass=False,physical_reset_origin_qualified=False,
                limits=['Prior83 reference RST start times are inferred from the documented11-T-state RST and atomic stack write; the field66 opcode and stack observations independently confirm the local prediction.',
                        'Retained native model has old SN conversion constants; no current complete-wrapper/audio claim.',
                        'No reference/image shift, arbitrary offset, state forcing, production RTL, Quartus or RBF change.'])
    target=Path('docs/evidence/sheriff_first_irq_boundary.json')
    target.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(report=target.as_posix(),actual_exits=receipt['child_exit_codes'],
                          first_difference=66,equal_prefix=82,native_return_PC='0ff3',
                          reference_return_PC='0fef',prior_epoch_master_clocks=-50,
                          native_ANA_end_request_delta=25,native_final_ANA_phi2_request_delta=phi2_offset,
                          reference_JNZ_end_request_delta=str(Decimal(ref_branch['T1_tick'])+250-edge))))


if __name__=='__main__':
    main()
