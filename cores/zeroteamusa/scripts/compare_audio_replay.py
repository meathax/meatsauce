"""Compare observed-command sound replay content; keep timing/fidelity scope explicit."""
from pathlib import Path
import argparse,array,csv,json,math,sys,wave

def pcm_info(data,channels,rate):
    values=array.array('h');values.frombytes(data)
    if sys.byteorder!='little':values.byteswap()
    left=values[::channels]
    first=next((i for i,v in enumerate(left) if v),None)
    return {'sample_rate':rate,'channels':channels,'frames':len(left),
            'first_nonzero_sample':first,'first_nonzero_seconds':first/rate if first is not None else None,
            'nonzero_samples':sum(v!=0 for v in left),'minimum':min(left,default=0),'maximum':max(left,default=0),
            'rms':math.sqrt(sum(int(v)*v for v in left)/len(left)) if left else 0,
            'clip_samples':sum(v in (-32768,32767) for v in left)}

def commands(path,limit):
    fm_register=0;music=[];oki=[];key_on=0;rows=0;last_cycle=0
    with path.open(newline='') as f:
        for row in csv.DictReader(f):
            cycle=int(row['cycle'])
            if cycle>=limit:break
            last_cycle=cycle
            address,data=int(row['address']),int(row['data']);rows+=1
            if address==0x4008:fm_register=data
            elif address==0x4009 and fm_register>=0x20:
                music.append((fm_register,data))
                key_on+=0xb0<=fm_register<=0xb8 and bool(data&32)
            elif address==0x6000:oki.append(data)
    return {'fm_music':music,'oki':oki,'key_ons':key_on,'trace_rows':rows,'last_cycle':last_cycle}

def sequence_difference(actual,expected):
    first=next((i for i,(a,e) in enumerate(zip(actual,expected)) if a!=e),None)
    return {'actual_count':len(actual),'reference_count':len(expected),
            'different_common_entries':sum(a!=e for a,e in zip(actual,expected)),
            'length_difference':len(actual)-len(expected),'first_difference_index':first,
            'exact':actual==expected}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('reference');p.add_argument('replay');a=p.parse_args()
    reference,replay=Path(a.reference),Path(a.replay)
    with wave.open(str(reference/'reference.wav'),'rb') as f:
        assert f.getsampwidth()==2,'Expected 16-bit reference WAV'
        ref=pcm_info(f.readframes(f.getnframes()),f.getnchannels(),f.getframerate())
    result=json.loads((replay/'result.json').read_text())
    rtl=pcm_info((replay/'audio.pcm').read_bytes(),1,49716)
    assert rtl['frames']==result['samples'],'PCM/result length mismatch'
    common_limit=min(result['cycles'],round(ref['frames']/ref['sample_rate']*96000000))
    rcmd=commands(reference/'timed-sound-events.csv',common_limit)
    acmd=commands(replay/'sound-events.csv',common_limit)
    out={'scope':'Observed-command component content comparison; not live gameplay or original-PCB audio timing/fidelity acceptance',
         'reference_pcm':ref,'rtl_pcm':rtl,'common_cycle_limit':common_limit,
         'fm_music_commands':sequence_difference(acmd['fm_music'],rcmd['fm_music']),
         'oki_commands':sequence_difference(acmd['oki'],rcmd['oki']),
         'reference_key_ons':rcmd['key_ons'],'rtl_key_ons':acmd['key_ons'],
         'reference_trace_rows':rcmd['trace_rows'],'rtl_trace_rows':acmd['trace_rows'],
         'reference_trace_last_cycle':rcmd['last_cycle'],'rtl_trace_last_cycle':acmd['last_cycle'],
         'reference_covers_common_interval':rcmd['last_cycle']>=common_limit-2*1732608,
         'reset_and_mono_checks':result['reset_enabled_clocks']>=6 and result['mono_differences']==0,
         'all_stimulus_consumed':result['events_consumed']==result['events'],
         'notes':['Timer/control register writes below 0x20 are excluded from musical-content comparison',
                  'Waveforms are measured, not required to be bit-identical across different synthesis implementations',
                  'Reference trace must cover the common interval; inspect its end before accepting a result']}
    (replay/'comparison.json').write_text(json.dumps(out,indent=2)+'\n')
    with wave.open(str(replay/'audio.wav'),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(49716);f.writeframes((replay/'audio.pcm').read_bytes())
    print(json.dumps({k:out[k] for k in ['fm_music_commands','oki_commands','reference_key_ons','rtl_key_ons','reset_and_mono_checks','all_stimulus_consumed']}))
    print(json.dumps({'reference_pcm':ref,'rtl_pcm':rtl}))
    return 0 if out['fm_music_commands']['exact'] and out['oki_commands']['exact'] and out['reset_and_mono_checks'] and out['all_stimulus_consumed'] and out['reference_covers_common_interval'] else 1

if __name__=='__main__':raise SystemExit(main())
