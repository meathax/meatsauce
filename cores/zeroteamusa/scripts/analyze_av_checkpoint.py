"""Inspect one completed live checkpoint without consuming partial final reports."""
from pathlib import Path
import argparse,hashlib,json,re
from PIL import Image,ImageChops
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkpoint',type=int)
parser.add_argument('reference',type=int)
parser.add_argument('--snapshot',type=Path,help='Matching native checkpoint .json inventory')
parser.add_argument('--evidence',help='Tracked evidence basename, without extension')
parser.add_argument('--expect-equal',action='store_true')
parser.add_argument('--image',type=Path,help='Completed final image instead of the periodic raster')
parser.add_argument('--report',type=Path,help='Completed board report for this final image')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
checkpoint=args.checkpoint;reference=args.reference
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def identity(path): return {'path':path.relative_to(root).as_posix(),'sha256':sha(path)}
if args.evidence:
    if not args.snapshot: parser.error('--evidence requires the matching --snapshot inventory')
    if not re.fullmatch(r'[a-z0-9-]+',args.evidence): parser.error('Invalid evidence basename')
path=(root/args.image).resolve() if args.image else root/f'sim/results/rtl-live-checkpoint-{checkpoint}.ppm'
image=Image.open(path).convert('RGB')
image.save(path.with_suffix('.png'))
refs=list((root/f'sim/results/mame-attract-{reference}').glob('*.png'))
assert len(refs)==1,refs
ref=Image.open(refs[0]).convert('RGB')
assert image.size==ref.size==(320,256)
pixels=list(image.get_flattened_data());golden=list(ref.get_flattened_data())
different=sum(a!=b for a,b in zip(pixels,golden))
meta={'checkpoint':checkpoint,'mame_frame':reference,'different_pixels':different,
      'difference_bbox':ImageChops.difference(image,ref).getbbox(),
      'rtl_nonblack':sum(any(p) for p in pixels),'mame_nonblack':sum(any(p) for p in golden),
       'limits':'Completed raster checkpoint; approximate cycle/frame alignment, not a gameplay-completion claim.'}
meta['rtl_image']=identity(path)
meta['mame_image']=identity(refs[0])
meta['comparison']='All RGB pixels in the actual 320x256 image; no shift, crop or color remapping.'
if args.report:
    report_path=(root/args.report).resolve()
    report=json.loads(report_path.read_text())
    meta['completed_board_report']=identity(report_path)
    meta['board_counters']={key:report[key] for key in ('cycles','irq_acks','complete_video_frames','cpu_reads','cpu_writes','video_dma_words','palette_dma_words','gfx_rom_requests','sound')}
if args.snapshot:
    inventory_path=(root/args.snapshot).resolve()
    inventory=json.loads(inventory_path.read_text())
    meta['frozen_build_inventory']=identity(inventory_path)
    meta['model_config']=inventory['model_config']
    meta['model_binary_sha256']=inventory['model_binary_sha256']
    meta['relevant_sources']={key:value for key,value in inventory['sources'].items()
        if key in ('rtl/Raiden2/Raiden2_cop3.sv','rtl/Raiden2/Raiden2_sprite_renderer.sv','sim/zero_av_top.sv')}
path.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n')
if args.evidence:
    (root/'docs/evidence'/f'{args.evidence}.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta))
if args.expect_equal and different: raise SystemExit(1)
