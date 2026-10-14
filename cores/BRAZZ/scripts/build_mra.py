"""Emit the Crystal System MRA set (every MAME 0.289 game this core supports) and verify each stream.

Index 1: 16-byte board record read by rtl/board/cs_board_config.sv ("CRYS", version 1, game id,
populated flash banks), the format of the BrezzaSoft_Crystal_System_MiSTer core.
Index 0 image (rtl/board/cs_mister_rom_loader.sv): the populated 16 MiB cartridge flash files with
MAME 0.289's init_<game> halfword overlays applied (little-endian), then the 128 KiB BIOS. That is
the DDR3 layout the core reads (cart 0x30000000, BIOS right after the populated banks), so the ROM
carries address="0x30000000" for Main_MiSTer's direct DDR3 copy; older builds stream it.
Index 4: battery RAM (64 KiB); urachamu ships MAME's default NVRAM image in its zip.
`--check` assembles every generated MRA with scripts/mra.py from the MAME 0.289 zips and checks the
size, every patched halfword and the BIOS placement; crysking is also compared with the staged image.
"""
from pathlib import Path
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
DDR_ADDRESS = "0x30000000"
BANK = 0x1000000
ROMDIR = Path(r"D:\Arcade\AI\MAME 0.289 ROMs (merged)")
DIPS = [(0, "Pause"), (1, "Free Play"), *[(i, f"Unknown DSW {i+1}") for i in range(2, 7)], (7, "Test")]
# MiSTer joystick order (CONF_STR J1): b1,b2,b3,b4,Start,Coin,Pause,Service Credit,Service Menu.
BIOS_B = ("crysbios.zip", "mx27l1000.u14", "beff39a9")
BIOS_D = ("crysbios.zip", "mx27l1000-alt.u14", "1e8175c8")


def crysking_patches():
    from stage_roms import PATCHES
    return dict(PATCHES)


# MAME 0.289 src/mame/misc/crystal.cpp init_* overlays, as flash byte offsets.
GAMES = [
    dict(file="The Crystal of Kings.mra", name="The Crystal of Kings", set="crysking", id=1, year="2001",
         maker="BrezzaSoft", category="Beat'em Up", players=2, zip="crysking.zip",
         flash=[("bcsv0004f01.u1", "8feff120"), ("bcsv0004f02.u2", "0e799845"), ("bcsv0004f03.u3", "659e2d17")],
         bios=BIOS_B, patches=crysking_patches,
         buttons=("Attack,Jump,Magic,-,Start,Coin,Pause,Service Credit,Service Menu", "A,B,X,-,Start,Select,L,-,-")),
    dict(file="_alternatives/_The Crystal of Kings/The Crystal of Kings (AMG0110D BIOS).mra",
         name="The Crystal of Kings", set="crysking", id=1, year="2001", maker="BrezzaSoft", category="Beat'em Up",
         players=2, zip="crysking.zip",
         flash=[("bcsv0004f01.u1", "8feff120"), ("bcsv0004f02.u2", "0e799845"), ("bcsv0004f03.u3", "659e2d17")],
         bios=BIOS_D, patches=crysking_patches,
         remark="Uses the AMG0110D BIOS (mx27l1000-alt.u14) from crysbios.zip instead of the default AMG0110B.",
         buttons=("Attack,Jump,Magic,-,Start,Coin,Pause,Service Credit,Service Menu", "A,B,X,-,Start,Select,L,-,-")),
    dict(file="Evolution Soccer.mra", name="Evolution Soccer", set="evosocc", id=2, year="2001",
         maker="Evoga / BrezzaSoft", category="Sports / Soccer", players=2, zip="evosocc.zip",
         flash=[("bcsv0001u01", "2581a0ea"), ("bcsv0001u02", "47ef1794"), ("bcsv0001u03", "f396a2ec")],
         bios=BIOS_B,
         patches=lambda: {2 * BANK + o: v for o, v in {0x97388e: 0x90fc, 0x973890: 0x9001, 0x971058: 0x907c,
                          0x971060: 0x9001, 0x978036: 0x900c, 0x978038: 0x8303, 0x974ed0: 0x90fc,
                          0x974ed2: 0x9001}.items()},
         buttons=("Shoot/Pass/Slide,High Pass/Tackle,Turbo,Special,Start,Coin,Pause,Service Credit,Service Menu",
                  "A,B,X,Y,Start,Select,L,-,-")),
    dict(file="Top Blade V.mra", name="Top Blade V", set="topbladv", id=3, year="2003",
         maker="Sonokong / Expotato", category="Action", players=2, zip="topbladv.zip",
         flash=[("flash.u1", "bd23f640")], bios=BIOS_B,
         patches=lambda: {0x12d7a: 0x90fc, 0x12d7c: 0x9001, 0x18880: 0x9004, 0x18882: 0x9001,
                          0x2fe18: 0x9001, 0x2fe1a: 0x9200, 0x2ed44: 0xdfe9, 0x2ed46: 0xc3c2},
         buttons=("Attack (Red),Jump (Blue),-,-,Start,Coin,Pause,Service Credit,Service Menu", "A,B,-,-,Start,Select,L,-,-")),
    dict(file="Office Yeoin Cheonha.mra", name="Office Yeoin Cheonha (version 1.2)", set="officeye", id=4,
         year="2001", maker="Danbi", category="Party / Reaction", players=3, zip="officeye.zip",
         flash=[("flash.u1", "d3f3eec4"), ("flash.u2", "e4f85d0a")], bios=("officeye.zip", "bios.u14", "ffc57e90"),
         # MAME master: real PIC16F84A (dumped) and no code patches. MAME 0.289's eight patch words leave the
         # PIC's answer missing, so the game's anti-tamper interrupt corrupts random RAM words (random freezes).
         patches=lambda: {}, pic=("office_yeo_in_cheon_ha_pic16f84a.bin", "7561cdf5", 0x4280),
         buttons=("Red,Green,Blue,-,Start,Coin,Pause,Service Credit,Service Menu", "A,B,X,-,Start,Select,L,-,-")),
    dict(file="Urachacha Mudaeri.mra", name="Urachacha Mudaeri (Korea)", set="urachamu", id=5, year="2002",
         maker="GamToU", category="Party / Reaction", players=3, zip="urachamu.zip",
         flash=[("u1", "f341d6fc"), ("u2", "ad81d61f"), ("u3", "3c7e32a4"), ("u4", "c5505627")], bios=BIOS_B,
         patches=lambda: {}, nvram=("nvram", "66df826d"),
         buttons=("Blue,Yellow,Red,-,Start,Coin,Pause,Service Credit,Service Menu", "A,B,X,-,Start,Select,L,-,-")),
]


def check_version():
    import json
    audit = json.loads((ROOT / "docs/preparation_check.json").read_text(encoding="utf-8"))
    version = next(c["evidence"] for c in audit["checks"] if c["check"] == "oracle is official MAME 0.289" and c["passed"])
    if "0.289" not in version:
        raise ValueError("Audited MAME capture does not establish version 0.289")


def generate_one(g):
    root = ET.Element("misterromdescription")
    for tag, value in [("name", g["name"]), ("setname", g["set"]), ("rbf", "Arcade-CrystalSystem"),
                       ("mameversion", "0289"), ("year", g["year"]), ("manufacturer", g["maker"]),
                       ("category", g["category"]), ("players", str(g["players"])),
                       ("joystick", "8-way" if g["players"] == 2 else "none"), ("rotation", "horizontal"),
                       ("resolution", "15kHz"), ("homebrew", "no"), ("bootleg", "no")]:
        ET.SubElement(root, tag).text = value
    if g.get("remark"):
        ET.SubElement(root, "remark").text = g["remark"]
    banks = len(g["flash"])
    record = ET.SubElement(root, "rom", index="1")
    ET.SubElement(record, "part").text = " ".join(f"{b:02X}" for b in b"CRYS" + bytes([1, g["id"], banks]) + bytes(9))
    if g.get("pic"):  # before the ROM, so the firmware is in place when the board leaves reset
        pic = ET.SubElement(root, "rom", index="3", zip=g["zip"])
        ET.SubElement(pic, "part", name=g["pic"][0], crc=g["pic"][1])
    bios_zip, bios_name, bios_crc = g["bios"]
    zips = g["zip"] if bios_zip == g["zip"] else f"{g['zip']}|{bios_zip}"
    rom = ET.SubElement(root, "rom", index="0", zip=zips, address=DDR_ADDRESS)
    patches = g["patches"]()
    for bank, (name, crc) in enumerate(g["flash"]):
        cursor = 0
        for offset, value in sorted((o - bank * BANK, v) for o, v in patches.items() if bank * BANK <= o < (bank + 1) * BANK):
            if offset > cursor:
                ET.SubElement(rom, "part", name=name, crc=crc, offset=hex(cursor), length=hex(offset - cursor))
            ET.SubElement(rom, "part").text = value.to_bytes(2, "little").hex(" ").upper()
            cursor = offset + 2
        if cursor == 0:
            ET.SubElement(rom, "part", name=name, crc=crc)
        else:
            ET.SubElement(rom, "part", name=name, crc=crc, offset=hex(cursor), length=hex(BANK - cursor))
    ET.SubElement(rom, "part", name=bios_name, crc=bios_crc)
    if g.get("nvram"):
        nv = ET.SubElement(root, "rom", index="4", zip=g["zip"])
        ET.SubElement(nv, "part", name=g["nvram"][0], crc=g["nvram"][1])
    ET.SubElement(root, "nvram", index="4", size="65536")
    switches = ET.SubElement(root, "switches", default="FF", base="0")
    for bit, name in DIPS:
        ET.SubElement(switches, "dip", name=name, bits=str(bit), ids="On,Off")
    names, defaults = g["buttons"]
    ET.SubElement(root, "buttons", names=names, default=defaults)
    ET.indent(root, space="  ")
    path = ROOT / "releases" / g["file"]
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    return path


def generate():
    check_version()
    return [generate_one(g) for g in GAMES]


def check(paths):
    """Assemble each MRA from the MAME 0.289 zips; verify size, patches, BIOS and the board record."""
    import mra
    for path, g in zip(paths, GAMES):
        zips = [ROOT / "roms" / z if (ROOT / "roms" / z).is_file() else ROMDIR / z
                for z in dict.fromkeys([g["zip"], g["bios"][0]])]
        image = mra.build_image(path, zips)
        banks = len(g["flash"])
        assert len(image) == banks * BANK + 0x20000, f"{path.name}: size {len(image):#x}"
        for bank, (name, _) in enumerate(g["flash"]):
            with zipfile.ZipFile(ROMDIR / g["zip"]) as z:
                raw = bytearray(z.read(name))
            for o, v in g["patches"]().items():
                if bank * BANK <= o < (bank + 1) * BANK:
                    raw[o - bank * BANK:o - bank * BANK + 2] = v.to_bytes(2, "little")
            assert image[bank * BANK:(bank + 1) * BANK] == raw, f"{path.name}: bank {bank} differs"
        with zipfile.ZipFile(ROMDIR / g["bios"][0]) as z:
            assert image[banks * BANK:] == z.read(g["bios"][1]), f"{path.name}: BIOS differs"
        rec = bytes.fromhex(ET.parse(path).getroot().find("rom[@index='1']/part").text)
        assert rec[:4] == b"CRYS" and rec[5] == g["id"] and rec[6] == banks and len(rec) == 16
        if g.get("pic"):
            part = ET.parse(path).getroot().find("rom[@index='3']/part")
            with zipfile.ZipFile(ROMDIR / g["zip"]) as z:
                info = z.getinfo(part.get("name"))
            assert f"{info.CRC:08x}" == part.get("crc") == g["pic"][1] and info.file_size == g["pic"][2], f"{path.name}: PIC"
        if g["set"] == "crysking" and (ROOT / "roms/images/crysking.bin").is_file():
            assert image[:3 * BANK] == (ROOT / "roms/images/crysking.bin").read_bytes(), "crysking differs from staged image"
        print(f"PASS {path.name}: {banks} bank(s) + BIOS {g['bios'][1]} = {len(image):#x} bytes, "
              f"{len(g['patches']())} MAME patch words, board record id {g['id']}")
    return 0


if __name__ == "__main__":
    out = generate()
    for p in out:
        print(p)
    if "--check" in sys.argv:
        sys.exit(check(out))
