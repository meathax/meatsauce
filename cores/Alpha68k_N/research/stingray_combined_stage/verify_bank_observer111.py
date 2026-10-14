"""Qualify one actual observer terminal; do not build, replay or alter state."""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
JOB=HERE/'bank_before_after111'
OLD=HERE/'coupled_boot111'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def rows(p):
    with p.open() as f:return list(csv.DictReader(f))

def verify():
    assert not (JOB/'verification.json').exists(),'Preserve the existing qualification.'
    pins=json.loads((JOB/'source_pins.json').read_text())
    oldproof=json.loads((OLD/'verification.json').read_text())
    exits={stage:json.loads((JOB/(stage+'_exit.json')).read_text()) for stage in ['build','run']}
    cap=JOB/'capture';oldcap=OLD/'capture'
    frames=rows(cap/'frames.csv');inputs=rows(cap/'applied_inputs.csv');mcu=rows(cap/'coupled_mcu.csv')
    arrays=[]
    for p in sorted(oldcap.glob('frame_*')):
        if p.is_file():
            q=cap/p.name
            arrays.append({'name':p.name,'old_sha256':H(p),'observer_sha256':H(q) if q.exists() else None,
                           'pass':q.exists() and H(p)==H(q)})
    tmp=(JOB/'source/sim/build/wsl_system_build_dir.txt').read_text().strip()
    command=['wsl.exe','-d','Ubuntu','--exec','/bin/bash','-c',
             'cd "$1" && sha256sum -- ./*.sv ./*.v ./*.cpp ./*.h ./*.vlt','sha_scope',tmp]
    actual=subprocess.run(command,capture_output=True,text=True)
    compiled={}
    if actual.returncode==0:
        for line in actual.stdout.splitlines():
            sha,name=line.split(None,1);compiled[Path(name.strip()).name]=sha
    expected={Path(p['path']).name:p['observer_sha256'] for p in pins['source_files'] if Path(p['path']).suffix!='.mem'}
    compiled_checks={name:expected.get(name)==sha for name,sha in compiled.items()}
    checks={
      'actual_build0':exits['build']['exit_code']==0,'actual_run0':exits['run']['exit_code']==0,
      'same_observer_ELF_build_run':exits['build']['ELF_sha256']==exits['run']['ELF_sha256'],
      'all75_frozen_observer_inputs_unchanged':all(H(Path(p['path']))==p['observer_sha256'] for p in pins['source_files']),
      'only_host_readonly_vlt_differ_from_original':all(p['base_sha256']==p['observer_sha256'] or
          Path(p['path']).name in ['system_main.cpp','coupled_observer.vlt'] for p in pins['source_files']),
      'actual_compiled_copies_match':actual.returncode==0 and len(compiled_checks)>60 and all(compiled_checks.values()),
      'original111_failed_endpoint_receipt_immutable':H(OLD/'verification.json')==pins['original111_verification_sha256'],
      'same_legal_input_bytes':H(Path(pins['required_input']))==pins['required_input_sha256'],
      'actual111_contiguous_fields':len(frames)==111 and [int(r['frame']) for r in frames]==list(range(111)),
      'all111_frame_rows_exact':frames==rows(oldcap/'frames.csv'),
      'all_actual_applied_inputs_exact':inputs==rows(oldcap/'applied_inputs.csv'),
      'all_actual_MCU_tick_events_exact':mcu==rows(oldcap/'coupled_mcu.csv'),
      'all_retained_RGB_work_strip_arrays_exact':bool(arrays) and all(r['pass'] for r in arrays),
      'uncapped_IACK_and_epoch_rows_exact':rows(cap/'epoch_events.csv')==rows(oldcap/'epoch_events.csv'),
      'full_pixels_no_duplicates_deadlines_overflow':all(int(r['pixels'])==57344 and int(r['duplicates'])==0 and
          int(r['deadline_misses'])==0 and int(r['row_overflows'])==0 for r in frames)}
    edges=rows(cap/'bank_write_edges.csv')
    names={34:'22',41:'29',255:'ff'}
    mismatches=[r for r in edges if r['match']!='1']
    shared=[r for r in mcu if r['edge']=='before' and r['shared_write']=='1']
    exchanges=[]
    for event in shared:
        address=int(event['shared_addr']);tick=int(event['tick']);name=names.get(address)
        candidates=[r for r in edges if int(r['tick_before'])==tick and int(r['port_addr'])==address and r['MCU_work']=='1']
        edge=candidates[0] if len(candidates)==1 else None
        later=[r for r in edges if int(r['tick_before'])>tick and int(r['port_addr'])==address and
               (r['write_hi']=='1' or r['write_lo']=='1')]
        firstlow=next((r for r in later if r['write_lo']=='1'),None)
        committed=None if edge is None or name is None else int(edge['after'+name])&255==int(event['shared_data'])
        preserved=None if edge is None or name is None else int(edge['before'+name])>>8==int(edge['after'+name])>>8
        exchanges.append({'MCU_event':event,'actual_edge':edge,'MCU_low_committed_on_same_edge':committed,
             'high_byte_preserved_on_MCU_edge':preserved,'later_same_word_write_count':len(later),
             'first_later_low_write':firstlow,'first_later_low_write_is_CPU':None if firstlow is None else firstlow['CPU_work']=='1',
             'snapshot110_word':int.from_bytes((cap/'frame_000110.work.bin').read_bytes()[address*2:address*2+2],'big'),
             'interpretation':'Actual storage edge and later actual source-strobe writes only; physical board/MAME temporal pairing is not established.'})
    checks['both_actual_MCU_shared_edges_covered']=len(exchanges)==2 and all(e['actual_edge'] is not None for e in exchanges)
    checks['both_MCU_low_commits_and_high_preservation_observed']=len(exchanges)==2 and all(
         e['MCU_low_committed_on_same_edge'] and e['high_byte_preserved_on_MCU_edge'] for e in exchanges)
    # An unexpected reset/init or source path remains diagnostic; do not mask it.
    checks['all_retained_target_bank_edges_match_actual_write_lanes']=bool(edges) and not mismatches
    protocol=all(checks.values())
    receipt={'schema':'actual_sstingry_bank_before_after111_v1','checks':checks,'source_protocol_and_storage_edge_pass':protocol,
       'build_exit':exits['build'],'run_exit':exits['run'],'source_pins_sha256':H(JOB/'source_pins.json'),
       'verifier_sha256':H(Path(__file__)),'compiled_graph':tmp,'compiled_hash_command':command,
       'compiled_hash_exit':actual.returncode,'compiled_hash_stderr':actual.stderr,'compiled_hashes':compiled,
       'compiled_checks':compiled_checks,'bank_edges_retained':len(edges),'bank_edge_mismatches':mismatches[:20],
       'MCU_exchanges':exchanges,'all_retained_array_fidelity':arrays,
       'old_failed_endpoint_receipt_path':str(OLD/'verification.json'),'old_failed_endpoint_sha256':H(OLD/'verification.json'),
       'old_endpoint_failure_preserved':True,'old_endpoint_failure_proves_dropped_write':False,
       'functional_RTL_fix_justified_by_this_receipt':False,'production_edited':False,'graphics_pass':False,
       'full_attract_pass':False,'gameplay_pass':False,'physical_MAME_MCU_timing_pass':False,
       'limits':['Only words0x22,0x29,0xff have before/after storage histories; all write strobes to those words are retained including identical-data writes.',
         'Predicted byte values are report-only and never drive simulated state.',
         'An MCU committed byte later replaced by an actual CPU write explains the old endpoint without proving gameplay functionality or intended software semantics.',
         'Physical HALT cutoff and paired MAME MCU/shared-write timing remain unqualified; no phase shift or functional RTL change is authorized by an endpoint failure.']}
    save(JOB/'verification.json',receipt)
    (JOB/'verification.md').write_text('# Super Stingray actual storage-edge observer111\n\n'+
       f"Actual build and111-field run exited {exits['build']['exit_code']}/{exits['run']['exit_code']}. All source, overlapping-frame and observed storage-edge checks {'pass' if protocol else 'fail'}. Recorded {len(edges)} target bank edges and {len(exchanges)} MCU exchanges.\n\n"+
       '\n'.join(f"Word0x{int(e['MCU_event']['shared_addr']):02x}: actual MCU low-byte commit={e['MCU_low_committed_on_same_edge']}; preserved high={e['high_byte_preserved_on_MCU_edge']}; first subsequent low write CPU={e['first_later_low_write_is_CPU']}." for e in exchanges)+
       '\n\nThe original endpoint failure remains immutable and does not prove a dropped write. This observer contains no functional RTL edits. Full attract/gameplay, graphics and physical MAME timing acceptance remain open.\n')
    owned=[HERE/'prepare_bank_observer111.py',HERE/'bank_observer_worker111.py',Path(__file__),JOB/'source_pins.json',
      JOB/'source/sim/system_main.cpp',JOB/'source/sim/coupled_observer.vlt',JOB/'verification.json',JOB/'verification.md']
    for stage in ['build','run']:
        owned += [JOB/(stage+'_'+kind+'.json') for kind in ['worker','job','exit']]
    evidence=[JOB/'build.log',JOB/'run.log']+[p for p in sorted(cap.iterdir()) if p.is_file()]
    save(JOB/'import_manifest.json',{'schema':'private_sstingry_bank_observer111_import_v1',
        'entries':[{'path':str(p),'sha256':H(p),'bytes':p.stat().st_size} for p in owned],
        'large_evidence_references':[{'path':str(p),'sha256':H(p),'bytes':p.stat().st_size} for p in evidence],
        'source_recovery':str(JOB/'source'),'compiled_recovery':tmp,'no_production_edit':True,
        'original111_evidence_immutable':True,'replay_authorized_by_manifest':False})
    print(json.dumps({'checks':checks,'pass':protocol,'bank_edges':len(edges),'exchanges':exchanges,
       'verification_sha256':H(JOB/'verification.json'),'manifest_sha256':H(JOB/'import_manifest.json')}))

def main():
    action=sys.argv[1] if len(sys.argv)>1 else 'verify'
    if action=='launch-wait':
        assert not (JOB/'verification_waiter.json').exists(),'Observe the registered waiter.'
        with (JOB/'verification_waiter.log').open('w',encoding='utf8') as log:
            child=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),'wait'],cwd=HERE,
                stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'verification_waiter.json',{'pid':child.pid,'helper_sha256':H(Path(__file__)),'poll_seconds':45,'started':time.time()})
        print(json.dumps({'waiter_pid':child.pid}));return
    if action=='wait':
        while not (JOB/'run_exit.json').exists():time.sleep(45)
    assert action in ['wait','verify']
    try:
        verify();save(JOB/'verification_exit.json',{'exit_code':0,'helper_sha256':H(Path(__file__)),'finished':time.time()})
    except Exception as error:
        save(JOB/'verification_exit.json',{'exit_code':1,'error':repr(error),'helper_sha256':H(Path(__file__)),'finished':time.time()});raise

if __name__=='__main__':main()
