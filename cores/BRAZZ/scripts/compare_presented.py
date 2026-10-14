"""Compare complete native RTL and MAME presented frames, with no resizing.
Pixel equality is separate from game-state/input alignment. Never grants game
acceptance merely because two images (including two blank images) match.
"""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--rtl",type=Path,required=True,help="natural RTL snapshot directory")
    ap.add_argument("--mame",type=Path,required=True,help="native MAME frame metadata")
    ap.add_argument("--out",type=Path,required=True,help="private pair evidence directory")
    ap.add_argument("--alignment",type=Path,help="independent equivalent-state/event/input explanation; not inferred by this pixel tool")
    args=ap.parse_args()
    rtl=json.loads((args.rtl/"state.json").read_text())
    frame=rtl["complete_scanout"]
    assert rtl["natural_rtl_observation"] and frame["image_saved"] and frame["completed"]>0
    assert frame["width"]==320 and frame["height"]==240
    ppm=(args.rtl/"scanout_complete.ppm").read_bytes()
    header=re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s",ppm)
    assert header and tuple(map(int,header.groups()))==(320,240),"RTL frame is not a full native 320x240 P6 image"
    rgb=ppm[header.end():]
    assert len(rgb)==320*240*3
    pixels=[((rgb[i]&0xf8)<<8)|((rgb[i+1]&0xfc)<<3)|(rgb[i+2]>>3) for i in range(0,len(rgb),3)]
    packed=struct.pack("<"+"H"*len(pixels),*pixels)
    reference=json.loads(args.mame.read_text())
    assert reference["complete_screen"] and (reference["width"],reference["height"])==(320,240)
    expected=args.mame.with_suffix(".rgb565").read_bytes()
    assert len(expected)==len(packed) and digest(expected)==reference["rgb565_sha256"]
    wanted=[x[0] for x in struct.iter_unpack("<H",expected)]
    different=[i for i,(got,want) in enumerate(zip(pixels,wanted)) if got!=want]
    first=[{"x":i%320,"y":i//320,"rtl_rgb565":f"{pixels[i]:04x}","mame_rgb565":f"{wanted[i]:04x}"} for i in different[:16]]
    alignment=None
    if args.alignment:
        alignment=json.loads(args.alignment.read_text())
        assert alignment["rtl_run_id"]==rtl["run_id"]
        assert alignment["rtl_start_clock"]==frame["start_clock"] and alignment["rtl_end_clock"]==frame["end_clock"]
        assert alignment["mame_frame"]==reference["frame"]
        assert alignment.get("equivalent_game_state_evidence") and alignment.get("input_route_evidence")
    args.out.mkdir(parents=True,exist_ok=True)
    mask=bytearray(320*240*3)
    for i in different:mask[i*3]=255
    (args.out/"difference.ppm").write_bytes(b"P6\n320 240\n255\n"+mask)
    (args.out/"rtl.rgb565").write_bytes(packed)
    report={"scope":"complete native presented RGB565 pixel comparison; equivalent game state and route require independent evidence",
            "rtl":{"snapshot":str(args.rtl.resolve()),"run_id":rtl["run_id"],"frame_start_clock":frame["start_clock"],"frame_end_clock":frame["end_clock"],"state_sha256":digest((args.rtl/"state.json").read_bytes()),"rgb565_sha256":digest(packed)},
            "mame":{"metadata":str(args.mame.resolve()),"frame":reference["frame"],"rgb565_sha256":digest(expected),"presented_bank_matches":reference["presented_bank_matches"],"script_sha256":reference["script_sha256"],"rom_archives":reference["rom_archives"]},
            "width":320,"height":240,"compared_pixels":76800,"mismatch_pixels":len(different),
            "first_mismatches":first,"alignment_evidence":alignment,"equivalent_state_verified_by_pixel_tool":False,
            "pixel_equal":not different,"game_acceptance":False,"command_hint":"repeat this command with preserved frame/alignment metadata; aggregate required scenes separately"}
    (args.out/"comparison.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({"compared_pixels":76800,"mismatch_pixels":len(different),"pixel_equal":not different,"game_acceptance":False,"evidence":str(args.out/"comparison.json")}))
    return int(bool(different))

if __name__=="__main__":
    raise SystemExit(main())
