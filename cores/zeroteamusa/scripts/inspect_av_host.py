"""Read saved bridge counters/images without advancing any RTL clock."""
from pathlib import Path
import argparse,hashlib,json,struct

FIELDS=('requests,cop_requests,writes,reads,irqs,dma,pal_dma,busy,main_due,cop_due,'
        'gfx_due,gfx_requests,av_frame_pixels,av_complete_frames,zfetch,ziack,zwrite,zcoinread,zfmwrite,zokiwrite,'
        'asamples,anonzero,zpendingcycles,soundtraces').split(',')

def inspect(base,image=None):
    base=Path(base);root=Path(__file__).resolve().parents[1]
    meta=json.loads(Path(str(base)+'.json').read_text())
    source=root/'sim/board_main.cpp'
    assert hashlib.sha256(source.read_bytes()).hexdigest()==meta['sources']['sim/board_main.cpp'],'Bridge source changed'
    assert 'uint64_t requests,cop_requests,writes,reads,irqs,dma,pal_dma,busy,main_due,cop_due;' in source.read_text(),'Bridge prefix changed'
    with Path(str(base)+'.host').open('rb') as f:
        magic,size=struct.unpack('<QQ',f.read(16))
        assert magic==0x5a54484f53543031 and 24*8<=size<1024,'Unrecognized native bridge header'
        counters=dict(zip(FIELDS,struct.unpack('<24Q',f.read(24*8))))
        if image:
            f.seek(16+size+320*256*3)
            pixels=f.read(320*256*3)
            assert len(pixels)==320*256*3,'Incomplete saved frame'
            Path(image).write_bytes(b'P6\n320 256\n255\n'+pixels)
    assert Path(str(base)+'.rtl').is_file(),'Missing native RTL state'
    return {'scope':'Read-only saved host counters, not a resumed simulation',
            'base':str(base),'model_binary_sha256':meta['model_binary_sha256'],'host_struct_bytes':size,
            'cycle':int(base.name.rsplit('-',1)[1]),'counters':counters}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('base');p.add_argument('--image');p.add_argument('--output')
    a=p.parse_args();result=inspect(a.base,a.image)
    if a.output:Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))

if __name__=='__main__':main()
