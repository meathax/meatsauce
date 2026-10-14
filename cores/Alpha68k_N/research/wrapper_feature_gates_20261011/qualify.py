import hashlib,json,difflib,csv
from pathlib import Path
OUT=Path(__file__).resolve().parent
CAN=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def put(p,x):p.write_text(json.dumps(x,indent=2)+'\n',newline='\n')
checks=[]
def check(name,ok):
    checks.append(dict(name=name,passed=bool(ok)))
    assert ok,name
pre=read(OUT/'preparation.json');actual=read(OUT/'actual_prebuild_source_pins_v3.json')
for name in ['build_v3','run_v3']:
    exit=read(OUT/(name+'_exit.json'))
    check(name+'_actual_exit0',exit['actual_exit_code']==0 and sha(OUT/(name+'.log'))==exit['log_sha256'])
check('canonical_wrapper_unchanged',sha(CAN/'Alpha68k_N.sv')==pre['canonical_wrapper_sha256'])
check('actual_prebuild_inputs_unchanged',all(sha(Path(e['path']))==e['sha256'] for e in actual['source_pins']))
elf=read(OUT/'elf_v3.json');p=Path(elf['path'])
check('actual_ELF_pinned',sha(p)==elf['sha256'] and p.read_bytes()[:4]==bytes.fromhex('7f454c46'))
join=OUT.parent/'stingray_combined_stage/next_coupled_scope_v2'
closure=read(join/'source_closure.json')
check('joined_closure_pinned',sha(join/'source_closure.json')==pre['parent_closure_sha256'])
joined=[]
for e in closure['source_files']:
    p=Path(e['path'])
    try:rel=p.relative_to(join/'source')
    except ValueError:continue
    if rel.parts[0]=='rtl':
        assert sha(OUT/'source'/rel)==e['combined_sha256'];joined.append(rel.as_posix())
check('joined_P6_game_HDL_unchanged',len(joined)>60)
lines=(OUT/'effective_sources_v2.sha256').read_text().splitlines()
effective=[]
for line in lines:
    h,rel=line.split('  ',1);p=OUT/'source'/rel
    if rel=='sys/video_mixer.sv':
        adapter=read(OUT/'scope_adapter_v2.json')
        # The adapter contract itself preserves source/output byte hashes.
        assert sha(p)==adapter['original_sha256'] and h==adapter['adapted_sha256']
        effective.append(dict(path=rel,sha256=h,scope_adapter=adapter))
    else:
        assert sha(p)==h
        effective.append(dict(path=rel,sha256=h))
check('effective_native_HDL_host_pins_bound',len(effective)>80)
rows=list(csv.DictReader((OUT/'capture/frames.csv').open()))
check('two_real_profile2_fields',len(rows)==2 and all(int(e['core_pixels'])==57344 and int(e['duplicates'])==0 and int(e['unmapped'])==0 and int(e['deadlines'])==0 and int(e['overflows'])==0 for e in rows))
result=read(OUT/'capture/result.json');features=read(OUT/'capture/features.json')
check('complete_actual_ROM_HPS_release',result['passed'] and result['profile']==2 and result['rom_words']==327680 and result['frames']==2)
check('read_only_512byte_MCU_borrow_pause_resume_reset',features['passed'] and features['profile']==2 and features['read_only_shared_bytes']==512 and features['mcu_drain'] and features['cpu_mcu_resume'] and features['reset_revokes_pause'])
host=(OUT/'source/sim/wrapper_main.cpp').read_text()
check('complete_bad_profile_image_exercised', 'for(unsigned i=0;i<rom.size();i++) {\n        while(top.SIM_IOCTL_WAIT) tick();\n        word(true,i==5?3:rom[i]);' in host and 'complete invalid-profile image released reset' in host)
check('borrower_did_not_seed_scores_or_workRAM','SIM_TEST_HS_WRITE=1' not in host and 'download(4,scores)' not in host)
canonical=(CAN/'Alpha68k_N.sv').read_text();admit=canonical.replace('board_load_data[15:8]<=1','board_load_data[15:8]<=2')
check('single_required_integration_change',canonical.count('board_load_data[15:8]<=1')==1)
(OUT/'Alpha68k_N.production.sv').write_text(admit,newline='\n')
(OUT/'admit_profile2.patch').write_text(''.join(difflib.unified_diff(canonical.splitlines(True),admit.splitlines(True),fromfile='canonical/Alpha68k_N.sv',tofile='integration-candidate/Alpha68k_N.sv')),newline='\n')
qualification=dict(schema='private_profile2_wrapper_qualification_v1',passed=True,checks=checks,actual_exit_codes=dict(build=0,run=0),elf=elf,source_binding=dict(joined_parent_closure_sha256=pre['parent_closure_sha256'],canonical_wrapper_sha256=pre['canonical_wrapper_sha256'],production_admission_candidate_sha256=sha(OUT/'Alpha68k_N.production.sv'),actual_prebuild_manifest_sha256=sha(OUT/'actual_prebuild_source_pins_v3.json'),effective_sources=effective),features=features,result=result,limits=['Profile2 admission is private integration-only until real MCU/gameplay source gate closes','Pre-MCU-P2-fix source epoch; readonly observed-P2 boundary test does not prove every pause arrival edge nor qualify corrected future pipeline','Borrow test uses SIM_TEST_HS_ACCESS read-only, not real donor-earned save/reset/restore','First framework field57602samples is preserved; only2fields, no four-field settled video-mode claim','Physical PLL/SDRAM timing/audio/hardware and complete final timing remain unqualified'],failures_retained=['build_exit.json actual2 GNU Make spaces','build_v2_exit.json actual1 repeated framework adaptation refused'])
put(OUT/'qualification.json',qualification)
(OUT/'findings.md').write_text('''# Private profile2 wrapper qualification

The canonical wrapper deliberately rejects profile2 until P6 integration. The one-line `<=2` admission candidate remains private; this is an integration requirement, not a shipped bug. Its actual joined P6 board, real T48 MCU firmware, HPS ioctl loader and MiSTer video framework compiled and ran under Ubuntu WSL with native exits0/0. No production source, framework, clock, RBF or hardware was changed.

The finite real RTL run rejected a complete bad-profile3 image, then accepted all327680 words of the actual Stingray image and released reset through HPS. Two native fields had57344pixels, no duplicates, bus unmapped accesses, renderer misses or overflows. The original57602-sample startup framework field is retained and is not a settled mode claim.

OSD/user pause, actual observed P2 event followed by OSD pause, MCU/CPU freeze with raster running,512 read-only shared bytes stable across repeated borrow, release/resumption, and soft-reset revocation of user pause all passed. This test issues no score or work-RAM writes. OSD synchronization allows several master edges before pause arrives, so observing a pending P2 event before requesting OSD pause does not prove every possible coincident pause arrival edge. Board arbitration still gates the borrower behind `paused` and excludes live MCU shared writes; the fixed MCU pipeline must be bound to a later focused check if its output handling changes.

The generated admission patch and production candidate contain exactly one functional integration change. Read-only observer ports are present only in the private simulation wrapper. `qualification.json` binds the actual ELF, joined source closure, native build/runtime exits, HPS word count and effective compiler source hashes. Failed make-space and double-adaptation attempts remain preserved with actual exits2/1.

Remaining finite P8 gates: apply profile2 admission only after corrected MCU gameplay qualifies; rebind reset and MCU-pipeline changes to this focused protocol fixture; genuine Japan/Stingray CPU-earned donor save/reset/restore; profile-dependent game effects of coinage/cocktail/flip; changed profile2 video modes and OSD action labels. Reuse existing unchanged Kyros World earned178byte and framework/CRT/scaler proofs. Physical outputs/listening and final accepted all-corner timing remain P9 prerequisites.
''',newline='\n')
files=['prepare.py','run_job.py','launch_v2.py','launch_v3.py','run_job_v2.py','run_job_v3.py','qualify.py','build.sh','preparation.json','actual_prebuild_source_pins_v3.json','worker_v3_job.json','build_v3_job.json','build_v3_exit.json','run_v3_job.json','run_v3_exit.json','elf_v3.json','qualification.json','findings.md','admit_profile2.patch','wrapper_integration.patch','Alpha68k_N.production.sv','scope_adapter_v2.json','effective_sources_v2.sha256','framework_scope_recovery.json','build_exit.json','build_v2_exit.json','capture/result.json','capture/features.json','capture/frames.csv','build_v3.log','run_v3.log']
put(OUT/'import_manifest.json',dict(schema='private_wrapper_feature_import_v1',entries=[dict(path=str(OUT/name),sha256=sha(OUT/name),bytes=(OUT/name).stat().st_size) for name in files],recovery_source_root=str(OUT/'source'),limits=qualification['limits']))
print(json.dumps(dict(passed=True,checks=len(checks),ELF_sha256=elf['sha256'],manifest_sha256=sha(OUT/'import_manifest.json'),features=features)))
