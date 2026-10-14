"""Track compact evidence for a partial integrated-board run, never game completion."""
from pathlib import Path
import hashlib
import json

root=Path(__file__).resolve().parents[1]
result=json.loads((root/'sim/results/board-boot.json').read_text())
assert result['rom_requests']>100 and result['cpu_writes']>100
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
sources=(root/'sim/board_sources.f').read_text().splitlines()+['sim/board_main.cpp']
evidence={
    'set':'zeroteam', 'date':'2026-10-04',
    'command':f"wsl.exe -d Ubuntu --cd D:\\Arcade\\AI\\aCORES\\zero --exec bash ./sim/run_board.sh {result['cycles']}",
    'result':result,
    'program_sha256':digest(root/'roms/regions/maincpu.bin'),
    'sources':{p:digest(root/p) for p in sources},
    'dumps':{p.name:digest(p) for p in (root/'sim/results').glob('board-*.bin')},
    'limits':[
        'Real RTL V30, COP, CRTC, memory and DMA buffers; renderer and sound CPU are pending.',
        'Sound reads are explicitly open bus in this partial harness; no attract or gameplay completion claim.',
        'No ROM patch, injected CPU state, host CPU emulation or COP response stub.',
        'DMA and interrupt counts establish activity; target protection/sort/cipher behavior still needs comparison.',
        'DIP defaults and full four-player/sound input behavior still need integration.',
        'RAM/buffer snapshot uses a paused CPU after the timed run; not a rendered video frame.',
    ]
}
target=root/'docs/evidence/board-seam.json'
target.write_text(json.dumps(evidence,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ['cycles','irq_acks','video_dma_words','palette_dma_words','buffer_nonzero_words']},indent=2))
