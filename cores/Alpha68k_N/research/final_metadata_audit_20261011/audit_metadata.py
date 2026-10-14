"""Bounded primary MAME XML/ROM/layout/menu audit; no game replay or canonical writes."""
from pathlib import Path
import hashlib, json, re, subprocess, xml.etree.ElementTree as ET, zipfile

O = Path(__file__).resolve().parent
R = Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
OLD = Path(r"D:\Arcade\AI\aCORES\Alpha68k N")
MAME = OLD / "tools/mame0289/mame.exe"
DRIVER = Path(r"D:\Arcade\AI\mame289\src\mame\alpha\alpha68k_n.cpp")
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
assert sha(MAME) == "af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3"
assert MAME.read_bytes()[:2] == b"MZ"
profiles = js(R / "board_profiles.json")
layout = js(R / "rom_layout.json")
manifest = js(R / "research/rom_manifest.json")
previous = js(R / "research/feature_mra_validation.json")
source_pins = [pin(p) for p in (MAME, DRIVER, R / "Alpha68k_N.sv", R / "board_profiles.json", R / "rom_layout.json", R / "research/rom_manifest.json", R / "research/feature_mra_validation.json", R / "scripts/make_feature_mras.py")]
cases = []
for profile_id, name in enumerate(("kyros", "kyrosj", "sstingry")):
    command = [str(MAME), "-listxml", name]
    actual = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert actual.returncode == 0, actual.stderr
    xml_path = O / f"mame0289_{name}.xml"
    assert not xml_path.exists()
    xml_path.write_text(actual.stdout, encoding="utf-8")
    root = ET.fromstring(actual.stdout)
    machine = next(x for x in root.findall("machine") if x.get("name") == name)
    info = profiles["profiles"][name]
    mra_path = R / previous["sets"][name]["mra"]
    mra = ET.parse(mra_path).getroot()
    dip_nodes = machine.findall("dipswitch")
    machine_dips = {x.get("name"): x for x in dip_nodes}
    switches = mra.find("switches")
    mra_dips = {x.get("name"): x for x in switches.findall("dip")}
    dchecks = []
    for dip in info["dips"]:
        name_dip = dip["name"]
        original = machine_dips[name_dip]
        target = mra_dips[name_dip]
        mask = int(original.get("mask"))
        low, high = (mask & -mask).bit_length()-1, mask.bit_length()-1
        expected_bits = str(low) if low == high else f"{low},{high}"
        original_values = [(x.get("name"), int(x.get("value")), x.get("default") == "yes") for x in original.findall("dipvalue")]
        profile_values = [(x["name"], int(x["value"]), x["default"] == "yes") for x in dip["values"]]
        ids = target.get("ids").split(",")
        values = [int(x) << low for x in target.get("values").split(",")]
        dchecks.append({"name": name_dip, "mask": mask, "bits": target.get("bits"),
            "profile_matches_primary_MAME": int(dip["mask"]) == mask and profile_values == original_values,
            "MRA_bits_values_labels_match_MAME": target.get("bits") == expected_bits and list(zip(ids, values)) == [(n, v) for n, v, d in original_values],
            "max_OSD_columns": max(len(name_dip) + len(v) + 2 for v in ids)})
    default = 0
    for node in dip_nodes:
        for value in node.findall("dipvalue"):
            if value.get("default") == "yes": default |= int(value.get("value"))
    archive_path = R / manifest[name]["archive"]
    rom_node = next(x for x in mra.findall("rom") if x.get("index") == "0")
    crc_checks = []
    with zipfile.ZipFile(archive_path) as archive:
        def expand(node):
            output = bytearray()
            for part in node:
                if part.tag == "part":
                    if part.get("name"):
                        matches = [x for x in archive.infolist() if f"{x.CRC:08x}" == part.get("crc").lower()]
                        assert matches
                        candidate = next((x for x in matches if x.filename == part.get("name")), matches[0])
                        data = archive.read(candidate)
                        offset, length = int(part.get("offset", "0"), 0), int(part.get("length"), 0)
                        assert offset + length <= len(data)
                        primary = [x for x in machine.findall("rom") if x.get("crc") == part.get("crc").lower()]
                        crc_checks.append({"part_name": part.get("name"), "CRC": part.get("crc").lower(), "archive_member": candidate.filename, "primary_MAME_CRC_present": bool(primary), "offset": offset, "length": length})
                        output.extend(data[offset:offset+length])
                    else:
                        output.extend(bytes.fromhex(part.text or "") * int(part.get("repeat", "1"), 0))
                elif part.tag == "interleave":
                    lanes = {}
                    for child in part:
                        node2 = ET.Element("root"); node2.append(child)
                        lanes[child.get("map")] = expand(node2)
                    assert set(lanes) == {"01", "10"} and len(lanes["01"]) == len(lanes["10"])
                    output.extend(b for pair in zip(lanes["01"], lanes["10"]) for b in pair)
            return bytes(output)
        packed = expand(rom_node)
    payload_path = R / layout["sets"][name]["path"]
    payload = payload_path.read_bytes()
    regions = []
    for region in layout["sets"][name]["regions"]:
        regions.append({"name": region["name"], "base_hex": hex(region["base"]), "declared": region})
    checks = {
        "source_driver_same_pinned_oracle": sha(DRIVER) == "5f9884076ea1b5c02d2169a58de5425ae5475a13a4f1438abae2e2b9f0fdab7d",
        "MRA_setname_version_rbf": mra.findtext("setname") == name and mra.findtext("mameversion") == "0289" and mra.findtext("rbf") == "Alpha68k_N",
        "MRA_description_matches_primary_MAME": mra.findtext("name") == machine.findtext("description"),
        "MRA_year_matches_primary_MAME": mra.findtext("year") == machine.findtext("year"),
        "profile_and_MRA_all_DIP_fields_exact": len(dchecks) == len(dip_nodes) == len(mra_dips) and all(x["profile_matches_primary_MAME"] and x["MRA_bits_values_labels_match_MAME"] for x in dchecks),
        "MRA_DIP_default_exact": int(switches.get("default"), 16) == default,
        "all_DIP_menu_labels_within28": all(x["max_OSD_columns"] <= 28 for x in dchecks),
        "all_ROM_CRCs_present_in_primary_MAME": all(x["primary_MAME_CRC_present"] for x in crc_checks),
        "expanded_MRA_same_pinned_payload": packed == payload and sha(payload_path) == previous["sets"][name]["rom_sha256"],
        "payload_header_profile_version": len(payload) == layout["download_bytes"] == 0xa0000 and payload[:6] == b"A68N" + bytes([1, profile_id]),
        "MCU_profile2_remains_development": name != "sstingry" or mra_path.parent.name == "development",
    }
    cases.append({"set": name, "profile_id": profile_id, "MRA": pin(mra_path), "MAME_XML": pin(xml_path), "MAME_XML_command": command, "MAME_XML_actual_exit": actual.returncode,
        "checks": checks, "failed_checks": [k for k, v in checks.items() if not v], "DIPs": dchecks, "DIP_default": default,
        "year_MRA_MAME": [mra.findtext("year"), machine.findtext("year")], "manufacturer_MRA_MAME": [mra.findtext("manufacturer"), machine.findtext("manufacturer")],
        "button_names": mra.find("buttons").get("names"), "CRC_parts": crc_checks, "payload": pin(payload_path), "ROM_regions": regions})
top_path = R / "Alpha68k_N.sv"
top = top_path.read_text(encoding="utf-8")
conf = top.split("localparam CONF_STR = {", 1)[1].split("};", 1)[0]
parts = re.findall(r'"([^"\n]*)"', conf)
menus = []
for part in parts:
    entries = part.rstrip(";").split(",")
    if len(entries) > 2 and re.search(r"O(?:\[|[0-9A-Za-z])", entries[0]):
        menus.append({"selector": entries[0], "label": entries[1], "options": entries[2:], "max_columns": max(len(entries[1])+len(value)+2 for value in entries[2:])})
menu_checks = {
    "all_core_OSD_option_lines_within28": all(x["max_columns"] <= 28 for x in menus),
    "direct_video_hides_orientation_90_scale": all(any(x["selector"].startswith("H0") and x["label"] == label for x in menus) for label in ("Orientation", "Rotate 90", "Scale")),
    "CRT_children_hide_until_active": all(any(x["selector"].startswith("H1") and x["label"] == label for x in menus) for label in ("H-Size", "H-Position", "V-Position")),
    "VSize_hides_direct_video_or_disabledCRT": any(x["selector"].startswith("H3") and x["label"] == "V-Size" for x in menus) and "direct_video || !crt_active" in top,
    "hiscore_hides_until_configured": any(x["selector"].startswith("H2") and x["label"] == "Autosave Hiscores" for x in menus) and "!hs_configured" in top,
    "canonical_profile2_header_still_rejected": "board_load_data[15:8]<=1" in top,
    "DIP_transport_index254_byte0": "ioctl_index==254 && ioctl_addr==0" in top,
    "ROM_transport_index0": "ioctl_download && ioctl_index==0" in top,
    "no_rotary_OSD": not re.search(r"rotary|dial|spinner", conf, re.I),
}
joined = OLD / "research/stingray_combined_stage/next_coupled_scope_v2/source/rtl/alpha68kn_board.sv"
joined_text = joined.read_text()
load_lines = [{"line": i+1, "text": line.strip()} for i, line in enumerate(joined_text.splitlines()) if "load_addr" in line and any(s in line for s in ("main_rom", "sound_rom", "mcu_rom", "39000", "3a000", "20100", "00100"))]
output = O / "metadata_audit.json"
assert not output.exists()
result = {"scope": "Primary pinnedMAME0289 XML, archivedCRC/expandedpayload, staticmenu and intendedjoinedP6 loading audit only. No canonical changes or profile2 enablement.", "source_pins": source_pins, "cases": cases, "menu_items": menus, "menu_checks": menu_checks, "joined_board": pin(joined), "joined_load_contract": load_lines,
    "all_static_metadata_checks_pass": all(all(x["checks"].values()) for x in cases) and all(menu_checks.values()),
    "unqualified": ["Actual nondefaultDIP/coin/cocktail/flip effects in each game.", "Japan/Stingray earned-score save/reset/restore and profile2 MCU-safe wrapper borrowing.", "Affected joined-framework video modes and physicaloutputs.", "Stingray Fire/Special weapon labels remain provisional; original instructionpanel evidence is unavailable.", "No runtime, physical, resource/timing or allgame acceptance follows from metadata correctness."]}
output.write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
print(json.dumps({"path": str(output), "sha256": sha(output), "failed": {x["set"]: x["failed_checks"] for x in cases}, "menu_failed": [k for k,v in menu_checks.items() if not v], "year_pairs": {x["set"]: x["year_MRA_MAME"] for x in cases}, "CRC_parts": sum(len(x["CRC_parts"]) for x in cases), "profile2_enabled": False}))
