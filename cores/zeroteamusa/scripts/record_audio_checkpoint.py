"""Bind the observed first live AV checkpoint without reading in-flight final files."""
from pathlib import Path
import json,hashlib
root=Path(__file__).resolve().parents[1]
stamp=json.loads((root/'sim/results/av-source-stamp.json').read_text())
video=json.loads((root/'sim/results/rtl-live-checkpoint-1.json').read_text())
meta={'scope':'First completed checkpoint of the active 600-frame live AV run',
      'cycles':104000000,'complete_video_frames':59,'main_irq_acks':60,
      'sound':{'z80_fetches':431365,'irq_acks':254,'fm_data_writes':587,'oki_writes':0,
               'samples':53858,'nonzero_samples':53857},
      'counts_source':'Bounded checkpoint emitted by sim/board_main.cpp during the actual run',
      'video':video,'build_inputs':stamp,
      'image_sha256':hashlib.sha256((root/'sim/results/rtl-live-checkpoint-1.ppm').read_bytes()).hexdigest(),
      'limits':['The run is still active; these are checkpoint counts, not final results.',
                'Historical run incorrectly drove active-low coin idle to zero; it is not uncredited-attract or credited-input proof.',
                'No credited gameplay, four-player operation, music/speech correctness or hardware validation claimed.',
                'No OKI command has been issued by this early point; sample playback remains pending.',
                'The unchanged 162-pixel boot discrepancy remains unresolved.']}
(root/'docs/evidence/audio-live-60.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Recorded real live CPU/video/sound checkpoint and source/ROM hashes.')
