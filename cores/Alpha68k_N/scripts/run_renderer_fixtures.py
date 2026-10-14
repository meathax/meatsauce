"""Finite isolated strip fixtures. These do not satisfy CPU/game acceptance."""
from pathlib import Path
import csv, hashlib, json, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def fixture(setname):
    p=ROOT/'sim/captures'/setname/'gameplay'
    selected=sorted(p.glob('*.sprites.bin'))[-2]
    frame=int(selected.name.split('.')[0].split('_')[1])
    row=next(x for x in csv.DictReader((p/'frame_states.csv').open()) if int(x['frame'])==frame)
    return selected,int(row['background']),selected.with_suffix('').with_suffix('.display.rgb')
def stress(setname):
    image=(ROOT/'roms'/setname/'download.bin').read_bytes()
    sting=setname=='sstingry'
    words=[0]*4096
    for g,(c,d) in enumerate([(2,0x800),(3,0xc00),(1,0x400)]):
        for s in range(32):
            x=(s*8+(s&1))&255
            if sting and s>=25:x=249+(s-25)
            words[s*32+c]=((s%8)<<8)|x
            for i in range(32):
                bank=(s+g)% (4 if sting else 8)
                tile=([0,0x3ff] if sting else [0,0x3ff,0x400,0x7ff])[i%(2 if sting else 4)]
                data=((bank&3)<<10)|((bank>>2)<<15)|(tile&0x3ff)|((tile>>10)<<13)|((i&1)<<12)|((s&1)<<14)
                if data==(0x40 if sting else 0x20):data+=1
                words[s*32+d+i]=data
    if not sting:
        # Make color 0xff visibly exercised, without changing any ROM byte.
        for data in range(65536):
            address=((data>>1)&0x1000)|(data&0xffc)|((data>>14)&3)
            if image[0x31000+address]!=255 or data==0x20:continue
            bank=((data>>10)&3)|((data>>13)&4);tile=(data&0x3ff)|((data>>3)&0x400)
            base=(bank//2)*0x18000+tile*16
            other=base+(0x10000 if bank&1 else 0x8000)
            mask=0xf0 if bank&1 else 0x0f
            if any(image[0x40000+base+i]&mask or image[0x40000+other+i] for i in range(16)):
                words[30*32+0x400+3]=data;break
        else:raise RuntimeError('no nonempty Kyros color-ff fixture found')
    output=ROOT/'sim/captures/renderer/fixtures'/f'{setname}_stress.sprites.bin'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(b''.join(w.to_bytes(2,'big') for w in words))
    return output,38 if not sting else 0,None
def main():
    sources={}
    for line in (ROOT/'sim/build/renderer_inputs.sha256').read_text().splitlines():
        digest,name=line.split(None,1);p=ROOT/name
        if sha(p)!=digest:raise RuntimeError('renderer build source changed: '+name)
        sources[name]=digest
    exe=ROOT/'sim/build/alpha68kn_render_fixture_sim'
    results=[]
    failed=False
    cases=[]
    for name in ['kyros','kyrosj','sstingry']:
        cases.append((name,'recorded',False,fixture(name)))
    for name in ['kyros','sstingry']:
        cases.append((name,'flip_formula',True,fixture(name)))
        cases.append((name,'boundaries',False,stress(name)))
    for name,label,flip,(ram,bg,oracle) in cases:
        out=ROOT/'sim/captures/renderer'/f'{name}_{label}'
        cmd=['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec','./sim/build/alpha68kn_render_fixture_sim',
             f'roms/{name}/download.bin',ram.relative_to(ROOT).as_posix(),str(bg),
             out.relative_to(ROOT).as_posix(),str(int(flip)),oracle.relative_to(ROOT).as_posix() if oracle and not flip else '-']
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
        (out.parent/f'{out.name}.log').write_text(p.stdout+p.stderr)
        item={'set':name,'fixture':label,'exit_code':p.returncode,'command':cmd,
            'input_ram_sha256':sha(ram),'input_payload_sha256':sha(ROOT/'roms'/name/'download.bin')}
        if p.stdout.strip():item['result']=json.loads(p.stdout)
        if oracle and not flip:item['oracle_rgb_sha256']=sha(oracle)
        if label=='boundaries' and 'result' in item:
            result=item['result'];coverage=[]
            if result['banks_mask']!=(15 if name=='sstingry' else 255):coverage.append('all banks')
            if result['boundary_codes_mask']!=(3 if name=='sstingry' else 15):coverage.append('boundary tile codes')
            if name=='kyros' and result['color_ff_tiles']==0:coverage.append('valid color ff')
            if coverage:item['coverage_failures']=coverage;item['exit_code']=1
        failed=failed or bool(item['exit_code'])
        results.append(item)
        report={'scope':'isolated real strip/palette/SDRAM RTL using captured MAME RAM or named boundary fixtures; no CPU boot/game acceptance',
            'source_sha256':sources,'executable_sha256':sha(exe),
            'mame_driver_sha256':sha(Path(r'D:\Arcade\AI\mame289\src\mame\alpha\alpha68k_n.cpp')),
            'mame_drawgfx_sha256':sha(Path(r'D:\Arcade\AI\mame289\src\emu\drawgfx.cpp')),
            'cases':results}
        (ROOT/'research/renderer_fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps({'set':name,'fixture':label,'code':p.returncode,'result':item.get('result'),'stderr':p.stderr[-500:]}),flush=True)
    return 1 if failed else 0
if __name__=='__main__':raise SystemExit(main())
