"""Verify the one terminal111-field diagnostic; infer no physical timing pairing."""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
BASE=HERE/'coupled_boot16'
JOB=HERE/'coupled_boot111'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,obj):p.write_text(json.dumps(obj,indent=2)+'\n')
def rows(p):
    with p.open() as f:return list(csv.DictReader(f))

def verify():
    assert not (JOB/'verification.json').exists(),'Preserve completed qualification; do not rerun.'
    terminal=json.loads((JOB/'exit.json').read_text())
    lineage=json.loads((JOB/'lineage.json').read_text())
    baseproof=json.loads((BASE/'verification.json').read_text())
    pins=json.loads((BASE/'source_pins.json').read_text())
    capture=JOB/'capture';old=BASE/'capture'
    frame_rows=rows(capture/'frames.csv');old_frames=rows(old/'frames.csv')
    input_rows=rows(capture/'applied_inputs.csv');old_inputs=rows(old/'applied_inputs.csv')
    events=rows(capture/'coupled_mcu.csv');old_events=rows(old/'coupled_mcu.csv')
    prefix_arrays=[]
    for p in sorted(old.glob('frame_*')):
        if not p.is_file():continue
        new=capture/p.name
        prefix_arrays.append({'name':p.name,'original_sha256':H(p),
                              'current_sha256':H(new) if new.exists() else None,
                              'pass':new.exists() and H(new)==H(p)})
    checks={'actual111_exit0':terminal['exit_code']==0,
            'same_ELF_no_rebuild':H(Path(lineage['ELF_path']))==lineage['ELF_sha256']==baseproof['run_exit']['ELF_sha256'],
            'all75_private_source_pins_unchanged':all(H(Path(p['path']))==p['actual_private_sha256'] for p in pins['source_files']),
            'same_ROM_and_actual_inputs':H(Path(lineage['ROM_path']))==lineage['ROM_sha256'] and H(Path(lineage['legal_input_path']))==lineage['legal_input_sha256'],
            'original16_receipt_immutable':H(BASE/'verification.json')==lineage['original16_verification_sha256'],
            'preferred_preparation_contract_immutable':H(HERE/'integration_contract.json')==lineage['contract_sha256'],
            '111_actual_contiguous_fields':len(frame_rows)==111 and [int(r['frame']) for r in frame_rows]==list(range(111)),
            'legal_ports_0_1_3':bool(input_rows) and all((int(r['controls']),int(r['dips']),int(r['coins_n']))==(0,1,3) for r in input_rows),
            'original16_frames_exact':frame_rows[:len(old_frames)]==old_frames,
            'original16_applied_inputs_exact':input_rows[:len(old_inputs)]==old_inputs,
            'original16_MCU_tick_events_exact':events[:len(old_events)]==old_events,
            'all48_overlapping_RGB_work_strip_arrays_exact':len(prefix_arrays)==48 and all(r['pass'] for r in prefix_arrays),
            'full_pixels_no_duplicate_deadline_or_row_failures':all(int(r['pixels'])==57344 and int(r['duplicates'])==0 and int(r['deadline_misses'])==0 and int(r['row_overflows'])==0 for r in frame_rows)}
    before=[r for r in events if r['edge']=='before']
    commands=[r for r in before if r['command']=='1']
    shared=[r for r in before if r['shared_write']=='1']
    irqpulses=[r for r in before if r['irq2_pulse']=='1']
    controls=[r for r in before if r['control_event']=='1']
    buses=[r for r in before if r['bus_event']=='1']
    transitions=[];previous=None;intervals=[];active=None
    for row in events:
        level=int(row['halt'])
        if level!=previous:
            entry={k:row[k] for k in ['tick','edge','halt','ASn','cpu_phase','control','program_addr']}
            transitions.append(entry)
            if level==1:active={'assertion':entry,'samples':[]}
            elif active is not None:
                active['release']=entry;intervals.append(active);active=None
        if active is not None:active['samples'].append(row)
        previous=level
    if active is not None:intervals.append(active)
    halt_windows=[]
    for window in intervals:
        start=int(window['assertion']['tick']);end=int(window.get('release',window['assertion'])['tick'])
        command=next((r for r in commands if int(r['tick'])+1==start),None)
        high=[r for r in window['samples'] if r['ASn']=='1']
        phases=sorted(set(int(r['cpu_phase']) for r in high))
        halt_windows.append({'assertion':window['assertion'],'release':window.get('release'),
             'accepted_command_before':command,'accepted_command_edge_inferred_from_host_clock':None if command is None else int(command['tick'])+1,
             'command_HALT_causal_edge_match':command is not None and bool(int(command['control'])&16),
             'AS_low_at_assertion':window['assertion']['ASn']=='0','AS_high_observed_while_HALTed':bool(high),
             'observed_AS_high_cpu_phases':phases,'observed_AS_high_phase_constant':len(phases)==1 if high else None,
             'first_AS_high_observation':high[0] if high else None,
             'exact_AS_high_transition_tick_known':False,
             'nearby_shared_consumption_rows':[r for r in shared if start-1<=int(r['tick'])<=end+1],
             'resumed_later_accepted_command':any(int(r['tick'])>end for r in commands) if 'release' in window else False})
    epoch=rows(capture/'epoch_events.csv')
    iacks=[r for r in epoch if r['iack']=='1']
    iack2=[r for r in iacks if ((int(r['address'])>>1)&7)==2]
    checks['uncapped_IACK2_rows_match_actual_counter']=len(iack2)==int(frame_rows[-1]['irq2_acks'])
    # Actual endpoint checks only. General CPU write capture is capped, so this
    # does not reconstruct every memory write or pretend to prove atomicity.
    before_ram=(capture/'frame_000090.work.bin').read_bytes()
    after_ram=(capture/'frame_000110.work.bin').read_bytes()
    last={int(r['shared_addr']):r for r in shared}
    coherence=[]
    for address,row in sorted(last.items()):
        data=int(row['shared_data']);offset=address*2
        coherence.append({'word_address':address,'latest_observed_MCU_data':data,
           'latest_shared_pulse_before_tick':int(row['tick']),
           'board_consumption_edge_inferred_from_unchanged_clock':int(row['tick'])+1,
           'snapshot90_high':before_ram[offset],'snapshot110_high':after_ram[offset],
           'snapshot110_low':after_ram[offset+1],
           'final_low_matches_latest_observed_MCU_write':after_ram[offset+1]==data,
           'high_equal_between_retained_snapshots':before_ram[offset]==after_ram[offset]})
    primary=baseproof['reference_first20_commands']
    def mame_key(r):return (((int(r['address'])-0x80000)//2),r['area']=='mcu_command_read',None if r['area']=='mcu_command_read' else int(r['data'])&255)
    def native_key(r):return (int(r['command_addr']),r['rw']=='1',None if r['rw']=='1' else int(r['dout'])&255)
    count=min(len(commands),len(primary))
    command_order={'comparison':'Ordered command address/read/write-data tuples only; each producer keeps its own unshifted epoch.',
       'compared_rows':count,'native_rows_total':len(commands),'primary_rows_retained':len(primary),
       'prefix_equal':count>0 and [native_key(r) for r in commands[:count]]==[mame_key(r) for r in primary[:count]],
       'native_first20':commands[:20],'primary_first20':primary,
       'physical_or_frame_pairing_pass':False}
    native_first_field=next((int(r['frame']) for r in frame_rows if int(r['mcu_transactions'])>0),None)
    source_board=Path(next(x['path'] for x in pins['source_files'] if x['path'].endswith('alpha68kn_board.sv')))
    board=source_board.read_text()
    structural={'MCU_priority_excludes_CPU_work_service':'(!sting_mcu_work_service || iack || maddr<24\'h020000 || maddr>=24\'h021000)' in board,
       'MCU_priority_excludes_HS_service':'hs_access && !sting_mcu_work_service' in board,
       'MCU_drives_low_byte_only':'wire work_write_lo=sting_mcu_work_service' in board,
       'MCU_does_not_directly_enable_high_byte':'sting_mcu_work_service' not in board.split('wire work_write_hi=',1)[1].split(';',1)[0],
       'profile2_Kyros_HLE_disabled':'wire hle_service=!is_stingray' in board,
       'pinned_source_sha256':H(source_board),'proof_kind':'Pinned port-selection source predicates; not observed per-edge RAM readback.'}
    complete=bool(commands) and bool(shared) and any(w['release'] and w['command_HALT_causal_edge_match'] for w in halt_windows)
    source_protocol=all(checks.values())
    evidence=[]
    for p in sorted(capture.iterdir()):
        if p.is_file():evidence.append({'path':str(p),'sha256':H(p),'bytes':p.stat().st_size})
    receipt={'schema':'actual_sstingry_initial_exchange111_v1','checks':checks,'source_protocol_pass':source_protocol,
       'terminal':terminal,'lineage_sha256':H(JOB/'lineage.json'),'verifier_sha256':H(Path(__file__)),
       'first_native_MCU_field':native_first_field,'native_command_count':len(commands),'native_shared_write_count':len(shared),
       'native_IRQ2_pulse_count':len(irqpulses),'native_IRQ2_IACK_count':len(iack2),
       'native_control_event_count':len(controls),'native_BUS_event_count':len(buses),
       'HALT_windows':halt_windows,'initial_exchange_liveness_complete':complete,
       'shared_byte_endpoint_checks':coherence,'shared_byte_lane_source_contract':structural,
       'IRQ2_pulse_first20':irqpulses[:20],'IRQ2_IACK_first20':iack2[:20],
       'software_command_order':command_order,'original16_array_fidelity':prefix_arrays,
       'frames_first':frame_rows[0],'frames_last':frame_rows[-1],'actual_capture_evidence':evidence,
       'paired_MAME_MCU_order_pass':False,'physical_HALT_cutoff_pass':False,'all_shared_writes_atomicity_pass':False,
       'graphics_pass':False,'full_attract_pass':False,'gameplay_pass':False,'production_edited':False,
       'limits':['The original observer retains events, not every AS/phase transition; AS-high drain and phase hold are qualified only at actual observed samples.',
         'General bus.csv caps4096 initial plus2048 selected samples; instruction_events only fields59/60. No complete CPU shared-write history is available.',
         'RAM90/110 endpoint matches do not prove every write, temporal atomicity or absence of intervening CPU writes. High-byte source gating and endpoint observations are separate evidence.',
         'Primary MAME records command tuples but lacks direct MCU P2/BUS/shared-write/HALT timestamps and a separate raw exit receipt. No frame shift or physical paired ordering is inferred.',
         'This bounds initial boot/exchange only. Full attract/gameplay, display/audio equivalence and FPGA resource/timing remain pending.']}
    save(JOB/'verification.json',receipt)
    (JOB/'verification.md').write_text('# Private actual Super Stingray initial exchange111\n\n'+
        f"The same pinned ELF completed111 fields with exit{terminal['exit_code']}; source/protocol checks {'pass' if source_protocol else 'fail'}. Initial exchange liveness is {complete}. Actual commands={len(commands)}, shared writes={len(shared)}, IRQ2 pulses={len(irqpulses)}, IRQ2 IACKs={len(iack2)}.\n\n"+
        'The original16-field frames, applied inputs, MCU tick stream and48 RGB/work/strip arrays are checked without shifting or masks. The preferred preparation and canonical production are unchanged.\n\n'+
        'HALT observations and final shared-byte snapshots are finite evidence; exact AS transition timing, per-write atomicity and physical paired MCU ordering remain unqualified. See verification.json for source predicates, actual pulse/ack rows and all limits. Full attract/gameplay, graphics/audio equivalence and FPGA gates remain pending.\n')
    owned=[HERE/'run_coupled111.py',Path(__file__),JOB/'lineage.json',JOB/'worker.json',JOB/'job.json',JOB/'exit.json',
           JOB/'verification.json',JOB/'verification.md']
    save(JOB/'import_manifest.json',{'schema':'actual_sstingry_initial_exchange111_import_v1',
       'entries':[{'path':str(p),'sha256':H(p),'bytes':p.stat().st_size} for p in owned],
       'large_actual_evidence_references':[{'path':str(JOB/'run.log'),'sha256':H(JOB/'run.log'),'bytes':(JOB/'run.log').stat().st_size}]+evidence,
       'base16_source_and_ELF_recovery':str(BASE),'preferred_candidate_immutable':str(HERE/'import_manifest.json'),
       'new_build':False,'canonical_edit':False,'rerun_authorized_by_manifest':False})
    print(json.dumps({'checks':checks,'commands':len(commands),'shared_writes':len(shared),'IRQ2_pulses':len(irqpulses),
       'IRQ2_IACKs':len(iack2),'first_native_MCU_field':native_first_field,'initial_exchange_complete':complete,
       'HALT_windows':[{k:v for k,v in w.items() if k not in ['nearby_shared_consumption_rows','first_AS_high_observation']} for w in halt_windows[:6]],
       'shared_endpoint_checks':coherence,'software_prefix_equal':command_order['prefix_equal'],
       'verification_sha256':H(JOB/'verification.json'),'manifest_sha256':H(JOB/'import_manifest.json'),
       'manifest_entries':len(owned)}))
    return 0 if source_protocol else 1

def main():
    action=sys.argv[1] if len(sys.argv)>1 else 'verify'
    if action=='launch-waiter':
        assert not (JOB/'verifier_waiter.json').exists(),'Follow existing verification waiter.'
        with (JOB/'verification.log').open('w',encoding='utf8') as log:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),'await-terminal'],cwd=HERE,
                       stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'verifier_waiter.json',{'pid':child.pid,'started':time.time(),'verifier_sha256':H(Path(__file__)),
                                     'poll_seconds':45,'launches_simulation':False})
        print(json.dumps({'verifier_waiter_pid':child.pid,'poll_seconds':45}));return
    if action=='await-terminal':
        while not (JOB/'exit.json').exists():time.sleep(45)
    assert action in ['verify','await-terminal']
    try:code=verify();error=None
    except Exception as failure:
        code=1;error=repr(failure)
        import traceback;traceback.print_exc()
    save(JOB/'verification_exit.json',{'exit_code':code,'error':error,'finished':time.time(),
                                    'verifier_sha256':H(Path(__file__)),'build_or_replay_launched':False})
    raise SystemExit(code)

if __name__=='__main__':main()
