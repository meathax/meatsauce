"""Qualify one completed coupled diagnostic; never build or replay evidence."""
from pathlib import Path
import csv
import hashlib
import json
import subprocess

HERE=Path(__file__).resolve().parent
JOB=HERE/'coupled_boot16'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    output=JOB/'verification.json';assert not output.exists(),'Preserve completed verification.'
    source=json.loads((JOB/'source_pins.json').read_text())
    provenance=json.loads((JOB/'reference_provenance.json').read_text())
    exits={stage:json.loads((JOB/(stage+'_exit.json')).read_text()) for stage in ['build','run']}
    checks={'actual_build0':exits['build']['exit_code']==0,'actual_run0':exits['run']['exit_code']==0,
            'same_ELF_build_and_run':exits['build']['ELF_sha256']==exits['run']['ELF_sha256'],
            'Linux_ELF_runtime_explicit':exits['run']['ELF_header']=='7f454c46',
            'all75_private_inputs_unchanged':all(H(Path(p['path']))==p['actual_private_sha256'] for p in source['source_files']),
            'real_port_trace_unchanged':H(JOB/'actual_attract_inputs.csv')==source['input_sha256'],
            'frozen_preparation_contract':H(HERE/'integration_contract.json')==source['contract_sha256']}
    source_root=JOB/'source'
    tmp=(source_root/'sim/build/wsl_system_build_dir.txt').read_text().strip()
    command=['wsl.exe','-d','Ubuntu','--exec','/bin/bash','-c',
             'cd "$1" && sha256sum -- ./*.sv ./*.v ./*.cpp ./*.h ./*.vlt','sha_scope',tmp]
    actual=subprocess.run(command,capture_output=True,text=True)
    actual_hashes={}
    if actual.returncode==0:
        for line in actual.stdout.splitlines():
            sha,name=line.split(None,1);actual_hashes[Path(name.strip()).name]=sha
    expected={Path(x['path']).name:x['actual_private_sha256'] for x in source['source_files'] if Path(x['path']).suffix!='.mem'}
    compiled_checks={name:expected.get(name)==sha for name,sha in actual_hashes.items()}
    checks['actual_compiled_copy_hashes_match']=actual.returncode==0 and len(compiled_checks)>60 and all(compiled_checks.values())
    capture=JOB/'capture';frames=list(csv.DictReader((capture/'frames.csv').open()))
    inputs=list(csv.DictReader((capture/'applied_inputs.csv').open()))
    checks['actual16_contiguous_fields']=len(frames)==16 and [int(r['frame']) for r in frames]==list(range(16))
    checks['actual_input_ports_0_1_3']=all((int(r['controls']),int(r['dips']),int(r['coins_n']))==(0,1,3) for r in inputs)
    checks['full_pixels_no_duplicates_or_deadline_misses']=all(int(r['pixels'])==57344 and int(r['duplicates'])==0 and int(r['deadline_misses'])==0 for r in frames)
    audio_rows=list(csv.DictReader((capture/'audio_events.csv').open()))
    checks['real_main_transactions']=int(frames[-1]['main_transactions'])>0
    z80_observation={'observed_sound_bus_addresses':sorted(set(int(r['sound_address']) for r in frames)),
                     'actual_audio_event_rows':len(audio_rows),'first_audio_events':audio_rows[:12],
                     'real_T80_compiled_source_pin':actual_hashes.get('T80s.v'),
                     'limit':'No aggregate sound transaction counter is exported in frames.csv; bus addresses/audio events are actual observations only.'}
    rows=list(csv.DictReader((capture/'coupled_mcu.csv').open()))
    before=[r for r in rows if r['edge']=='before']
    commands=[r for r in before if r['command']=='1']
    shared=[r for r in before if r['shared_write']=='1']
    irq=[r for r in before if r['irq2_pulse']=='1']
    controls=[r for r in before if r['control_event']=='1']
    buses=[r for r in before if r['bus_event']=='1']
    halts=[];previous=None
    for row in rows:
        state=int(row['halt'])
        if state!=previous:halts.append({'tick':int(row['tick']),'edge':row['edge'],'halt':state,'ASn':int(row['ASn']),'cpu_phase':int(row['cpu_phase'])})
        previous=state
    checks['actual_real8748_clock_activity']=bool(rows) and max(int(r['oscillator_ticks']) for r in rows)>0 and max(int(r['core_ticks']) for r in rows)>0
    checks['actual_firmware_control_activity']=bool(controls)
    reference=Path(provenance['manifest_path']).parent
    reference_commands=[];areas={};first_command=None
    with (reference/'events.csv').open() as f:
        for row in csv.DictReader(f):
            if row['area'] not in ['mcu_command_read','mcu_command_write']:continue
            areas[row['area']]=areas.get(row['area'],0)+1
            if first_command is None:first_command=row
            if len(reference_commands)<20:reference_commands.append(row)
    reference_vectors=[]
    with (reference/'events.csv').open() as f:
        for row in csv.DictReader(f):
            if int(row['frame'])>=16:break
            if row['area']=='main_vector_read' and len(reference_vectors)<20:reference_vectors.append(row)
    image_evidence=[]
    for p in sorted(capture.glob('frame_*')):
        if p.is_file():image_evidence.append({'path':str(p),'bytes':p.stat().st_size,'sha256':H(p)})
    import io
    instruction=capture/'instruction_events.csv'
    with instruction.open('rb') as f:
        header=f.readline().decode().strip()
        f.seek(max(0,instruction.stat().st_size-32768))
        tail=f.read().decode(errors='replace').splitlines()[1:]
    native_tail=list(csv.DictReader(io.StringIO(header+'\n'+'\n'.join(tail))))[-32:]
    rom_path=next(Path(x['path']) for x in provenance['ROM_regions'] if x['path'].endswith('maincpu.bin'))
    rom=rom_path.read_bytes();pcs=sorted(set(int(x['pc_after']) for x in native_tail))
    pc_evidence={'actual_last32_accepted_bus_rows':native_tail,'request_PC_is_dispatch':False,
                 'ROM_path':str(rom_path),'ROM_sha256':H(rom_path),
                 'reset_SP':int.from_bytes(rom[:4],'big'),'reset_PC':int.from_bytes(rom[4:8],'big'),
                 'observed_PC_windows':[{'pc':pc,'offset':max(0,pc-12),
                       'bytes_hex':rom[max(0,pc-12):min(len(rom),pc+16)].hex()} for pc in pcs if pc<len(rom)],
                 'reference_initial_snapshot':next(csv.DictReader((reference/'states.csv').open())),
                 'limit':'Accepted bus rows expose current PC/IR registers; they do not by themselves identify dispatch or prove a loop cause.'}
    log=(JOB/'run.log').read_text(errors='replace')
    linux_pid=next((x.split('=',1)[1] for x in log.splitlines() if x.startswith('linux_pid=')),None)
    minimal_complete=bool(commands) and any(x['halt']==1 for x in halts) and any(x['halt']==0 for x in halts[1:]) and bool(shared) and bool(irq)
    receipt={'schema':'actual_sstingry_coupled_boot16_v1','checks':checks,'protocol_source_checks_pass':all(checks.values()),
             'build_exit':exits['build'],'run_exit':exits['run'],'linux_run_pid':linux_pid,
             'source_pins_sha256':H(JOB/'source_pins.json'),'verifier_sha256':H(Path(__file__)),
             'compiled_copy_hash_command':command,'compiled_copy_hash_exit':actual.returncode,
             'compiled_copy_hashes':actual_hashes,'compiled_copy_checks':compiled_checks,'compiled_copy_stderr':actual.stderr,
             'frames_first':frames[0],'frames_last':frames[-1],'applied_input_rows':len(inputs),
             'actual_Z80_observation':z80_observation,'actual_native_PC_bus_evidence':pc_evidence,
             'MCU_observer_rows':len(rows),'MCU_command_consumption_rows':len(commands),'MCU_shared_consumption_rows':len(shared),
             'MCU_irq2_pulses':len(irq),'MCU_bus_events':len(buses),'MCU_control_events':len(controls),
             'initial_control_rows':controls[:12],'initial_bus_rows':buses[:8],'HALT_transitions':halts,
             'reference_provenance_sha256':H(JOB/'reference_provenance.json'),'reference_command_area_counts':areas,
             'reference_first_command':first_command,'reference_first20_commands':reference_commands,
             'reference_first16_vector_rows':reference_vectors,'actual_capture_arrays':image_evidence,
             'actual_coupled_initial_command_complete':minimal_complete,'paired_MAME_MCU_order_pass':False,
             'physical_HALT_cutoff_pass':False,'full_attract_pass':False,'gameplay_pass':False,'graphics_pass':False,
             'no_production_edit':True,'no_Quartus_or_RBF':True,
             'limits':['Sixteen authentic fields ended before a main-CPU MCU command; do not claim the initial coupled exchange is complete.',
                       'Observer samples actual read-only retained RTL wires before/after the unchanged host clock edges. Event filtering does not retain every AS/phase transition.',
                       'MAME CPU command/vector taps do not observe direct MCU P2/BUS/shared-write/HALT ordering. Its reset/first-instruction capture epoch is not proven by retained traces.',
                       'Hash-matched capture manifest attests finite completion; a separate historical raw exit receipt was not retained.',
                       'RGB/work/strip arrays are pinned as actual evidence only; no epoch alignment, mask, frame shift or graphics success is claimed.'],
             'precise_missing_reference_requirement':['Retain actual process exit0/exe/ROM/Lua/input pins for a capture observing CPU and MCU from reset before the first command.',
                       'Observe MAME MCU command data/address/read-mode, P2/control, BUS, HALT assertion/release, shared low-byte write and IRQ2/IACK order with emulated timestamps.',
                       'Use the actual legal constant attract ports0/1/3; no memory edits, synthetic MCU replies or CPU state seeding.'],
             'next_bound_from_primary_trace':None if first_command is None else int(first_command['frame'])+2}
    output.write_text(json.dumps(receipt,indent=2)+'\n')
    (JOB/'verification.md').write_text('# Actual private Super Stingray coupled boot diagnostic\n\nBuild and bounded16-field run both exited0 using the same ELF and real68000/Z80/T48. Source/ROM/legalinput pins and compiled-copy hashes are retained in verification.json. Canonical hardware and the preferred P6 candidate remained unchanged.\n\n'+
      f"Observed {len(commands)} accepted MCU commands, {len(shared)} shared writes, {len(irq)} IRQ2 pulses, {len(controls)} firmware control events and {len(buses)} firmware BUS events. The initial CPU/MCU command exchange is {'complete' if minimal_complete else 'not complete'} within this bound.\n\n"+
      'The retained MAME executable, source, recorder and ROM identities match. CPU command taps omit direct MCU control/HALT/shared-write ordering, and no separate historical process-exit receipt remains. This evidence establishes only the recorded finite behavior; it does not qualify physical timing, paired MCU ordering, attract/gameplay or graphics.\n')
    owned=[HERE/'prepare_coupled_boot16.py',HERE/'coupled_worker.py',Path(__file__),HERE/'verify_coupled_boot16_v1.py',HERE/'repair_verify_coupled_boot16.py',JOB/'verifier_v1_failure.json',JOB/'reference_provenance.json',JOB/'source_pins.json',
           JOB/'build_worker.json',JOB/'build_job.json',JOB/'build_exit.json',JOB/'run_worker.json',JOB/'run_job.json',JOB/'run_exit.json',
           output,JOB/'verification.md',JOB/'source/sim/system_main.cpp',JOB/'source/sim/build_system.sh',JOB/'source/sim/coupled_observer.vlt']
    manifest={'schema':'private_stingray_coupled_boot16_import_v1','entries':[{'path':str(p),'sha256':H(p),'bytes':p.stat().st_size} for p in owned],
              'large_actual_evidence_references':[{'path':str(p),'sha256':H(p),'bytes':p.stat().st_size} for p in
                  [JOB/'build.log',JOB/'run.log',capture/'coupled_mcu.csv',capture/'frames.csv',capture/'applied_inputs.csv']]+image_evidence,
              'source_graph_recovery':str(source_root),'compiled_graph_recovery':tmp,'actual_source_graph_pins':str(JOB/'source_pins.json'),
              'preferred_P6_preparation_immutable':str(HERE/'import_manifest.json'),'initial_exchange_complete':minimal_complete,
              'reference_limits_preserved':True,'rerun_authorized_by_manifest':False}
    (JOB/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'checks':checks,'MCU_commands':len(commands),'MCU_shared_writes':len(shared),'MCU_IRQ2_pulses':len(irq),
                      'MCU_control_events':len(controls),'MCU_bus_events':len(buses),'HALT_transitions':halts,
                      'first_MAME_command':first_command,'initial_exchange_complete':minimal_complete,
                      'frames_last':frames[-1],'verification_sha256':H(output),'manifest_sha256':H(JOB/'import_manifest.json'),
                      'manifest_entries':len(owned),'verification':str(output)}))

if __name__=='__main__':main()
