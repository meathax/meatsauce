"""One strict terminal qualifier; observer interpretation follows invariant checks."""
from pathlib import Path
from collections import deque
import csv,hashlib,json,subprocess,sys,time,wave
from PIL import Image
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'paired601'
N=HERE/'native_capture';M=HERE/'mame_capture'
OLD=ROOT/'research/remaining_gates_20261011/japan_joined720/capture'
REF=ROOT/'sim/captures/kyrosj/gameplay'
FIELDS=[0,30,90,240,360,600]
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
def rows(p):
    with p.open(newline='',encoding='utf-8-sig') as f:return list(csv.DictReader(f))
def write(name,obj):(HERE/name).write_text(json.dumps(obj,indent=2)+'\n')
def dif(a,b):return sum(x!=y for x,y in zip(a,b))+abs(len(a)-len(b))
def main():
    assert (HERE/'paired_terminal.json').exists(),'Native/MAME terminal missing; no early interpretation'
    assert not (HERE/'verification.json').exists(),'Refuse a repeated terminal qualifier'
    terminal=json.loads((HERE/'paired_terminal.json').read_text())
    checks={'native_actual_exit0':terminal['native_exit']==0,'MAME_actual_exit0':terminal['MAME_exit']==0}
    frames=rows(N/'frames.csv');mframes=rows(M/'frame_states.csv')
    checks['native_actual601_contiguous']=len(frames)==601 and [int(x['frame']) for x in frames]==list(range(601))
    checks['MAME_actual601_complete']=len(mframes)==601 and [int(x['frame']) for x in mframes]==list(range(601)) and (M/'complete.txt').read_text().startswith('frames=601\n')
    checks['native_protocol_pixels_deadlines_unmapped']=all(int(x['pixels'])==57344 and all(int(x[k])==0 for k in ['duplicates','deadline_misses','row_overflows','unmapped']) for x in frames)
    checks['MAME_original_all601_state_ports_exact']=mframes==rows(REF/'frame_states.csv')[:601]
    inputs=rows(N/'applied_inputs.csv');oldinputs=[x for x in rows(OLD/'applied_inputs.csv') if int(x['frame'])<601]
    checks['native_original_all601_inputs_exact']=inputs==oldinputs
    arrays=[]
    for f in FIELDS:
        image=Image.open(M/f'frame_{f:06d}.png')
        display=image.transpose(Image.Transpose.ROTATE_90).convert('RGB').tobytes()
        (M/f'frame_{f:06d}.display.rgb').write_bytes(display)
        for ext in ['rgb','work.bin','sprites.bin']:
            native=N/f'frame_{f:06d}.{ext}';old=OLD/native.name
            ref=REF/(f'frame_{f:06d}.display.rgb' if ext=='rgb' else native.name)
            paired=M/(f'frame_{f:06d}.display.rgb' if ext=='rgb' else native.name)
            arrays.append(dict(field=f,suffix=ext,native=pin(native),old_native=pin(old),old_MAME=pin(ref),paired_MAME=pin(paired),
                native_original_different_bytes=dif(native.read_bytes(),old.read_bytes()),
                MAME_original_different_bytes=dif(paired.read_bytes(),ref.read_bytes()),
                paired_different_bytes=dif(native.read_bytes(),paired.read_bytes())))
    checks['native_original_all18_arrays_invariant']=all(x['native_original_different_bytes']==0 for x in arrays)
    checks['MAME_original_all18_arrays_invariant']=all(x['MAME_original_different_bytes']==0 for x in arrays)
    nativeaudio=rows(N/'audio_events.csv')
    oldaudio=[x for x in rows(OLD/'audio_events.csv') if int(x['frame'])<601]
    checks['native_original_all601_chip_DAC_audio_events_exact']=nativeaudio==oldaudio
    nPCM=(N/'audio.pcm').read_bytes();oPCM=(OLD/'audio.pcm').read_bytes()
    checks['native_original_all601_PCM_exact_prefix']=bool(nPCM) and nPCM==oPCM[:len(nPCM)]
    with wave.open(str(M/'audio.wav'),'rb') as new,wave.open(str(REF/'audio.wav'),'rb') as old:
        wavparams=dict(channels=new.getnchannels(),width=new.getsampwidth(),rate=new.getframerate())
        oldparams=dict(channels=old.getnchannels(),width=old.getsampwidth(),rate=old.getframerate())
        newcount=new.getnframes();pcmnew=new.readframes(newcount);pcmold=old.readframes(newcount)
    checks['MAME_original_actual601_WAV_exact_prefix']=newcount>0 and wavparams==oldparams and pcmnew==pcmold
    for suffix,label in [('rgb','RGB'),('sprites.bin','strip'),('work.bin','work')]:
        checks['paired_all6_'+label+'_exact']=all(x['paired_different_bytes']==0 for x in arrays if x['suffix']==suffix)
    invariant_keys=[k for k in checks if not k.startswith('paired_all6_')]
    invariant_ok=all(checks[k] for k in invariant_keys)
    interpretation=[]
    if invariant_ok:
        ns={int(x['frame']):{k:int(v) for k,v in x.items()} for x in rows(N/'architectural_snapshots.csv')}
        ms={int(x['frame']):{k:int(v) for k,v in x.items()} for x in rows(M/'architectural_snapshots.csv')}
        targets=[]
        for x in arrays:
            if x['suffix']=='work.bin' and x['paired_different_bytes']:
                a=Path(x['native']['path']).read_bytes();b=Path(x['paired_MAME']['path']).read_bytes()
                targets += [(x['field'],0x020000+(i&~1)) for i in range(len(a)) if a[i]!=b[i]]
        targets=sorted(set(targets))
        histories={domain:{key:dict(last_write=None,last_write_hi=None,last_write_lo=None,
            reads_since_write=0,reads_since_hi_write=0,reads_since_lo_write=0,recent=deque(maxlen=4))
            for key in targets} for domain in ['native','MAME']}
        for domain,path in [('native',N/'upper_ram_arch.csv'),('MAME',M/'upper_ram_arch.csv')]:
            with path.open(newline='') as fh:
                for ordinal,row in enumerate(csv.DictReader(fh),1):
                    frame=int(row['frame']);addr=int(row['address'])&~1
                    for target,word in targets:
                        if frame>target or addr!=word:continue
                        state=histories[domain][target,word]
                        if domain=='native':
                            # True pre-edge lane strobes and observed RAM before/post prove commits.
                            writing=int(row['write_hi']) or int(row['write_lo'])
                            reading=int(row['rw'])==1 and int(row['iack'])==0
                            hi=bool(int(row['write_hi'])) if writing else int(row['uds_n'])==0
                            lo=bool(int(row['write_lo'])) if writing else int(row['lds_n'])==0
                        else:
                            writing=row['kind']=='write';reading=row['kind']=='read'
                            hi=bool(int(row['mask'])&0xff00);lo=bool(int(row['mask'])&0xff)
                        if writing:
                            state['last_write']=dict(row_ordinal=ordinal,**row);state['reads_since_write']=0
                            if hi:state['last_write_hi']=dict(row_ordinal=ordinal,**row);state['reads_since_hi_write']=0
                            if lo:state['last_write_lo']=dict(row_ordinal=ordinal,**row);state['reads_since_lo_write']=0
                        elif reading:
                            state['reads_since_write']+=1
                            if hi:state['reads_since_hi_write']+=1
                            if lo:state['reads_since_lo_write']+=1
                        state['recent'].append(dict(row_ordinal=ordinal,**row))
        for field,addr in targets:
            nstate=ns[field];mstate=ms[field]
            a=(N/f'frame_{field:06d}.work.bin').read_bytes();b=(M/f'frame_{field:06d}.work.bin').read_bytes();off=addr-0x020000
            item=dict(field=field,address_hex=f'0x{addr:06x}',native_word_hex=a[off:off+2].hex(),MAME_word_hex=b[off:off+2].hex(),
                native_snapshot_arch=nstate,MAME_snapshot_arch=mstate,
                native_word_below_current_A7=addr<nstate['a7'],MAME_word_below_current_A7=addr<mstate['a7'],
                architectural_A7_selection_exact=nstate['a7']==(nstate['ssp'] if nstate['sr']&0x2000 else nstate['usp']) and mstate['a7']==(mstate['ssp'] if mstate['sr']&0x2000 else mstate['usp']),
                classification='Raw writer/A7 evidence only: no automatic stale-stack classification or acceptance change.')
            for domain in ['native','MAME']:
                h=histories[domain][field,addr]
                item[domain+'_retained_accesses']=dict(last_write=h['last_write'],last_write_hi=h['last_write_hi'],last_write_lo=h['last_write_lo'],
                    reads_since_write=h['reads_since_write'],reads_since_hi_write=h['reads_since_hi_write'],
                    reads_since_lo_write=h['reads_since_lo_write'],recent=list(h['recent']))
            interpretation.append(item)
    result=dict(checks=checks,invariant_precondition_pass=invariant_ok,actual_native_exit=terminal['native_exit'],actual_MAME_exit=terminal['MAME_exit'],
        actual_native_fields=len(frames),actual_MAME_fields=len(mframes),arrays=arrays,MAME_WAV_parameters=wavparams,MAME_WAV_samples=newcount,
        native_PCM_bytes=len(nPCM),strict_work_gate=checks['paired_all6_work_exact'],RAM_writer_arch_evidence=interpretation,
        limitations=['PC prefetch observations are not alone the executing instruction; use IR/IRD/FC and MAME CURPC source mapping.',
                     'Present A7 or zero later reads does not alone prove popped/stale content. Strict work failures retained.',
                     'MAME observed read counts may include original observer snapshot accesses; no causal guest-reader assertion follows from raw counts alone.'])
    write('verification.json',result)
    print(json.dumps(dict(checks_true=sum(checks.values()),checks_total=len(checks),failed=[k for k,v in checks.items() if not v],
        invariant_ok=invariant_ok,native_fields=len(frames),MAME_fields=len(mframes),RAM_words=len(interpretation),verification=pin(HERE/'verification.json')),indent=2))
    return 0 if all(checks.values()) else 1
if __name__=='__main__':sys.exit(main())
