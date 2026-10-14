"""Snapshot finite live prefixes and compare actual software-produced audio events.

No simulator invocation and no whole-run or action-semantic acceptance claim.
"""
from pathlib import Path
import csv, hashlib, io, json, wave

R = Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
C = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
O = Path(__file__).resolve().parent
pins = []
def sha(data): return hashlib.sha256(data).hexdigest()
def rows(path, limit=None, select=lambda x:True):
    # Bound the open file to its initial byte length, including only complete lines.
    # Stream large MAME bus logs and retain selected audio rows only.
    size=path.stat().st_size; count=0; raw_hash=hashlib.sha256()
    def lines(f):
        nonlocal count
        while count<size:
            line=f.readline(size-count)
            if not line or not line.endswith(b'\n'):break
            count+=len(line);raw_hash.update(line)
            yield line.decode('utf-8-sig')
    parsed=[]
    with path.open('rb') as f:
        for x in csv.DictReader(lines(f)):
            if limit is not None and int(x['frame'])>=limit:break
            if select(x):parsed.append(x)
    buf = io.StringIO(newline='')
    if parsed:
        w = csv.DictWriter(buf, fieldnames=list(parsed[0]), lineterminator='\n')
        w.writeheader(); w.writerows(parsed)
    normalized = buf.getvalue().encode()
    pins.append({'path': str(path), 'read_bytes':count,'read_raw_prefix_sha256':raw_hash.hexdigest(), 'finite_rows':len(parsed),
                 'normalized_selected_rows_sha256':sha(normalized), 'frame_limit':limit})
    return parsed
def compare(a,b):
    def key(x):return tuple(int(x[n]) for n in ('address','data'))
    first=next((i for i,(x,y) in enumerate(zip(a,b)) if key(x)!=key(y)),None)
    if first is None and len(a)!=len(b):first=min(len(a),len(b))
    return {'reference_count':len(a),'native_count':len(b),'nonvacuous':bool(a and b),
            'ordered_address_data_equal':first is None,
            'field_label_differences':sum(int(x['frame'])!=int(y['frame']) for x,y in zip(a,b)),
            'first_difference_index':first,
            'reference_first':a[first] if first is not None and first<len(a) else None,
            'native_first':b[first] if first is not None and first<len(b) else None,
            'reference_sequence_sha256':sha(json.dumps(list(map(key,a))).encode()),
            'native_sequence_sha256':sha(json.dumps(list(map(key,b))).encode())}
def report_pair(name, native_dir, ref_dir, fields):
    n=rows(native_dir/'audio_events.csv',fields)
    a=rows(ref_dir/'events.csv',fields,lambda x:x['area'] in ('sound_io','sound_latch_write') or (x['area']=='sound_memory' and int(x['address'])==0xe004))
    groups={}
    for chip, ports in [('YM',[16,17]),('AY1',[128,129]),('AY2',[144,145])]:
        aa=[x for x in a if x['area']=='sound_io' and int(x['address']) in ports]
        nn=[x for x in n if x['kind']=='write' and int(x['address']) in ports]
        groups[chip]=compare(aa,nn)
    aa=[x for x in a if x['area']=='sound_memory' and int(x['address'])==0xe004]
    nn=[x for x in n if x['kind']=='dac' and int(x['address'])==0xe004]
    groups['DAC']=compare(aa,nn)
    epoch=rows(native_dir/'epoch_events.csv',fields,lambda x:not int(x['iack']) and not int(x['rw']) and int(x['address'])==0xe0000)
    aa=[dict(x,data=str(int(x['data'])&int(x['mask']))) for x in a if x['area']=='sound_latch_write']
    nn=[]
    for x in epoch:
        if int(x['iack']) or int(x['rw']) or int(x['address'])!=0xe0000:continue
        mask=(0 if int(x['uds_n']) else 0xff00)|(0 if int(x['lds_n']) else 0xff)
        nn.append(dict(x,address=x['address'],data=str(int(x['data_out'])&mask)))
    groups['latch']=compare(aa,nn)
    # Native register buses are preserved separately; inter-chip scheduling remains visible.
    groups['global_ports']=compare([x for x in a if x['area']=='sound_io'],[x for x in n if x['kind']=='write'])
    return {'name':name,'fields':fields,'comparisons':groups,'native_event_kinds':sorted(set(x['kind'] for x in n)),
            'native_directory':str(native_dir),'reference_directory':str(ref_dir)}

live=R/'sim/captures/rtl/kyros_merged_lifecycle_v2'
frames=rows(live/'frames.csv')
# Bound to fields already fully recorded; do not infer completion from a live PID.
fields=max(int(x['frame']) for x in frames)+1
receipt_path=R/'research/kyros_merged_lifecycle_v2_compiled_exit.json'
receipt=json.loads(receipt_path.read_text())
elf=live/'alpha68kn_merged_lifecycle_v2_sim'
bindings={n:sha((C/n).read_bytes())==h for n,h in receipt['production_source_pins'].items()}
result={'scope':'Finite actual CPU-produced event comparison; live prefix only, no terminal receipt or semantic hit/jump/pickup claim.',
        'live_complete_fields':fields,'build_actual_exit':receipt.get('exit_code'),
        'build_receipt_sha256':sha(receipt_path.read_bytes()),'actual_elf_sha256':sha(elf.read_bytes()),
        'build_elf_pin_equal':sha(elf.read_bytes())==receipt.get('actual_ELF_sha256'),
        'current_source_bindings':bindings,'pairs':[]}
result['pairs'].append(report_pair('merged_lifecycle_finite_prefix',live,R/'sim/captures/kyros/idle_death_restart_actions4401',fields))
result['pairs'].append(report_pair('combat3301_retained_DAC',R/'sim/captures/rtl/kyros_combat_hud3301',R/'sim/captures/kyros/combat3600_clocked',3301))
# Retain applied control evidence separately from successful action semantics.
applied=rows(live/'applied_inputs.csv',fields)
ref_inputs=rows(R/'sim/captures/kyros/idle_death_restart_actions4401/frame_states.csv',fields)
idx={int(x['frame']):x for x in ref_inputs}
port_map={'controls':'in0','dips':'in1','coins_n':'in2'}
if not all(k in applied[0] for k in port_map):raise ValueError('Unsupported actual applied-input schema')
diff=[int(x['frame']) for x in applied if int(x['frame']) in idx and any(int(x[k])!=int(idx[int(x['frame'])][v]) for k,v in port_map.items())]
result['same_field_input_differences']={'count':len(diff),'first_fields':diff[:12],
    'native_to_reference_port_map':port_map,
    'limit':'Same-field diagnostic only; recorder uses apply-after-snapshot epoch, not proof of invalid inputs.'}
result['pins']=pins
wav_source=R/'sim/captures/rtl/kyros_combat_hud3301/audio.wav'
wav_out=O/'combat3301_observed_punch_noise_12to14s.wav'
with wave.open(str(wav_source),'rb') as wav:
    params=wav.getparams();start=12*wav.getframerate();count=2*wav.getframerate()
    wav.setpos(start);data=wav.readframes(count)
with wave.open(str(wav_out),'wb') as wav:
    wav.setparams(params);wav.writeframes(data)
audio_json=R/'sim/captures/rtl/kyros_combat_hud3301/audio.json'
result['short_existing_native_WAV']={'source':str(wav_source),'source_sha256':sha(wav_source.read_bytes()),
    'output':str(wav_out),'output_sha256':sha(wav_out.read_bytes()),'first_sample':start,'samples':count,
    'sample_rate':params.framerate,'channels':params.nchannels,'sample_width':params.sampwidth,
    'scope':'Unmodified actual CPU mixed PCM at 12..14 seconds, retained punch/noise interval; no listening, successful hit semantics or PCM identity claim.',
    'actual_audio_metrics':json.loads(audio_json.read_text()),'actual_audio_metrics_sha256':sha(audio_json.read_bytes())}
result['required_remaining']=['Source-qualified successful hit/jump/pickup semantic windows; legal button pulses do not prove the effects.',
    'Merged lifecycle actual terminal receipt and full audio sample/clipping/reset qualification.',
    'Japan current-source replay/oracle epoch qualification; complete sound integration map/fit/STA.',
    'B03-B06/B13 full phase gate remains open; physical listening reserved for P9.']
result['full_P5_pass']=False
result['audit_script_sha256']=sha(Path(__file__).read_bytes())
out=O/'retained_cpu_audio_result.json';out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'result_sha256':sha(out.read_bytes()),'live_fields':fields,'build_elf_pin_equal':result['build_elf_pin_equal'],
    'source_bindings':len(bindings),'current_source_pin_failures':[k for k,v in bindings.items() if not v],
    'comparisons':{p['name']:{k:{q:v[q] for q in ('reference_count','native_count','ordered_address_data_equal','field_label_differences','first_difference_index')} for k,v in p['comparisons'].items()} for p in result['pairs']}}))
