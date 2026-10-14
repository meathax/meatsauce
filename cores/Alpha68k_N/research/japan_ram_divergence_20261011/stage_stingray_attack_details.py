"""Freeze only needed score/rank/projectile ROM source windows, no game runtime."""
from pathlib import Path
import json,hashlib,subprocess
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'stingray_route1800/attack_diagnosis'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
tool=ROOT/'tools/mame0289/unidasm.exe';rom=ROOT/'roms/sstingry/maincpu.bin';entries=[]
for base,count in [(0x1744,160),(0x255a,260),(0x4200,620),(0x44d0,110),(0x3b60,100),(0x2f30,100),(0x9280,90),(0x3f26,64)]:
    cmd=[str(tool),str(rom),'-arch','m68000','-skip',str(base),'-count',str(count),'-basepc',f'{base:x}']
    child=subprocess.run(cmd,capture_output=True,text=True);assert child.returncode==0
    p=HERE/f'ROM_{base:06x}.asm.txt';assert not p.exists();p.write_text(child.stdout+child.stderr)
    entries.append(dict(command=cmd,actual_exit=0,output=pin(p)))
b=(HERE.parent/'revised_reference_v1/capture/frame_000119.hiscore148.bin').read_bytes()
rows=[dict(offset=i,bytes=b[4+i:4+i+14].hex(),scoreBCD=b[4+i:8+i].hex(),name=b[8+i:16+i].decode('ascii',errors='replace'),stage=b[16+i:18+i].hex()) for i in range(0,140,14)]
p=HERE/'score_rank_source_details.json';p.write_text(json.dumps(dict(source=pin(Path(__file__)),ROM=pin(rom),unidasm=pin(tool),disassembly=entries,boot148=pin(HERE.parent/'revised_reference_v1/capture/frame_000119.hiscore148.bin'),candidate14byte_layout=rows,sentinel=b[144:].hex(),warning='Stride14 and count10 remain candidate until source255a rank loop is reviewed.'),indent=2)+'\n')
print(json.dumps(dict(details=pin(p),actual_exits=[0]*8,table=rows,sentinel=b[144:].hex()),indent=2))
