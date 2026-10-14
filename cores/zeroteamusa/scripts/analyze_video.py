"""Save and compare the actual RTL-rendered early boot image against MAME."""
from pathlib import Path
import hashlib,json
from PIL import Image

root=Path(__file__).resolve().parents[1]
out=root/'sim/results'
image=Image.open(out/'rtl-logo.ppm').convert('RGB')
reference=Image.open(out/'mame-attract-60/reference.png').convert('RGB')
assert image.size==reference.size==(320,256)
image.save(out/'rtl-logo.png')
a=list(image.get_flattened_data()); b=list(reference.get_flattened_data())
meta={'scope':'Isolated real RTL video path using actual CPU/COP boot buffers',
      'size':list(image.size),'different_pixels':sum(x!=y for x,y in zip(a,b)),
      'nonblack_rtl_pixels':sum(x!=(0,0,0) for x in a),
      'nonblack_mame_pixels':sum(x!=(0,0,0) for x in b),
      'rtl_image_sha256':hashlib.sha256((out/'rtl-logo.png').read_bytes()).hexdigest(),
      'reference_image_sha256':hashlib.sha256((out/'mame-attract-60/reference.png').read_bytes()).hexdigest(),
      'limits':'Captured early boot buffers; CPU and sound are not running in this isolated video fixture. Sprite cipher is integrated and separately verified, but later animated scenes remain pending.'}
sources=['rtl/ZeroTeam_video.sv','rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv','sim/zero_video_top.sv','sim/video_main.cpp']+[f'rtl/Raiden2/{n}.sv' for n in ['Raiden2_video_timing','Raiden2_text_renderer','Raiden2_tile_layer','Raiden2_sprite_renderer','spram_dp','tile_rom_arbiter','raiden2_mixer']]
meta['source_sha256']={s:hashlib.sha256((root/s).read_bytes()).hexdigest() for s in sources}
meta['timing']=json.loads((out/'video-fixture.json').read_text())
(root/'docs/evidence/video-logo.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({k:meta[k] for k in ['different_pixels','nonblack_rtl_pixels','nonblack_mame_pixels','timing']},indent=2))
