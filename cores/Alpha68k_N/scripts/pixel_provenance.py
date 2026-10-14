"""Offline Kyros pixel ownership diagnostic; never substitutes for RTL execution."""
import argparse
import hashlib
import json
from pathlib import Path


def trace(image, ram, x, y):
    word = lambda a: int.from_bytes(ram[a * 2:a * 2 + 2], "big")
    layers = []
    for group, offset in [(2, 0x800), (3, 0xc00), (1, 0x400)]:
        for strip in range(0, 0x400, 0x20):
            pos_address = strip + group
            position = word(pos_address)
            mx, my = position & 255, (-(position >> 8)) & 255
            for row in range(32):
                address = strip + offset + row
                data = word(address)
                if data != 0x20 and mx <= x < mx + 8 and my <= y < my + 8:
                    bank = ((data >> 10) & 3) + ((data >> 13) & 4)
                    tile = (data & 0x3ff) + ((data >> 3) & 0x400)
                    color = image[0x31000 + ((data >> 1) & 0x1000)
                                  + (data & 0xffc) + ((data >> 14) & 3)]
                    iy, ix = y - my, x - mx
                    if data & 0x1000:
                        iy = 7 - iy
                    base = (bank // 2) * 0x18000
                    planes = [0 if bank & 1 else 4,
                              (0x10000 if bank & 1 else 0x8000) * 8]
                    planes.append(planes[1] + 4)
                    pen = 0
                    for p, plane in enumerate(planes):
                        bit = base * 8 + tile * 128 + plane + iy * 8 + [67, 66, 65, 64, 3, 2, 1, 0][ix]
                        if image[0x40000 + bit // 8] & (0x80 >> (bit % 8)):
                            pen |= 1 << (2 - p)
                    index = (color % 32) * 8 + pen
                    indirect = ((image[0x30500 + index] & 15) << 4) | (image[0x30400 + index] & 15)
                    rgb = [(image[a + indirect] & 15) * 17 for a in [0x30100, 0x30200, 0x30300]]
                    layers.append(dict(group=group, strip=strip // 32, row=row,
                                       position_address=0x40000 + pos_address * 2,
                                       tile_address=0x40000 + address * 2, data=data,
                                       position=position, bank=bank, tile=tile,
                                       color=color, pen=pen, rgb=rgb))
                my = (my + 8) & 255
    return layers


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("payload", type=Path)
    p.add_argument("sprites", type=Path)
    p.add_argument("display_rgb", type=Path)
    p.add_argument("report", type=Path)
    args = p.parse_args()
    image, ram, display = [x.read_bytes() for x in [args.payload, args.sprites, args.display_rgb]]
    if len(image) != 0xa0000 or image[5] > 1 or len(ram) != 8192 or len(display) != 256 * 224 * 3:
        raise ValueError("unflipped Kyros/Japan fixture sizes/profile required")
    pixels = []
    for x, y in [(26, 24), (27, 24), (28, 24), (29, 31)]:
        layers = trace(image, ram, x, y)
        opaque = [a for a in layers if a["pen"]]
        source = list(display[((y - 16) * 256 + x) * 3:((y - 16) * 256 + x) * 3 + 3])
        pixels.append(dict(x=x, raster_y=y, layers=layers, displayed_rgb=source,
                           owner_matches_display=bool(opaque) and opaque[-1]["rgb"] == source))
    result = dict(scope="four unflipped Kyros pixels; offline MAME loop transcription, no CPU/RTL acceptance",
                  inputs={str(x): hashlib.sha256(x.read_bytes()).hexdigest()
                          for x in [args.payload, args.sprites, args.display_rgb]}, pixels=pixels)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(report=str(args.report), owner_matches=[x["owner_matches_display"] for x in pixels],
                          owners=[x["layers"][-1] if x["layers"] else None for x in pixels])))
    return 0 if all(x["owner_matches_display"] for x in pixels) else 1


if __name__ == "__main__":
    raise SystemExit(main())
