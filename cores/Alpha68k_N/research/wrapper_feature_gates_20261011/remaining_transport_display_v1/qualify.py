import hashlib,json,csv,re
from pathlib import Path
OUT=Path(__file__).resolve().parent
BASE=OUT.parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def put(p,x):p.write_text(json.dumps(x,indent=2)+'\n',newline='\n')
checks=[]
def check(name,ok):
    checks.append(dict(name=name,passed=bool(ok)))
    assert ok,name
admission=read(OUT/'admission.json')
for name in ['build','run']:
    e=read(OUT/(name+'_exit.json'))
    check(name+'_actual_exit0',e['actual_exit_code']==0 and sha(OUT/(name+'.log'))==e['log_sha256'])
check('admitted_source_inputs_unchanged',all(sha(Path(e['path']))==e['sha256'] for e in admission['source_pins']))
pre=read(OUT/'actual_prebuild_source_pins.json')
check('prebuild_source_inputs_unchanged',all(sha(Path(e['path']))==e['sha256'] for e in pre['source_pins']))
check('actual_ROM_pinned',pre['rom_sha256']=='9c60564786045834e97f98350e8310ef37a6027dadecc31cf89f1fa8bfe4358d' and pre['rom_bytes']==655360)
elf=read(OUT/'elf.json');ep=Path(elf['path'])
check('actual_native_ELF_pinned',sha(ep)==elf['sha256'] and ep.read_bytes()[:4]==bytes.fromhex('7f454c46'))
check('owned_job_scan_no_duplicate',read(OUT/'owned_job_scan.json')['actual_exit_code']==0 and not read(OUT/'owned_job_scan.json')['matching_jobs'])
parent=read(BASE/'p2_rebind_v1/preparation.json')
check('approved_P2_sources_bound',all(sha(OUT/'source'/e['path'])==e['candidate_sha256'] for e in parent['approved_p2_changes']))
effective=[]
for line in (OUT/'effective_sources_v2.sha256').read_text().splitlines():
    h,rel=line.split('  ',1);p=OUT/'source'/rel
    if rel=='sys/video_mixer.sv':
        adapter=read(OUT/'scope_adapter_v2.json');assert sha(p)==adapter['original_sha256'] and h==adapter['adapted_sha256']
        effective.append(dict(path=rel,sha256=h,scope_adapter=adapter))
    else:
        assert sha(p)==h;effective.append(dict(path=rel,sha256=h))
check('effective_compiler_HDL_and_host_pins_bound',len(effective)>80)
result=read(OUT/'capture/result.json');display=read(OUT/'capture/remaining_video.json')
check('actual_HPS_profile2_two_native_fields',result['passed'] and result['profile']==2 and result['rom_words']==327680 and result['frames']==2)
rows=list(csv.DictReader((OUT/'capture/frames.csv').open()))
check('native_fields_complete_no_bus_renderer_failures',len(rows)==2 and all(int(e['core_pixels'])==57344 and int(e['duplicates'])==0 and int(e['unmapped'])==0 and int(e['deadlines'])==0 and int(e['overflows'])==0 for e in rows))
check('transport_display_runtime_terminated_all_assertions',display['passed'] and display['profile']==2 and display['additional_master_ticks']<=64*811008)
host=(OUT/'source/sim/wrapper_main.cpp').read_text()
check('no_score_or_game_RAM_seeding','SIM_TEST_HS_WRITE=1' not in host and 'download(4,scores)' not in host)
check('nonuniform_transform_guard_and_gamma_path_present','nonuniform' in host and 'gamma pixel LUT path failed' in host and 'HQ2x field coverage failed' in host)
check('actual_config_and_menu_visibility_checked','H0O5,Aspect ratio,Original,Full Screen;' in host and 'menu()==13' in host and 'menu()==14' in host and 'menu()==4' in host)
text=(OUT/'run.log').read_text();metrics=[]
for m in re.finditer(r'video mode=(\d+) direct=(\d+) lines=(\d+) fields=(\d+) pixels=(\d+)',text):
    keys=['mode','direct','lines','fields','pixels'];metrics.append(dict(zip(keys,map(int,m.groups()))))
check('three_actual_cadence_mode_records',len(metrics)==3 and all(m['fields']==2 for m in metrics))
q=dict(schema='remaining_real_profile2_wrapper_transport_display_qualification_v1',passed=True,checks=checks,actual_exits=dict(build=0,run=0),ELF=elf,source_binding=dict(admission_sha256=sha(OUT/'admission.json'),effective_sources=effective,approved_aspect_patch_sha256=admission['root_approved_patch_sha256'],approved_suite_sha256=admission['root_approved_suite_sha256']),results=dict(initial_profile2_fields=result,transport_display=display,additional_fields=display['additional_master_ticks']/811008,measured_cadence_modes=metrics),qualified_scope=['MRA-compatible default01/nondefault13/cocktail93 DIP delivery only','Individual coinA/B, P1/P2 start,direction and two-action HPS mapping only','Actual HPS CONF_STR and menu mask with H0-gated Aspect ratio','Nonuniform paused real-ROM native image and full180/CW/CCW pixels and quarter-turn DDR addresses','Integer1280x896 geometry, native4:3/rotated3:4/full-screen aspect','Representative CRT H/V adjustment and positive Vsize cadence','HPS gamma LUT RGB17/34/51 actual native and HQ2x pixels,4x HQ coverage and CRT25 scanline flag','Direct-video mode hides HDMI and Vsize options and suppresses rotation DDR writes'],limits=['DIP/coin/player transport while guest paused is not game-effect acceptance','No actual guest lives/cocktail/alternate-player behavior or earned-score claim; effect200 remains unreleased','Only two startup framework fields recorded; first57602 samples retained; later mode checks wait4 settled fields','Ideal PLL/SDRAM model and rotation DDR acceptance only; physical Main/scaler/display/SDRAM/audio/timing remain unqualified','This private image uses approved P2 sources plus menu/readonly observer wrapper changes; final joined canonical image must retain dependent source binding'])
put(OUT/'qualification.json',q)
(OUT/'findings.md').write_text('''# Remaining real profile2 transport/display acceptance

One native Verilator build and one runtime completed with actual exits0/0. The private graph uses the reviewed P2 MCU/T48 pair, unchanged game board/clock/reset/framework and the approved `O5`→`H0O5` Aspect ratio menu fix with read-only simulation observer ports. No canonical source was edited by this task.

All actual HPS configuration, mask, DIP and individual coin/player transfer checks passed. The real ROM image was paused; no scores or game states were seeded. The frozen image was nonuniform before full native180/CW/CCW pixel comparisons, so the display tests were not vacuous. Quarter-turn dimensions, addresses and all57344pixels passed for both directions. Integer geometry was1280x896; native/rotated/full-screen aspect matched the wrapper contract. Native, representative CRT H/V and positive Vsize each produced two measured output fields with the required cadence; gamma LUT programming produced RGB17/34/51 through actual native and HQ2x output, with4x HQ2x coverage and the CRT25 scanline flag. Direct Video masked HDMI/CRT Vsize controls and suppressed rotation DDR writes.

`qualification.json` records actual extra master ticks and the64-field ceiling, compiler source hashes, ELF identity, actual exits and all limitations. Prior fourteen-check wrapper proofs and failed routing attempts remain untouched. Initial field0 retains57602 framework samples; native crops are57344, and later display mode checks use the existing four-field settling convention.

DIP/coin/player transfer is not a claim that game software used those settings. Actual lives, cocktail/P2 behavior, real earned-score save/reset/restore and physical outputs/audio/timing remain separate. The proposed200-field game-effect pilot was neither built nor run. This feature evidence must be bound to the final joined source graph before release.
''',encoding='utf-8',newline='\n')
files=['admission.json','owned_job_scan.json','actual_prebuild_source_pins.json','worker_job.json','build_job.json','build_exit.json','run_job.json','run_exit.json','elf.json','qualification.json','findings.md','qualify.py','build.sh','run_remaining.py','effective_sources_v2.sha256','scope_adapter_v2.json','capture/result.json','capture/remaining_video.json','capture/frames.csv','build.log','run.log']
put(OUT/'import_manifest.json',dict(schema='remaining_wrapper_transport_display_import_v1',entries=[dict(path=str(OUT/name),sha256=sha(OUT/name),bytes=(OUT/name).stat().st_size) for name in files],source_recovery_root=str(OUT/'source'),limits=q['limits']))
print(json.dumps(dict(passed=True,checks=len(checks),additional_master_ticks=display['additional_master_ticks'],additional_fields=display['additional_master_ticks']/811008,ELF_sha256=elf['sha256'],manifest_sha256=sha(OUT/'import_manifest.json'))))
