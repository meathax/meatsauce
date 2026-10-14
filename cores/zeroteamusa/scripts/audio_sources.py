"""One shared inventory for the target sound simulation and later QIP wiring."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sources=[root/'rtl/ZeroTeam_audio.sv']
for folder in ('rtl/tv80','rtl/sound/jtopl','rtl/sound/jt6295'):
    sources.extend(sorted((root/folder).glob('*.v')))
# JT cores use these real shared memory/filter components.
sources.extend(root/f'rtl/sound/{name}' for name in ('jtframe_dual_ram.v','jtframe_fir_mono.v'))
out=root/'sim/audio_sources.f'
out.write_text('\n'.join(p.relative_to(root).as_posix() for p in sources)+'\n')
print(f'{len(sources)} target sound RTL files')
