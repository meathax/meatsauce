"""Qualify existing real isolated terminals; no simulator/build invocation."""
from pathlib import Path
import hashlib,json
S=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def js(p):return json.loads(p.read_text())
def cases(d):return {x['period']:x for x in d['actual_case_results'] if 'period' in x}
def winpath(p):return Path(p.replace('/mnt/d/','D:/'))
B=js(S/'v2/run_exit.json');C=js(S/'candidate/run_exit.json');b=cases(B);c=cases(C)
BP=B['production_source_pins'];CP=C['actually_compiled_candidate_source_pins']
baseline_root=winpath(B['build_root']);candidate_root=winpath(C['build_root'])
original=(baseline_root/'jt49_div.v').read_text();fixed=(candidate_root/'jt49_div.v').read_text()
expected=original.replace('    if(period==0) div<=0;','    // Period zero toggles at the same cadence as period one.')
pin='rtl/vendor/jt12/jt49/hdl/jt49_div.v'
production=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
compiled=js(S.parents[1]/'research/kyros_merged_lifecycle_v2_compiled_exit.json')
checks={
 'initial_space_path_build_failure_preserved':js(S/'build_exit.json')['exit_code']==2 and not (S/'run_exit.json').exists(),
 'baseline_actual_build0_run1':js(S/'v2/build_exit.json')['exit_code']==0 and B['exit_code']==1,
 'candidate_actual_build0_run0':js(S/'candidate/build_exit.json')['exit_code']==0 and C['exit_code']==0,
 'all_three_cases_completed_in_each_run':set(b)==set(c)=={0,1,37},
 'baseline_period0_failure_real_silence':b[0]['nominal_frequency_pass'] is False and b[0]['channel_A_output']['rises']==0 and b[0]['tone_divider_bit_A']['rises']==0 and b[0]['minimum_channel_A']==b[0]['maximum_channel_A']==0,
 'baseline_nonzero_frequencies_exact':all(b[p]['nominal_frequency_pass'] is True for p in (1,37)),
 'candidate_all_nominal_frequencies_exact':all(c[p]['nominal_frequency_pass'] is True for p in (0,1,37)),
 'all_accepted_registers_exact':all(x['accepted_registers_exact'] is True for x in list(b.values())+list(c.values())),
 'actual_enable_periods24_and96':all(x['chip_enable']['minimum_gap']==x['chip_enable']['maximum_gap']==24 and x['SSG_enable']['minimum_gap']==x['SSG_enable']['maximum_gap']==96 for x in list(b.values())+list(c.values())),
 'candidate_period0_matches_period1_nominal_rate':c[0]['tone_divider_bit_A']['minimum_gap']==c[0]['tone_divider_bit_A']['maximum_gap']==c[0]['channel_A_output']['minimum_gap']==c[0]['channel_A_output']['maximum_gap']==768,
 'nonzero_rising_periods_unchanged':all(b[p][k]['minimum_gap']==b[p][k]['maximum_gap']==c[p][k]['minimum_gap']==c[p][k]['maximum_gap']==768*p for p in (1,37) for k in ('tone_divider_bit_A','channel_A_output')),
 'all_real_copied_baseline_source_pins':all(sha(baseline_root/Path(k).name)==h for k,h in BP.items()),
 'all_real_copied_candidate_source_pins':all(sha(candidate_root/Path(k).name)==h for k,h in CP.items()),
 'only_embedded_divider_pin_changes':set(BP)==set(CP) and [k for k in BP if BP[k]!=CP[k]]==[pin],
 'same_current_production49_source_graph':len(BP)==49 and all(compiled['production_source_pins'][k]==h and sha(production/k)==h for k,h in BP.items()),
 'same_read_only_adapter_and_host':B['probe_sha256']==C['probe_sha256'] and B['host_sha256']==C['host_sha256'],
 'normalized_source_delta_only_period0_override':fixed==expected,
 'GPL_donor_notice_preserved':original.splitlines()[:23]==fixed.splitlines()[:23],
 'actual_ELF_pins':sha(baseline_root/'obj/ym2203_ssg_pitch_sim')==B['actual_ELF_sha256'] and sha(candidate_root/'obj/ym2203_ssg_pitch_sim')==C['actual_ELF_sha256'],
 'actual_log_pins':sha(S/'v2/run.log')==B['run_log_sha256'] and sha(S/'candidate/run.log')==C['run_log_sha256'],
 'original_cpp_pins':sha(S/'pitch_main.cpp')==B['host_sha256'] and sha(S/'v2/pitch_main.cpp')==B['host_sha256'] and sha(S/'candidate/pitch_main.cpp')==C['host_sha256']
}
phase={p:{k:{'baseline_first_ticks':b[p][k]['first_rising_ticks'],'candidate_first_ticks':c[p][k]['first_rising_ticks'],'baseline_rises':b[p][k]['rises'],'candidate_rises':c[p][k]['rises']} for k in ('tone_divider_bit_A','channel_A_output')} for p in (1,37)}
receipt={'scope':'Actual isolated current production SSG pitch failure and private one-line candidate correction; no production/core/clock changes or CPU replay.',
 'checks':checks,'finite_isolated_measurement_and_private_candidate_pass':all(type(v) is bool and v for v in checks.values()),
 'baseline_actual_run_exit':B['exit_code'],'candidate_actual_run_exit':C['exit_code'],
 'source_contract_sha256':sha(S/'v2/source_contract.json'),'baseline_run_receipt_sha256':sha(S/'v2/run_exit.json'),'candidate_run_receipt_sha256':sha(S/'candidate/run_exit.json'),
 'nominal_formula':'48MHz / (24*4*4*2*max(P,1)) = 62500/max(P,1) Hz; gaps768,768,28416ticks for0,1,37.',
 'nonzero_absolute_phase_and_count_observations':phase,
 'limits':['Absolute nonzero first-edge phase differs because period0 now oscillates during normal register setup; this is retained, not called waveform identity.','Periods1 and37 cadence is exactly unchanged; no arbitrary tolerance or bit-identical PCM comparison.','Only channelA fixed-volume tone and default prescaler are measured; no complete SSG envelope/noise/route/action acceptance.','Private candidate is not applied to production; current4401 remains on the frozen original divider.','Broad P5, full audio and whole-game acceptance remain pending.'],
 'production_patch_applied':False,'full_P5_acceptance':False,'full_audio_acceptance':False,'whole_game_acceptance':False,
 'evidence':[{'relative_path':str(p.relative_to(S)).replace('\\','/'),'sha256':sha(p),'bytes':p.stat().st_size} for p in [S/'v2/run_exit.json',S/'candidate/run_exit.json',S/'v2/run.log',S/'candidate/run.log',S/'v2/source_contract.json',S/'candidate/source_contract.json',S/'candidate/jt49_div.v',S/'candidate/divider.patch',S/'candidate/candidate_provenance.json',Path(__file__)]]}
p=S/'qualification.json';p.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'checks':len(checks),'passed':sum(v is True for v in checks.values()),'failed':[k for k,v in checks.items() if v is not True],'receipt_sha256':sha(p)}))
raise SystemExit(0 if receipt['finite_isolated_measurement_and_private_candidate_pass'] else 1)
