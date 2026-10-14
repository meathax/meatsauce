"""Convert the actual ignored RTL snapshots for the isolated renderer fixture."""
from pathlib import Path
import struct
root=Path(__file__).resolve().parents[1]
for layer in ['bg','mg','fg','text','sprite','palette']:
    data=(root/f'sim/results/board-{layer}.bin').read_bytes()
    assert len(data)==4096,layer
    words=struct.unpack('<2048H',data)
    (root/f'sim/results/video-fixture-{layer}.mem').write_text(''.join(f'{v:04x}\n' for v in words))
print('Prepared six renderer memories from actual RTL boot snapshots.')
