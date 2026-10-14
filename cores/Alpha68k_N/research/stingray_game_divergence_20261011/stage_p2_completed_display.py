"""Bind reviewed completed-texture consumer semantics without mutating references."""
from pathlib import Path
import hashlib,json,re
O=Path(__file__).resolve().parent;J=O/'p2_gameplay181'
B=O.parent/'stingray_combined_stage/next_coupled_scope_v2'
R=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/sim/captures/sstingry/gameplay')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
manifest=B/'completed_texture_consumer_fix/import_manifest.json'
assert H(manifest)=='fde5566380fccd5df657b01002e867f0a46f8cb09150550bfdbca4801d56ad3d'
for p in json.loads(manifest.read_text())['files']:
    assert H(Path(p['path']))==p['sha256']
proof=json.loads((B/'first_buffer_cause/verification.json').read_text());pins=proof['completed_RGB_pins'];pins=pins.values() if isinstance(pins,dict) else pins
observer=json.loads((O/'native_observer181/verification.json').read_text())
pngs={r['name']:r for r in observer['reference_all5_completedPNG_RAM_exact'] if r['name'].endswith('.png')}
F=J/'mame_completed_texture';F.mkdir(exist_ok=True);binding=[]
for r in pins:
    p=Path(r['path']);assert H(p)==r['sha256'];f=int(re.search(r'frame_(\d+)',p.name).group(1))
    png=R/f'frame_{f:06d}.png';assert H(png)==pngs[png.name]['original_sha256']
    local=F/f'frame_{f:06d}.display.rgb'
    assert not local.exists(),'Preserve completed display outputs'
    local.write_bytes(p.read_bytes());assert H(local)==r['sha256']
    binding.append({'frame':f,'MAME_completed_PNG':pin(png),'qualified_completed_RGB':pin(p),'MAME_display_RGB':pin(local),'native_RGB_path':str(J/f'capture/frame_{f:06d}.rgb'),'unshifted_unmasked':True})
result={'scope':'Reuse reviewed consumer contract: MAME completed .display.rgb versus actual native .rgb; no source/reference edits, PNG re-recording, offsets or masks.','reviewed_consumer_manifest':pin(manifest),'completed_png_cause_manifest':pin(B/'first_buffer_cause/import_manifest.json'),'official_PNG_readonly_observer_invariance':pin(O/'native_observer181/verification.json'),'frames':sorted(binding,key=lambda r:r['frame'])}
p=J/'completed_texture_consumer_binding.json';assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'binding':str(p),'sha256':H(p),'frames':len(binding)}))
