from pathlib import Path
import csv, hashlib, json, re, subprocess, sys

root=Path(__file__).parent
source=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_candidate_qualification_v7')
prior=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_candidate_qualification_v3')
if '--worker' not in sys.argv:
    assert not (root/'qualification_review_v1_exit.json').exists(), 'Immutable output exists'
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'qualification_review_v1.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'scope':'Read-only qualification/source verification; no RTL replay or Quartus.'}
    (root/'qualification_review_v1_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr)
    sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def tokens(path):
    pieces=re.findall(r'/\*.*?\*/|//[^\r\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_$][A-Za-z0-9_$]*|[0-9]+|[^\s]',path.read_text(encoding='utf-8'),re.S)
    return [x for x in pieces if not x.startswith(('/*','//'))]
manifest=source/'import_manifest.json'
assert sha(manifest)=='bc0af87993a78ba9ce95127f50b5324a5749e605b9c0227a9b138f92fa255334'
data=json.loads(manifest.read_text());assert len(data['files'])==50
for entry in data['files']:
    path=Path(entry['path']);assert path.stat().st_size==entry['bytes'] and sha(path)==entry['sha256'],path
assert sha(source/'candidate.patch')=='fc0dfc663584bf3d5f2ed27d2c87a4308f82cb6e362e63e43e24b60479ddb5f1'
assert sha(source/'candidate/t48_core.v')=='2ad3acf392e1deec18d5d7f2c8d878b33b00073c55a7c032cd0155dfac46bf6d'
assert sha(source/'candidate/alpha68kn_mcu.sv')=='26614f565524e7dc136c3c898eb044807d22d2c6ce473dcc64d7f54258a97120'
static=json.loads((root/'static_review_v1.json').read_text())
assert static['pass'] and json.loads((root/'static_review_v1_exit.json').read_text())['actual_exit_code']==0
for profile in ['baseline','candidate']:
    for name in ['t48_core.v','alpha68kn_mcu.sv']:
        assert tokens(source/profile/name)==tokens(prior/profile/name),(profile,name,'functional source changed after review')
verification=json.loads((source/'verification.json').read_text())
unit_exits={}
for profile in ['baseline','candidate']:
    for stage in ['build','run']:
        path=source/profile/(stage+'_exit.json');value=json.loads(path.read_text());assert value['exit_code']==0
        unit_exits[profile+'_'+stage]={'path':str(path),'sha256':sha(path),'actual_exit_code':value['exit_code']}
    for pin in verification['results'][profile]['source_pins']:
        assert sha(source/profile/pin['name'])==pin['sha256'],pin
    job=json.loads((source/profile/'build_job.json').read_text())
    assert job['command'][0]=='wsl.exe' and job['command'][1:3]==['-d','Ubuntu']
    assert '/usr/local/bin/verilator' in job['command']
    for required in ['fixture.sv','alpha68kn_mcu.sv','t48_core.v','main.cpp']:assert required in job['command']
assert (source/'baseline/fixture.sv').read_bytes()==(source/'candidate/fixture.sv').read_bytes()
assert (source/'baseline/mcu.hex').read_bytes()==(source/'candidate/mcu.hex').read_bytes()
assert sha(source/'candidate/mcu.hex')=='6d5a895aeeec178b2fb55b5af94db6091d20ed17bec918ffd1dc14bf606c9bc9'
firmware=[int(byte,16) for byte in (source/'candidate/mcu.hex').read_text().split()]
assert len(firmware)==1024
assert firmware[0x188:0x18a]==[0x8a,0x10],'Expected genuine ORL P2,#10 opcode'
def host_stimulus(path):
    text=path.read_text();rows=text.splitlines();returns=[row for row in rows if row.lstrip().startswith('return ')];assert len(returns)==1
    return '\n'.join(row for row in rows if row!=returns[0]),returns[0]
base_host,base_return=host_stimulus(source/'baseline/main.cpp');new_host,new_return=host_stimulus(source/'candidate/main.cpp')
assert base_host==new_host,'Host stimulus or observation differed across pair'
assert '!coinage_reply && lost_ready>0' in base_return
assert 'coinage_reply && lost_ready==0' in new_return
fixture=(source/'candidate/fixture.sv').read_text()
assert 'initial $readmemh("mcu.hex",rom);' in fixture
assert 'always @(posedge clk) program_q<=rom[program_addr[9:0]];' in fixture
assert 'force ' not in fixture and 'release ' not in fixture
assert '.pause_game(1\'b0)' in fixture
for illegal in ['t.mcu','t.p2_latch=','t.control=','t.shared_write=','t.main_halt=']:assert illegal not in new_host
results={profile:json.loads((source/profile/'result.json').read_text()) for profile in ['baseline','candidate']}
assert results['baseline']['ready_restore_lost_events']>0 and results['baseline']['coinage_reply']==0
assert results['candidate']['ready_restore_lost_events']==0 and results['candidate']['coinage_reply']==1
assert all(results[profile]['sent']==1 and results[profile]['ID_reply']==1 and results[profile]['sent_second']==1 for profile in results)
rows={}
for profile in ['baseline','candidate']:
    with (source/profile/'events.csv').open(newline='') as handle:rows[profile]=[{key:int(value) for key,value in row.items()} for row in csv.DictReader(handle)]
    assert len(rows[profile])==results[profile]['recorded_events']
candidate=rows['candidate'];writes=[row for row in candidate if row['shared_write']]
assert [(row['shared_addr'],row['shared_data']) for row in writes]==[(255,255),(41,35),(41,34),(34,1)]
assert all(row['main_halt']==1 and row['pending']==1 and row['control_after']==row['latch_before'] for row in writes)
restores=[row for row in candidate if row['control_event'] and not row['control_before']&16 and row['control_after']&16]
releases=[row for row in candidate if row['control_event'] and row['control_before']&16 and not row['control_after']&16]
assert len(restores)==4 and len(releases)==4 and all(row['main_halt']==0 for row in releases)
assert all(row['pending']==1 and row['control_after']==row['latch_before'] for row in candidate if row['control_event'])
causal=json.loads((source/'causal_proof.json').read_text())
assert causal['candidate_real_firmware_shared_writes']==[{key:str(value) for key,value in row.items()} for row in writes]
provenance=json.loads((source/'SOURCE.proposed.json').read_text())
assert provenance['candidate_core_sha256']==sha(source/'candidate/t48_core.v')
assert provenance['candidate_wrapper_sha256']==sha(source/'candidate/alpha68kn_mcu.sv')
assert provenance['license_notice']['sha256']==sha(source/'LICENSE.upstream')=='f9870f7d47c16bec37e17b923440d4f0a274d7c409d9327d86e25a000e4bab27'
receipt={'pass':True,'approved_for_bounded_real_game_replay':True,'gameplay_or_timing_qualified':False,'source':str(source),'manifest_sha256':sha(manifest),'manifest_files_verified':50,'candidate_core_sha256':sha(source/'candidate/t48_core.v'),'candidate_wrapper_sha256':sha(source/'candidate/alpha68kn_mcu.sv'),'unit_exits':unit_exits,'same_host_stimulus_except_expected_result':True,'real_firmware_bytes':len(firmware),'ORL_P2_immediate_opcode':[firmware[0x188],firmware[0x189]],'baseline_lost_ready':results['baseline']['ready_restore_lost_events'],'candidate_lost_ready':results['candidate']['ready_restore_lost_events'],'candidate_shared_writes':[(row['shared_addr'],row['shared_data']) for row in writes],'ready_restores':len(restores),'halt_releases':len(releases),'findings':[],'integration_notes':['Apply proposed donor adaptation/credits/hash to production SOURCE.json and donormap at integration.'],'scope':'Read-only pinned full-source and existing paired component build/run/events qualification. No new replay, artificial guest state, Quartus or production edits.'}
(root/'qualification_review_v1.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps(receipt))
