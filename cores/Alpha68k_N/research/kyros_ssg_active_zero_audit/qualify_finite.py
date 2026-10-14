"""Qualify the known-state window; preserve the original startup-uncertainty failure."""
from pathlib import Path
import hashlib,json
S=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
d=json.loads((S/'qualification.json').read_text())
e=json.loads((S/'check_exit.json').read_text())
windows=[]
for run in d['runs']:
    t=json.loads((S/(run['label']+'_register_timeline.json')).read_text())
    unknown=[{'update_index':i,'tick':u['tick'],'frame':u['frame'],'register':u['register'],
        'value':u['value'],'channels':['ABC'[k] for k,v in enumerate(u['channels']) if v['active_zero_candidate'] is None]}
        for i,u in enumerate(t) if any(v['active_zero_candidate'] is None for v in u['channels'])]
    first=1+max((x['update_index'] for x in unknown),default=-1)
    known=t[first:]
    eligible=[(u,v) for u in known for v in u['channels'] if v['tone_enabled'] is True and v['volume_register'] is not None and v['volume_register']&31]
    windows.append({'label':run['label'],'excluded_unknown_startup_updates':unknown,
        'first_continuously_classifiable_update':{k:t[first][k] for k in ['ordinal','tick','frame','register','value','registers']},
        'known_state_updates':len(known),'active_zero_updates':sum(v['active_zero_candidate'] is True for u in known for v in u['channels']),
        'unresolved_known_window_updates':sum(v['active_zero_candidate'] is None for u in known for v in u['channels']),
        'tone_enabled_nonzero_volume_or_envelope_channel_updates':len(eligible),
        'envelope_selected_eligible_channel_updates':sum(v['envelope_selected'] is True for u,v in eligible),
        'eligible_nonzero_periods':sorted(set(v['period'] for u,v in eligible if v['period'] is not None)),
        'envelope_amplitude_observed':False,'original_terminal_present':run['terminal_present'],
        'frame_rows':run['frame_rows'],'last_complete_frame':run['last_complete_frame']})
checks={'original_actual_exit1_and_startup_failures_preserved':e['actual_exit_code']==1 and
    d['checks']['complete1800_no_unknown_active_zero_classification'] is False and
    d['checks']['current_partial_no_unknown_active_zero_classification'] is False,
    'complete1800_actual_terminal0':d['checks']['complete1800_actual_terminal0'] is True,
    'complete1800_all1800_frame_rows':d['checks']['complete1800_contiguous_frame_rows'] is True,
    'both_known_windows_nonvacuous_real_tone_commands':all(w['tone_enabled_nonzero_volume_or_envelope_channel_updates']>0 for w in windows),
    'both_known_windows_have_no_active_zero_and_no_unknown_candidates':all(w['active_zero_updates']==0 and w['unresolved_known_window_updates']==0 for w in windows),
    'all_immutable_event_and_timeline_pins_match':all(sha(Path(run[k]['path']))==run[k]['sha256'] for run in d['runs'] for k in ['immutable_event_prefix_pin','immutable_frame_prefix_pin','timeline_pin'])}
r={'scope':'Conservative finite software-impact result after observed startup volume initialization. No active period-zero tone candidate in the explicitly known register windows.',
    'checks':checks,'finite_known_state_impact_qualification_pass':all(type(v) is bool and v for v in checks.values()),
    'windows':windows,'original_failure_receipt_sha256':sha(S/'check_exit.json'),
    'original_audit_receipt_sha256':sha(S/'qualification.json'),'script_sha256':sha(Path(__file__)),
    'limits':d['limits']+['Before the first continuously classifiable update, 3 unknown channel classifications are preserved in each trace; absence is not asserted over that startup gap.',
        'Envelope selection means a potential amplitude source, not measured nonzero envelope output. Actual amplitude and noise gating remain unobserved.'],
    'whole_run_active_zero_absence_proved_without_reset_assumption':False,
    'software_impact_in_other_scenes_excluded':False,'PCM_phase_identity_proved':False,'full_audio_acceptance':False}
p=S/'finite_qualification.json';p.write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({'checks':checks,'windows':windows,'receipt_sha256':sha(p)}))
raise SystemExit(0 if r['finite_known_state_impact_qualification_pass'] else 1)
