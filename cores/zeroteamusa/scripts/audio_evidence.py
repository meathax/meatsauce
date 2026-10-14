"""Record bounded cold-boot sound evidence; never embed game ROM contents."""
from pathlib import Path
import json,hashlib,csv,array,math,wave
root=Path(__file__).resolve().parents[1]
result=json.loads((root/'sim/results/audio-isolated.json').read_text())
assert result['cycles']==96000000
assert abs(result['z80_enables']-96000000*105/2816)<2
assert 49700<=result['samples']<=49730
assert result['fetches']>100000 and result['fm_data_writes']>100
assert result['interrupt_acknowledgements']>100 and result['coin_reads']>100
files=(root/'sim/audio_sources.f').read_text().splitlines()
files += ['sim/audio_main.cpp','sim/run_audio.sh','scripts/stage_zero_audio.py']
files += [p.relative_to(root).as_posix() for p in (root/'rtl/sound/jt6295').glob('*.hex')]
digest=lambda p:hashlib.sha256((root/p).read_bytes()).hexdigest()
samples=array.array('h',(root/'sim/results/audio-isolated.pcm').read_bytes())
assert len(samples)==result['samples']
pcm={'minimum':min(samples),'maximum':max(samples),'unique_values':len(set(samples)),
     'rms':math.sqrt(sum(s*s for s in samples)/len(samples))}
returns=[]
with (root/'sim/results/audio-reg-trace.csv').open() as f:
    for row in csv.DictReader(f):
        if int(row['address']) in (0x4018,0x4019) and int(row['data']):
            if len(returns)<16: returns.append({k:int(v) for k,v in row.items()})
tv80={}
for p in (root/'rtl/tv80').glob('*.v'):
    original=root/'donors/irem-m72/rtl/tv80'/p.name
    assert p.read_bytes()==original.read_bytes(),p.name
    tv80[p.name]=digest(p.relative_to(root))
donors=json.loads((root/'donors/manifest.json').read_text())
if isinstance(donors,dict): donors=donors.get('donors',donors.get('repositories',[]))
selected=[x for x in donors if x.get('name') in ('raiden','irem-m72')]
meta={'scope':'Real TV80/YM3812/single OKI cold boot for one simulated second; standalone Seibu sound bus',
      'clocks':{'system_hz':96000000,'z80_fm_ratio':'105/2816','oki_ratio':'15/1408','oki_pin7':'HIGH'},
      'result':result,'pcm':pcm,'bounded_nonzero_sub2main_writes':returns,
      'sources':{p:digest(p) for p in files},'unmodified_tv80':tv80,'donors':selected,
      'rom_regions':{p:digest('roms/regions/'+p+'.bin') for p in ('audiocpu','oki')},
      'limits':['No main CPU command was injected in this isolated test.',
                'Coin1 was pulsed naturally on the active-low input at 0.25 seconds for 0.05 seconds; idle port is FF.',
                'Nonzero audio is electrical activity, not proof of correct music/sample content.',
                'Music, speech, four-player coin/start behavior and full gameplay await integrated validation.',
                'No finished sound savestates or hardware/RBF validation is claimed.']}
(root/'docs/evidence/audio-coldboot.json').write_text(json.dumps(meta,indent=2)+'\n')
with wave.open(str(root/'sim/results/audio-isolated.wav'),'wb') as w:
    w.setnchannels(1);w.setsampwidth(2);w.setframerate(49716);w.writeframes(samples.tobytes())
print(json.dumps({'samples':result['samples'],'fm_irq_acks':result['interrupt_acknowledgements'],
                  'coin_reads':result['coin_reads'],'pcm':pcm,'sub2main_nonzero':returns[:4]}))
