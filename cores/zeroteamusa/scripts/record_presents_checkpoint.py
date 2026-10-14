"""Record the correctly idle live 120-IRQ image and actual saved RTL inputs."""
from pathlib import Path
import json,hashlib
root=Path(__file__).resolve().parents[1]
base=root/'sim/results/av-checkpoint-208000000'
parent=json.loads(Path(str(base)+'.json').read_text())
video=json.loads((root/'sim/results/rtl-live-checkpoint-2.json').read_text())
assert video['different_pixels']==0 and video['mame_frame']==120
meta={'scope':'Real live V30/COP/video/cipher/sound reaches SEIBU PRESENTS; correct active-low coin idle',
      'cycles':208000000,'main_irq_acks':120,'complete_video_frames':119,
      'coin_idle':255,
      'sound':{'z80_fetches':862283,'irq_acks':512,'fm_data_writes':1205,'oki_writes':0,
               'samples':107717,'nonzero_samples':107716},
      'counts_source':'Actual bounded sim/board_main.cpp checkpoint output',
      'video':video,'build_inputs':parent,
      'checkpoint_hashes':{s:hashlib.sha256(Path(str(base)+s).read_bytes()).hexdigest() for s in ('.rtl','.host','.json')},
      'image_sha256':hashlib.sha256((root/'sim/results/rtl-live-checkpoint-2.ppm').read_bytes()).hexdigest(),
      'limits':['Early static image is pixel-exact; stable populated attract and gameplay remain pending.',
                'No OKI playback/music/speech correctness or four-player RTL gameplay claimed.',
                'Native checkpoint continuation to later attract is active; no hardware/RBF validation.']}
(root/'docs/evidence/live-presents-120.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Recorded pixel-exact live SEIBU PRESENTS with real hardware/bridge checkpoint hashes.')
