"""Preserve a native checkpoint across only the proven USA blank-sprite skip.

This deliberately rejects any other RTL, CPU, ROM, model or serialization change.
The original streams are retained. No saved register/memory byte is patched.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,sys
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('base');p.add_argument('new_work');p.add_argument('name')
a=p.parse_args();root=Path(__file__).resolve().parents[1]
assert sys.platform.startswith('linux'),'Run explicitly in Ubuntu WSL'
assert re.fullmatch(r'[A-Za-z0-9_-]+',a.name)
base=Path(a.base).resolve();new=Path(a.new_work).resolve()
saved=json.loads(Path(str(base)+'.json').read_text())
current=json.loads((new/'sim/results/av-source-stamp.json').read_text())
old=(root/'sim/results/current-builds/cop-rom-combat2p').resolve()
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
assert sha(old/'sim/build/av/Vzero_av_top')==saved['model_binary_sha256'],'Unexpected origin model'
assert sha(new/'sim/build/av/Vzero_av_top')==current['model_binary_sha256'],'New model changed'
for key in ('rom_regions','verilator_version','model_config'):
    assert saved[key]==current[key],f'{key} changed'
assert saved['sources'].keys()==current['sources'].keys(),'Source closure changed'
changed={s for s,h in saved['sources'].items() if h!=current['sources'][s]}
rtl_changed={s for s in changed if s.startswith('rtl/') or s.endswith('zero_av_top.sv')}
allowed={'rtl/ZeroTeam_video.sv','rtl/Raiden2/Raiden2_sprite_renderer.sv'}
assert rtl_changed==allowed,f'Unexpected hardware changes: {rtl_changed}'
assert changed-allowed=={'sim/run_av.sh'},f'Unexpected harness changes: {changed-allowed}'
renderer=(old/'rtl/Raiden2/Raiden2_sprite_renderer.sv').read_text()
renderer=renderer.replace('module Raiden2_sprite_renderer (',
'''module Raiden2_sprite_renderer #(
    // Zero Team's upper 4 MiB is unpopulated and reads transparent 0xff.
    // Keep the full address range for donor boards that populate both halves.
    parameter BLANK_UPPER_HALF = 1'b0
) (''')
renderer=renderer.replace("\t\t\t\t\tif (spr_data == 16'd0) begin       // entry vuota: stesso test di prima",
'''\t\t\t\t\t// USA fills unused slots with code 0x8000 at (0,0). Avoid
\t\t\t\t\t// spending the top-row budget fetching transparent ROM padding.
\t\t\t\t\tif (spr_data == 16'd0 || (BLANK_UPPER_HALF && spr_data[15])) begin''')
assert renderer==(new/'rtl/Raiden2/Raiden2_sprite_renderer.sv').read_text(),'Sprite change exceeds the proven skip'
video=(old/'rtl/ZeroTeam_video.sv').read_text().replace(
    '    Raiden2_sprite_renderer sprite_layer (','    Raiden2_sprite_renderer #(.BLANK_UPPER_HALF(1)) sprite_layer (')
assert video==(new/'rtl/ZeroTeam_video.sv').read_text(),'Video change exceeds the target parameter'
def methods(path):
    text=Path(path).read_text();out={}
    for match in re.finditer(r'void\s+(\w+::__V(?:de)?serialize)\([^)]*\)\s*\{',text):
        pos=match.end();depth=1
        while depth:
            if text[pos]=='{':depth+=1
            elif text[pos]=='}':depth-=1
            pos+=1
        out[match[1]]=text[match.start():pos]
    return out
schemas={}
for name in ('Vzero_av_top.cpp','Vzero_av_top__Syms__Slow.cpp','Vzero_av_top___024root__Slow.cpp'):
    left=methods(old/'sim/build/av'/name);right=methods(new/'sim/build/av'/name)
    assert left==right,f'Native serialization differs in {name}'
    schemas.update({key:hashlib.sha256(body.encode()).hexdigest() for key,body in left.items()})
assert len(schemas)==4,'Unexpected native serialization closure'
headers={}
for name in ('Vzero_av_top.h','Vzero_av_top__Syms.h','Vzero_av_top___024root.h'):
    first=old/'sim/build/av'/name;second=new/'sim/build/av'/name
    assert first.read_bytes()==second.read_bytes(),f'Model ABI changed in {name}'
    headers[name]=sha(first)
original={suffix:sha(str(base)+suffix) for suffix in ('.rtl','.host','.json')}
out=root/'sim/results/native-migrations'/a.name
assert not out.exists(),'Retain existing migration evidence; choose another name'
out.mkdir(parents=True)
probe=out/'probe-';env=os.environ.copy();env['AV_PROBE_MODEL_DIR']=str(new/'sim/build/av')
subprocess.run(['bash',str(root/'sim/run_av_state_probe.sh'),str(base),str(probe),'--roundtrip'],cwd=root,env=env,check=True)
assert sha(str(probe)+'roundtrip.rtl')==original['.rtl'],'Passive full native roundtrip changed bytes'
numeric=json.loads(Path(str(probe)+'numeric.json').read_text())
profile=saved.get('physical_inputs')
if profile:
    import csv
    assert sha(profile['path'])==profile['sha256'],'Input fixture changed'
    with Path(profile['path']).open(newline='') as f:initial=next(csv.DictReader(f))
    expected=(int(initial['dips'],0),int(initial['system'],0)&0x0700)
else:expected=(0xffff,0x0700)
assert (numeric['dips'],numeric['cabinet'])==expected,'Actual native reset configuration differs'
assert original=={suffix:sha(str(base)+suffix) for suffix in original},'Origin streams changed'
destination=out/'checkpoint'
for suffix in ('.rtl','.host'):
    shutil.copyfile(str(base)+suffix,str(destination)+suffix)
    assert sha(str(destination)+suffix)==original[suffix]
proof={'scope':'Lossless native checkpoint migration for only the USA blank-sprite skip; not a gameplay acceptance',
    'origin_base':str(base),'origin_streams_sha256':original,'destination_base':str(destination),
    'origin_model_sha256':saved['model_binary_sha256'],'new_model_sha256':current['model_binary_sha256'],
    'changed_rtl':sorted(rtl_changed),'serialization_methods_sha256':schemas,'identical_model_headers_sha256':headers,
    'roundtrip_sha256':sha(str(probe)+'roundtrip.rtl'),'all_saved_bytes_preserved':True,
    'host_bytes_preserved':True,'passive_no_eval_no_clocks':True,'cycle':numeric['cycle'],
    'native_reset_configuration':{'dips':numeric['dips'],'cabinet':numeric['cabinet']},
    'observer_source_sha256':sha(root/'sim/av_state_probe.cpp')}
metadata=dict(current)
for key in ('run_arguments','physical_inputs'):
    if key in saved:metadata[key]=saved[key]
    else:metadata.pop(key,None)
metadata['native_migration']=proof
Path(str(destination)+'.json').write_text(json.dumps(metadata,indent=2)+'\n')
(out/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({'migrated_base':str(destination),'cycle':numeric['cycle'],'new_model_sha256':current['model_binary_sha256'],
    'all_saved_bytes_preserved':True,'reset_configuration':proof['native_reset_configuration']}))
