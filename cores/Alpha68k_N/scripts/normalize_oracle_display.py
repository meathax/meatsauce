"""Canonical native RGB from the displayed MAME texture, not its drawing buffer."""
from pathlib import Path
import argparse, hashlib, json
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def normalize(directory):
    records=[]
    for png in sorted(directory.glob('frame_*.png')):
        with Image.open(png) as image:
            if image.size!=(224,256):
                raise RuntimeError(f'Unexpected ROT90 snapshot dimensions: {png}: {image.size}')
            # All three pinned GAME declarations use ROT90 (clockwise).
            rgb=image.transpose(Image.Transpose.ROTATE_90).convert('RGB').tobytes()
        output=png.with_suffix('.display.rgb')
        output.write_bytes(rgb)
        old=png.with_suffix('.rgb')
        diff=None
        if old.exists():
            data=old.read_bytes()
            if len(data)!=len(rgb):raise RuntimeError('screen:pixels dimensions differ')
            diff=sum(data[i:i+3]!=rgb[i:i+3] for i in range(0,len(rgb),3))
        records.append({'source_png':png.relative_to(ROOT).as_posix(),'png_sha256':sha(png),
            'native_rgb':output.relative_to(ROOT).as_posix(),'native_rgb_sha256':sha(output),
            'source_orientation':'ROT90','native_dimensions':[256,224],
            'drawing_buffer_differences':diff})
    if not records:raise RuntimeError('No MAME snapshots: '+str(directory))
    return records
def main():
    p=argparse.ArgumentParser()
    p.add_argument('--set',choices=['kyros','kyrosj','sstingry'])
    p.add_argument('--mode',choices=['attract','gameplay'])
    a=p.parse_args()
    records=[]
    for name in ([a.set] if a.set else ['kyros','kyrosj','sstingry']):
        for mode in ([a.mode] if a.mode else ['attract','gameplay']):
            records.extend(normalize(ROOT/'sim/captures'/name/mode))
    report={'method':'displayed render texture PNG; inverse pinned ROT90; lossless native RGB bytes',
        'drawing_buffer_policy':'original screen:pixels .rgb/.pix32 retained as diagnostic evidence; not canonical current displayed frames',
        'original_capture_manifest_sha256':sha(ROOT/'research/reference_capture_manifest.json'),
        'normalizer_sha256':sha(Path(__file__)),
        'source_sha256':{name:sha(Path(r'D:\Arcade\AI\mame289\src\emu')/name) for name in ['screen.cpp','video.cpp']},
        'captures':records}
    (ROOT/'research/oracle_display_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'snapshots':len(records),'differing_drawing_buffers':sum(bool(x['drawing_buffer_differences']) for x in records)}))
if __name__=='__main__':main()
