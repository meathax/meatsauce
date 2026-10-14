from pathlib import Path
import hashlib,json,wave
O=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((O/'retained_cpu_audio_result.json').read_text());e=json.loads((O/'audit_exit.json').read_text())
m,c=r['pairs'];p=m['comparisons'];q=c['comparisons'];w=r['short_existing_native_WAV']
with wave.open(w['source'],'rb') as a,wave.open(w['output'],'rb') as b:
    a.setpos(w['first_sample']);pcm_equal=a.readframes(w['samples'])==b.readframes(w['samples'])
checks={'actual_audit_terminal0':e['exit_code']==0,'actual_ELF_pin_exact':r['build_elf_pin_equal'] is True,
    'finite_scope_2588_complete_fields':r['live_complete_fields']==2588,
    'all_finite_merged_ordered_sound_groups_nonvacuous_equal':all(x['ordered_address_data_equal'] is True and x['nonvacuous'] is True for x in p.values()),
    'finite_merged_all_group_field_labels_exact':all(x['field_label_differences']==0 for x in p.values()),
    'finite_merged10608ports32091DAC21latches':p['global_ports']['native_count']==10608 and p['DAC']['native_count']==32091 and p['latch']['native_count']==21,
    'retained_combat32091DAC134latches_nonvacuous_equal':q['DAC']['native_count']==32091 and q['DAC']['ordered_address_data_equal'] is True and q['latch']['native_count']==134 and q['latch']['ordered_address_data_equal'] is True,
    'retained_combat_YM7field_global_failure_preserved':q['YM']['field_label_differences']==7 and q['global_ports']['ordered_address_data_equal'] is False and q['global_ports']['first_difference_index']==896,
    'current_board_source_delta_preserved':r['current_source_bindings']['rtl/alpha68kn_board.sv'] is False and sum(r['current_source_bindings'].values())==68,
    'finite_same_field_input_values_exact':r['same_field_input_differences']['count']==0,
    'existing_short_WAV_exact_sample_bytes':pcm_equal and sha(Path(w['output']))==w['output_sha256'],
    'fullP5_false':r['full_P5_pass'] is False,
    'diagnostic_failure_and_previous_output_retained':(O/'failed_input_schema_v1/audit_exit.json').exists() and (O/'prior_unmasked_latch_and_wrong_elf_key_v2/retained_cpu_audio_result.json').exists()}
v={'scope':'Verification of finite retained real CPU sound events and exact existing PCM extraction; no current-image or full-P5 pass.',
   'checks':checks,'all_checks_strict_boolean_true':all(x is True for x in checks.values()),
   'result_sha256':sha(O/'retained_cpu_audio_result.json'),'native_ELF_sha256':r['actual_elf_sha256']}
(O/'verification.json').write_text(json.dumps(v,indent=2)+'\n')
files=[{'relative_path':str(f.relative_to(O)).replace('\\','/'),'bytes':f.stat().st_size,'sha256':sha(f)} for f in sorted(O.rglob('*')) if f.is_file() and f.name!='import_manifest.json']
(O/'import_manifest.json').write_text(json.dumps({'scope':v['scope'],'files':files,'all_finite_checks_pass':v['all_checks_strict_boolean_true'],'full_P5_pass':False},indent=2)+'\n')
print(json.dumps({'checks':checks,'all_pass':v['all_checks_strict_boolean_true'],'files':len(files),'verification_sha256':sha(O/'verification.json'),'manifest_sha256':sha(O/'import_manifest.json')}))
raise SystemExit(0 if v['all_checks_strict_boolean_true'] else 1)
