"""Adapt retained15protocol contract to the reviewed P2 game181 scope; no replay."""
from pathlib import Path
import csv,hashlib,json,os,subprocess,sys,time
O=Path(__file__).resolve().parent;J=O/'p2_gameplay181'
BASE=O.parent/'stingray_combined_stage/next_coupled_scope_v2'
CAN=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
REF=CAN/'sim/captures/sstingry/gameplay'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf-8')
def rows(p):return list(csv.DictReader(p.open(newline='',encoding='utf-8')))
def verify():
    assert not (J/'protocol_verification_v3.json').exists(),'Immutable qualification already exists'
    a=json.loads((J/'admission.json').read_text());c=json.loads((J/'source_closure.json').read_text());v=json.loads((J/'verification.json').read_text())
    exits={k:json.loads((J/(k+'_exit.json')).read_text()) for k in ['build','run']}
    frames=rows(J/'capture/frames.csv');inputs=rows(J/'capture/applied_inputs.csv');legal=rows(BASE/'gameplay_inputs.csv')
    native=rows(J/'capture/accepted_inputs.csv');mame=rows(O/'native_observer181/mame181/accepted_reads.csv')
    tmp=(J/'source/sim/build/wsl_system_build_dir.txt').read_text().strip()
    command=['wsl.exe','-d','Ubuntu','--exec','/bin/bash','-c','cd "$1" && sha256sum -- ./*.sv ./*.v ./*.cpp ./*.h ./*.vlt','p2compiled',tmp]
    p=subprocess.run(command,capture_output=True,text=True);compiled={}
    if not p.returncode:
        for line in p.stdout.splitlines():h,n=line.split(None,1);compiled[Path(n.strip()).name]=h
    expected={Path(r['path']).name:r['candidate_sha256'] for r in c['source_files'] if Path(r['path']).suffix in ['.sv','.v','.cpp','.h','.vlt']}
    excluded={'alpha68kn_crt.sv','alpha68kn_pll.sv'}
    recipe=J/'source/sim/build_system.sh'
    assert not any(n in recipe.read_text() for n in excluded)
    assert set(expected)-set(compiled)==excluded and not (set(compiled)-set(expected))
    expected_native={n:h for n,h in expected.items() if n not in excluded}
    assert len(expected_native)==70
    compiled_check={n:compiled.get(n)==h for n,h in expected_native.items()}
    effective={0:inputs[0]}
    for row in inputs[1:]:effective[int(row['frame'])+1]=row
    ns=[r for r in native if int(r['address'])==0xc0000 and int(r['frame'])>=159]
    ms=[r for r in mame if int(r['address'])==0xc0000 and int(r['frame'])>=159]
    nactive=[r for r in ns if int(r['data_in_after'])&128];mactive=[r for r in ms if int(r['data'])&128]
    ncredit=[r for r in native if int(r['address'])==0x20044 and int(r['main_pc'])==5274 and (int(r['data_in_after'])&255)==1]
    mcredit=[r for r in mame if int(r['address'])==0x20044 and int(r['main_pc'])==5274 and (int(r['data'])&255)==1]
    reference=json.loads((BASE/'reference_coverage.json').read_text())['references']['gameplay']
    comparisons=v['comparisons']
    checks={
      'actual_build0':exits['build']['exit_code']==0,
      'actual_run0':exits['run']['exit_code']==0,
      'same_frozen_ELF_build_admission_run':H(Path(a['ELF']['path']))==a['ELF']['sha256']==json.loads((J/'ELF.json').read_text())['sha256'],
      'all75_candidate_sources_unchanged':len(c['source_files'])==75 and all(H(Path(r['path']))==r['candidate_sha256'] for r in c['source_files']),
      'compiled_real_CPU_graph_hashes_exact':p.returncode==0 and set(compiled)==set(expected_native) and all(compiled_check.values()),
      '181_contiguous_fields':len(frames)==181 and [int(r['frame']) for r in frames]==list(range(181)),
      'actual_original_input_and_ROM_hashes':all(H(Path(a[k]['path']))==a[k]['sha256'] for k in ['input','ROM']) and a['input']['sha256']=='20833903b9400168a62a83b7e2027aaae2a662ff12184e58c8622697a3608ee8',
      'all_applied_actual_ports_match_exact_original_input':len(inputs)==182 and all(tuple(int(r[k]) for k in ['controls','dips','coins_n'])==tuple(int(legal[int(r['frame'])][k]) for k in ['in0','in1','in2']) for r in inputs),
      'effective_coin122_127_and_start162_167':all(int(effective[f]['coins_n'])==2 for f in range(122,128)) and all(int(effective[f]['controls'])==128 for f in range(162,168)),
      'actual_CPU_consumed_first_start162_matches_MAME':bool(nactive and mactive) and int(nactive[0]['frame'])==int(mactive[0]['frame'])==162,
      'actual_matched_PC_coinage_reply1':bool(ncredit and mcredit),
      'preinput_completed_MAME_RGB_exact':all(r['RGB_different_pixels']==0 for r in comparisons if r['frame'] in [0,30,90,119]),
      'all_pixels_no_duplicates_deadlines_overflow':all(int(r['pixels'])==57344 and int(r['duplicates'])==0 and int(r['deadline_misses'])==0 and int(r['row_overflows'])==0 for r in frames),
      'all5_required_complete_RGB_work_strip_coordinates_present':sorted(r['frame'] for r in comparisons)==[0,30,90,119,179],
      'all_primary_reference_artifact_pins_unchanged':all(H(REF/r['path'])==r['sha256'] for r in reference['artifacts'])}
    assert len(checks)==15
    old=BASE/'coupled181/capture';historical=[]
    for p0 in sorted(old.glob('frame_*')):
        try:f=int(p0.name.split('_')[1].split('.')[0])
        except ValueError:continue
        if f>119:continue
        p1=J/'capture'/p0.name
        if p1.exists():historical.append({'name':p0.name,'baseline_sha256':H(p0),'candidate_sha256':H(p1),'exact':H(p0)==H(p1)})
    mc=rows(J/'capture/coupled_mcu.csv');nc=[r for r in mc if r['edge']=='before' and r['command']=='1'];primary=[]
    with (REF/'events.csv').open(encoding='utf-8') as stream:
        for r in csv.DictReader(stream):
            if int(r['frame'])>=181:break
            if r['area'] in ['mcu_command_read','mcu_command_write']:primary.append(r)
    nk=lambda r:(int(r['command_addr']),r['rw']=='1',None if r['rw']=='1' else int(r['dout'])&255)
    mk=lambda r:((int(r['address'])-0x80000)//2,r['area']=='mcu_command_read',None if r['area']=='mcu_command_read' else int(r['data'])&255)
    prefix=0
    for n,m in zip(nc,primary):
        if nk(n)!=mk(m):break
        prefix+=1
    receipt={'scope':'Reviewed P2 candidate real181; adapted15contract. Historical unchanged-MCU prefix assertions replaced by actual accepted coinage/start checks and completedPNG preinput checks.','checks':checks,'protocol_source_pass':all(checks.values()),'compiled_graph':tmp,'compiled_hashes':compiled,'compiled_hash_checks':compiled_check,'native_recipe_exclusions':{'names':sorted(excluded),'reason':'CRT output wrapper and hardware PLL are frozen75source entries but not compiled by the reviewed real-system native recipe. Their sourcepins remain checked.','recipe_sha256':H(recipe)},'compiled_hash_exit':p.returncode,'compiled_hash_stderr':p.stderr,'closure_sha256':H(J/'source_closure.json'),'admission_sha256':H(J/'admission.json'),'verifier_sha256':H(Path(__file__)),'actual_start_consumption':{'native':ns,'MAME':ms},'actual_coinage_consumption':{'native':ncredit,'MAME':mcredit},'graphics':{'all5_completed_RGB_exact':v['all5_completed_RGB_exact'],'comparisons':comparisons},'historical_preinput_array_comparisons':historical,'historical_MCU_frame_row_exactness_is_not_candidate_acceptance':True,'software_commands':{'native_commands':len(nc),'MAME_commands':len(primary),'ordered_exact_prefix':prefix,'full_equal':len(nc)==len(primary)==prefix,'native_first_mismatch':nc[prefix:prefix+1],'MAME_first_mismatch':primary[prefix:prefix+1],'physical_cycle_pairing_claimed':False},'audio_native':json.loads((J/'capture/audio.json').read_text()),'audio_MAME_exactness_not_qualified':True,'whole_game_1800_pass':False,'production_edited':False,'timing_resources_hardware_pass':False}
    save(J/'protocol_verification_v3.json',receipt)
    code=0 if all(checks.values()) else 1
    save(J/'protocol_verification_v3_exit.json',{'exit_code':code,'finished':time.time(),'worker_pid':os.getpid(),'result_sha256':H(J/'protocol_verification_v3.json')})
    print(json.dumps({'protocol_checks_passed':sum(checks.values()),'count':len(checks),'failed':[k for k,v in checks.items() if not v],'all5_completed_RGB_exact':v['all5_completed_RGB_exact'],'software_commands':receipt['software_commands']}),flush=True)
    return code
if __name__=='__main__':
    if '--wait' in sys.argv:
        while not (J/'verification_exit.json').exists():
            if (J/'worker_failure.json').exists():raise RuntimeError('Owned worker failed; no replay launched by verifier')
            time.sleep(30)
    sys.exit(verify())
