"""Finish local project bookkeeping without starting implementation or Quartus."""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    provenance = ROOT / "docs/template_provenance.json"
    revision = json.loads(provenance.read_text())["revision"] if provenance.exists() else subprocess.run([r"C:\Program Files\Git\cmd\git.exe", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    (ROOT / "docs/template_provenance.json").write_text(json.dumps({
        "url": "https://github.com/MiSTer-devel/Template_MiSTer", "revision": revision,
        "project_name": "CrystalSystem", "framework_changes": "None; sys remains unmodified",
        "bootstrap_changes": "Quartus 17 project/wrapper/constraint filenames renamed; Quartus 13 project files removed; preparation/tool scaffolding added"}, indent=2) + "\n", encoding="utf-8")
    ignore = ROOT / ".gitignore"
    with ignore.open("a", encoding="utf-8") as stream:
        if "# Private inputs and generated development outputs" not in ignore.read_text():
            stream.write("\n# Private inputs and generated development outputs\nroms/\nmister.env\n.env\n__pycache__/\n*.pyc\n"
                         "build/\ncaptures/\nsim/output/\nsim/obj_dir/\n*.rbf\n*.vcd\n*.fst\n"
                         "# Local pinned upstream snapshots; tracked manifest/script recover them\ndonors/*/\n")
    (ROOT / "mister.env").write_text(
        "# Local machine paths only; credentials stay in global/session instructions.\n"
        "MISTER_CORES_ROOT=D:/Arcade/AI/aCORES/BRAZZ\n"
        "MAME_SRC=D:/Arcade/AI/mame289/src/mame/misc/crystal.cpp\n"
        "MAME_DIR=D:/Arcade/AI/mameexe\nMAME_EXE=D:/Arcade/AI/mameexe/mame.exe\n"
        "MAME_ROMPATH=D:/Arcade/AI/aCORES/BRAZZ/Arcade-CrystalSystem_MiSTer/roms\n"
        "QUARTUS_BIN=D:/q17/quartus/bin64\nMSYS2_ROOT=D:/vibes/fpga/toolchains/msys64\n",
        encoding="utf-8")
    profile = {
        "_comment": "Crystal System CPU address-space inventory from MAME 0.289. Generic capture/trace tools still need SE3208 adaptation. Select bounded snapshots/taps for each oracle capture; do not dump every region every frame.",
        "cpu": ":maincpu", "space": "program", "bus_bytes": 4, "big_endian": False,
        "read": {"workram": ["0x02000000", "0x027fffff"], "textram": ["0x03800000", "0x03ffffff"],
                 "frameram": ["0x04000000", "0x047fffff"], "nvram": ["0x01400000", "0x0140ffff"]},
        "wtap": {"vregs": ["0x03000000", "0x030000ff"], "crtc": ["0x01803400", "0x018037ff"],
                 "sound": ["0x04800000", "0x04800fff"], "textram": ["0x03800000", "0x03ffffff"],
                 "frameram": ["0x04000000", "0x047fffff"]},
        "sweep": ["vregs", "crtc", "sound", "textram", "frameram"],
        "trace": {"addr_hi": "0xffffffff", "io": ["0x01200000", "0x01ffffff"], "vectors": ["0x00000000", "0x000000ff"],
                  "rom": [["0x00000000", "0x0001ffff"], ["0x05000000", "0x05ffffff"]],
                  "ram": [["0x02000000", "0x027fffff"], ["0x03800000", "0x047fffff"]]},
        "inputs": {"coin": "Coin 1", "start": "1 Player Start", "hold": "P1 Right", "pulse": "P1 Button 1"}}
    (ROOT / "scripts/mame/regions.json").write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")
    (ROOT / "Readme.md").write_text(
        "# Crystal System / The Crystal of Kings for MiSTer\n\n"
        "Preparation project for BrezzaSoft's 2001 The Crystal of Kings (`crysking`). "
        "**The game core is not implemented or playable yet.** The template's demonstration RTL is still present.\n\n"
        "The main implementation plan is [plan.md](plan.md); actual work goes in [progress.md](progress.md). "
        "[goal_prompt.md](goal_prompt.md) contains the next execution prompt. "
        "[Hardware notes](docs/HARDWARE_NOTES.md) and the [donor coverage map](docs/DONOR_MAP.md) record the research.\n\n"
        "The official MiSTer template, nine pinned public donor/reference snapshots and audited local crysking/BIOS archives "
        "are staged. No compatible public SE3208 or complete VRender0 RTL was located; CPU/SoC/video/audio/DS1302 target logic "
        "needs implementation. Donor presence is not an integration or license-clearance claim.\n\n"
        "All game bring-up, attract mode, sound and gameplay must work in synthesizable RTL simulation/Verilator first. "
        "Quartus/RBF/deployment/MiSTer testing is the final phase. The root `CrystalSystem.qpf` is a renamed Quartus 17 template.\n\n"
        "ROMs, credentials, local configuration and large donor snapshots are excluded from commits. "
        "Source revisions/provenance are recorded in `donors/manifest.json` and local donor directories. "
        "The original template license is retained; individual donor reuse/compatible licensing is resolved before RTL promotion.\n\n"
        "Oracle: full vanilla MAME 0.289, with seven matching key reference files from `mame0289`. "
        "The eight MAME protection patches and reset workaround are explicitly documented. "
        "Copied scripts are generic scaffolding and need SE3208/board adaptation.\n\n"
        "Preparation and plan include AI-generated work. Future implementation, validation status, third-party notices and "
        "material approximations must remain explicit. No release bitstream exists yet.\n", encoding="utf-8")
    redundant = ROOT / "docs/reference/mame/crystal.cpp"
    if redundant.exists():
        redundant.unlink()
    manifests = json.loads((ROOT / "donors/manifest.json").read_text())
    lines = ["# Pinned donor revision index", "", "| Snapshot | Revision | Files | License metadata |", "|---|---|---:|---|"]
    for item in manifests:
        lines.append(f"| {item['name']} | `{item['revision']}` | {item['files']} | {item['license_spdx']} |")
    (ROOT / "donors/REVISIONS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"project": str(ROOT), "template_revision": revision, "snapshots": len(manifests),
                      "profile": "SE3208 little-endian 32-bit", "quartus_run": False, "hardware_run": False}, indent=2))


if __name__ == "__main__":
    main()
