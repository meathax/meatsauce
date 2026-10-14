"""Read-only retained CPU event reconstruction; never launches or controls a replay."""
import csv, hashlib, io, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
CANON = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(data): return hashlib.sha256(data).hexdigest()
def pin(p):
    data=p.read_bytes()
    return {'path':str(p),'sha256':sha(data),'bytes':len(data)}

def classification(reg,k):
    lo,hi,mix,vol=reg[2*k],reg[2*k+1],reg[7],reg[8+k]
    period=None if lo is None or hi is None else lo|((hi&15)<<8)
    tone=None if mix is None else not bool(mix&(1<<k))
    envelope=None if vol is None else bool(vol&16)
    eligible=None if vol is None else bool(vol&31)
    # A known exclusion settles the conjunction even when another register is unknown.
    qualifies=False if period not in (None,0) or tone is False or eligible is False else (
        None if period is None or tone is None or eligible is None else True)
    return {'period':period,'tone_enabled':tone,'volume_register':vol,
            'envelope_selected':envelope,'fixed_volume':None if vol is None or envelope else vol&15,
            'actual_envelope_amplitude':None,'active_zero_candidate':qualifies}

def reconstruct(label,folder,terminal,partial):
    source=ROOT/folder/'audio_events.csv'; data=source.read_bytes()
    usable=data[:data.rfind(b'\n')+1]
    rows=list(csv.DictReader(io.StringIO(usable.decode())))
    frame_data=(ROOT/folder/'frames.csv').read_bytes()
    frame_usable=frame_data[:frame_data.rfind(b'\n')+1]
    frames=list(csv.DictReader(io.StringIO(frame_usable.decode())))
    assert all(int(b['tick'])>=int(a['tick']) for a,b in zip(rows,rows[1:]))
    assert all(int(x['frame'])==i for i,x in enumerate(frames))
    # Unknown-seeded is the conservative result; reset-seeded is separately reported.
    reg=[None]*16; reset_reg=[0]*16; sel=None; updates=[]; opens={}; intervals=[]
    reset_candidates=0; unknown_candidates=0; ym_selects=0; ym_data=0; zero_enabled_muted=0
    for ordinal,x in enumerate(rows):
        if x['kind']!='write': continue
        address,value=int(x['address']),int(x['data'])
        if address==16:
            sel=value; ym_selects+=1; continue
        if address!=17: continue
        ym_data+=1
        if sel is None: raise AssertionError('YM data before observed selector')
        if sel>=16: continue
        reg[sel]=value; reset_reg[sel]=value
        states=[classification(reg,k) for k in range(3)]
        resets=[classification(reset_reg,k) for k in range(3)]
        reset_candidates+=sum(s['active_zero_candidate'] is True for s in resets)
        unknown_candidates+=sum(s['active_zero_candidate'] is None for s in states)
        zero_enabled_muted+=sum(s['period']==0 and s['tone_enabled'] is True and s['volume_register']==0 for s in states)
        item={'ordinal':ordinal,'tick':int(x['tick']),'frame':int(x['frame']),
              'register':sel,'value':value,'registers':reg.copy(),'channels':states}
        updates.append(item)
        for k,state in enumerate(states):
            if state['active_zero_candidate'] is True and k not in opens:
                opens[k]={'channel':'ABC'[k],'start':item,'envelope_amplitude_observed':False}
            if state['active_zero_candidate'] is not True and k in opens:
                interval=opens.pop(k);interval['end']=item
                interval['observed_IO_boundary_duration_masterticks']=item['tick']-interval['start']['tick']
                intervals.append(interval)
    for interval in opens.values(): interval['end']=None;intervals.append(interval)
    # Export complete explicit register reconstruction, rather than only candidate matches.
    timeline=OUT/(label+'_register_timeline.json')
    timeline.write_text(json.dumps(updates,separators=(',',':'))+'\n')
    snapshot=OUT/(label+'_audio_events.csv');snapshot.write_bytes(usable)
    frame_snapshot=OUT/(label+'_frames.csv');frame_snapshot.write_bytes(frame_usable)
    term_path=ROOT/terminal
    term=json.loads(term_path.read_text()) if term_path.exists() else None
    return {'label':label,'partial':partial,'source_event_pin':pin(source) if not partial else {
        'path':str(source),'observed_read_bytes':len(data),'observed_complete_prefix_bytes':len(usable),
        'observed_read_sha256':sha(data),'complete_prefix_sha256':sha(usable)},
        'immutable_event_prefix_pin':pin(snapshot),'immutable_frame_prefix_pin':pin(frame_snapshot),
        'timeline_pin':pin(timeline),'actual_terminal_pin':pin(term_path) if term else None,
        'actual_exit_code':term.get('exit_code') if term else None,
        'terminal_present':term is not None,'frame_rows':len(frames),'last_complete_frame':int(frames[-1]['frame']),
        'event_rows':len(rows),'last_event_frame':int(rows[-1]['frame']),
        'YM_address_writes':ym_selects,'YM_data_writes':ym_data,'SSG_register_updates':len(updates),
        'unknown_seeded_channel_updates_with_unresolved_candidate':unknown_candidates,
        'reset_seeded_active_zero_channel_updates':reset_candidates,
        'known_zero_tone_enabled_muted_channel_updates':zero_enabled_muted,
        'active_zero_intervals_observed_IO_coordinates':intervals,
        'final_explicit_register_state':reg,'final_channels':[classification(reg,k) for k in range(3)]}

old=reconstruct('portreplay1800','sim/captures/rtl/kyros_portreplay1800',
    'research/system_portreplay1800_exit.json',False)
current=reconstruct('merged4401_partial','sim/captures/rtl/kyros_merged_lifecycle_v2',
    'research/kyros_merged_lifecycle_v2_run_exit.json',True)
source_ranges={
    'rtl/alpha68kn_soundchips.sv':[(17,18),(38,42)],
    'rtl/vendor/jt12/hdl/jt12_top.v':[(87,87),(405,407),(461,469)],
    'rtl/vendor/jt12/hdl/jt12_mmr.v':[(187,188),(270,297),(420,423)],
    'rtl/vendor/jt12/jt49/hdl/jt49.v':[(168,174),(236,255)]}
sources=[]
for rel,ranges in source_ranges.items():
    p=CANON/rel;lines=p.read_text().splitlines()
    sources.append({**pin(p),'relative_path':rel,'excerpts':[
        {'first_line':a,'last_line':b,'text':'\n'.join(lines[a-1:b])} for a,b in ranges]})
checks={
    'complete1800_actual_terminal0':old['actual_exit_code']==0,
    'complete1800_contiguous_frame_rows':old['frame_rows']==1800,
    'complete1800_all_observed_YMdata_has_selector':old['YM_data_writes']>0,
    'complete1800_no_unknown_active_zero_classification':old['unknown_seeded_channel_updates_with_unresolved_candidate']==0,
    'complete1800_no_active_zero_in_either_reconstruction':not old['active_zero_intervals_observed_IO_coordinates'] and old['reset_seeded_active_zero_channel_updates']==0,
    'current_partial_no_unknown_active_zero_classification':current['unknown_seeded_channel_updates_with_unresolved_candidate']==0,
    'current_partial_no_active_zero_in_either_reconstruction':not current['active_zero_intervals_observed_IO_coordinates'] and current['reset_seeded_active_zero_channel_updates']==0}
receipt={'scope':'Retained actual Kyros CPU-issued YM IO sequences reconstructed through the source-defined embedded SSG register write interface; no new run.',
    'checks':checks,'all_checks_strict_boolean_true':all(type(v) is bool and v for v in checks.values()),
    'runs':[old,current],'interface_source_pins_and_excerpts':sources,
    'job_pins':[pin(ROOT/p) for p in ['research/system_portreplay1800_started.json','research/system_portreplay1800_exit.json','research/kyros_merged_lifecycle_v2_compiled_exit.json','research/kyros_merged_lifecycle_v2_run_job.json']],
    'limits':['No active period-zero tone with nonzero fixed volume/envelope selection occurs in either recorded prefix; this does not establish absence in other scenes or inputs.',
        'Unknown-seeded reconstruction does not assume unseen reset values. Reset-seeded result is separate and based on the source-defined reset state.',
        'The event timestamps label host-observed IO writes; exact downstream internal SSG latch ticks were not directly captured. No PCM phase identity or actual envelope amplitude is inferred.',
        'Historical1800 runtime ELF/input/terminal are pinned by retained receipts; current canonical interface excerpts describe the reconstruction semantics, not a new claim that every historical compiled source was independently re-pinned.',
        'Current4401 evidence is only an immutable snapshot of an ongoing run, not a terminal or whole-game acceptance.',
        'The isolated period-zero bug/fix remains valid even when this finite software trace does not exercise an audible zero-period tone.'],
    'PCM_phase_identity_proved':False,'full_audio_acceptance':False,'whole_game_acceptance':False}
p=OUT/'qualification.json';p.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'checks':checks,'qualification_sha256':sha(p.read_bytes()),'runs':[
    {k:x[k] for k in ['label','frame_rows','last_complete_frame','event_rows','YM_address_writes','YM_data_writes','SSG_register_updates','unknown_seeded_channel_updates_with_unresolved_candidate','reset_seeded_active_zero_channel_updates','known_zero_tone_enabled_muted_channel_updates','terminal_present']} for x in [old,current]]}))
raise SystemExit(0 if receipt['all_checks_strict_boolean_true'] else 1)
