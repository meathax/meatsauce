"""Bind a live AV run to its build inputs before later integrations change them."""
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path(__file__).resolve().parents[1]
files=(root/'sim/board_sources.f').read_text().splitlines()
files += (root/'sim/audio_sources.f').read_text().splitlines()
files += ['rtl/ZeroTeam_video.sv','sim/zero_av_top.sv','sim/board_main.cpp','rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv']
files += ['sim/run_av.sh']
files += [f'rtl/Raiden2/crypt/{n}.hex' for n in ['rotate_zt','x5_zt','x11_zt']]
files += [f'rtl/Raiden2/{n}.sv' for n in ['Raiden2_video_timing','Raiden2_text_renderer','Raiden2_tile_layer','Raiden2_sprite_renderer','spram_dp','tile_rom_arbiter','raiden2_mixer']]
# Compiler include files and readmem initializers are build/runtime inputs too.
# Conservative coverage avoids silently accepting changed V30 microcode tables.
files += [p.relative_to(root).as_posix() for p in (root/'rtl').rglob('*')
          if p.is_file() and p.suffix.lower() in ('.svh','.vh','.hex','.mif','.mem')]
files += ['scripts/snapshot_av_sources.py']
files = sorted(set(files))
meta={'scope':'Live V30/COP/CRTC/video/cipher/TV80/YM3812/single OKI6295',
      'verilator_version':subprocess.check_output(['verilator','--version'],text=True).strip(),
      'model_config':{'top':'zero_av_top','savable':True,'defines':['CE_HALF_PLUS2','READY_FIXED_HIGH','CE_STALL_ON']},
      'dependency_coverage':'Compile list plus all RTL headers and runtime initialization tables; older stamps are not retroactively expanded',
      'sources':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},
      'rom_regions':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'roms/regions').glob('*.bin')}}
meta['run_arguments']=sys.argv[1:]
meta['model_binary_sha256']=hashlib.sha256((root/'sim/build/av/Vzero_av_top').read_bytes()).hexdigest()
if '--load' in sys.argv:
    parent=Path(sys.argv[sys.argv.index('--load')+1])
    meta['resumed_from']={'base':parent.as_posix(),
                          'streams':{suffix:hashlib.sha256(Path(str(parent)+suffix).read_bytes()).hexdigest()
                                     for suffix in ('.rtl','.host','.json')}}
if '--inputs' in sys.argv:
    inputs=Path(sys.argv[sys.argv.index('--inputs')+1])
    meta['physical_inputs']={'path':inputs.as_posix(),'sha256':hashlib.sha256(inputs.read_bytes()).hexdigest()}
(root/'sim/results/av-source-stamp.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Saved live-run source/ROM hash inventory.')
