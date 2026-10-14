"""Stage pinned upstream donor snapshots and local MAME/ROM references.

ROMs remain private and unmodified. Downloads are source references, not
claims that a donor implements the Crystal System's register interface.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import io
import json
import pathlib
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAME = pathlib.Path(r"D:\Arcade\AI\mame289")
MAME_EXE = pathlib.Path(r"D:\Arcade\AI\mameexe\mame.exe")
ROMPATH = pathlib.Path(r"D:\Arcade\AI\MAME 0.289 ROMs (merged)")
DONORS = [
    ("jtframe", "jotego/jtcores", "JTFRAME clock enables, SDRAM/cache/FIFO/bus primitives; public chip/core catalogue", "modules/jtframe"),
    ("saturn", "MiSTer-devel/Saturn_MiSTer", "VDP1 textured framebuffer renderer; SCSP PCM; memory arbitration", None),
    ("psx", "MiSTer-devel/PSX_MiSTer", "GPU texture/cache/blend/framebuffer architecture; DDR3/SDRAM transport", None),
    ("neogeo", "MiSTer-devel/NeoGeo_MiSTer", "RTC BCD/calendar and persistent backup RAM integration; serial protocol differs", None),
    ("siliconre", "furrtek/SiliconRE", "K054539 PCM sample/voice scheduling reference; not VRender0-compatible", "K054539"),
    ("hiscores", "JimmyStones/Hiscores_MiSTer", "MiSTer high-score persistence and pause arbitration", None),
    ("crt_adjust", "rmonic79/MiSTer-CRT-Adjust", "Core-side analog geometry adjustment", None),
    ("sdram", "ultraembedded/core_sdram_axi4", "Small Verilog SDRAM controller fallback/reference", None),
    ("pic_risc8", "collectivertl/risc8_tcoonan", "Licensed PIC16C57-compatible research fallback; cartridge MCU model and firmware are unknown", None),
]


def request(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "CrystalSystem-source-staging", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=90) as response:
        return response.read()


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage_donor(item):
    name, repo, purpose, subtree = item
    dest = ROOT / "donors" / name
    provenance = dest / "PROVENANCE.json"
    if provenance.exists():
        return json.loads(provenance.read_text(encoding="utf-8"))
    result = {"name": name, "repository": repo, "url": f"https://github.com/{repo}", "purpose": purpose}
    try:
        info = json.loads(request(f"https://api.github.com/repos/{repo}"))
        pinned_manifest = ROOT / "donors" / "manifest.json"
        pinned = next((x for x in json.loads(pinned_manifest.read_text(encoding="utf-8")) if x["name"] == name and x.get("revision")), None) if pinned_manifest.exists() else None
        target_ref = pinned["revision"] if pinned else info["default_branch"]
        commit = json.loads(request(f"https://api.github.com/repos/{repo}/commits/{target_ref}"))
        revision = commit["sha"]
        archive_url = f"https://codeload.github.com/{repo}/zip/{revision}"
        data = request(archive_url)
        archive_hash = hashlib.sha256(data).hexdigest()
        dest.mkdir(parents=True, exist_ok=True)
        files = []
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for entry in archive.infolist():
                relative = pathlib.PurePosixPath(entry.filename)
                relative = pathlib.PurePosixPath(*relative.parts[1:])
                if not relative.parts or entry.is_dir() or ".." in relative.parts:
                    continue
                if any(p in {".git", "releases", "output_files", "db", "incremental_db"} for p in relative.parts):
                    continue
                if relative.suffix.lower() in {".rbf", ".sof", ".rom", ".bin", ".exe", ".dll"}:
                    continue
                if subtree and subtree.lower() not in str(relative).lower() and len(relative.parts) > 1:
                    continue
                target = dest.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
                files.append(str(relative))
        license_info = info.get("license") or {}
        result.update(status="staged", revision=revision, default_branch=info["default_branch"],
                      license_spdx=license_info.get("spdx_id", "NOASSERTION"),
                      archive_url=archive_url, archive_sha256=archive_hash,
                      selected_subtree=subtree, files=len(files),
                      source_bytes=sum(p.stat().st_size for p in dest.rglob("*") if p.is_file()),
                      local_changes="None; source-only snapshot with generated provenance; binary releases omitted")
        (dest / "FILES.json").write_text(json.dumps(files, indent=2) + "\n", encoding="utf-8")
        provenance.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        (dest / "PROVENANCE.md").write_text(
            f"# {repo}\n\nUpstream: {result['url']}\n\nRevision: `{revision}`\n\n"
            f"Archive SHA256: `{archive_hash}`\n\nLicense metadata: `{result['license_spdx']}`. "
            "Review individual file headers before reuse; retain their original license notices.\n\n"
            f"Purpose: {purpose}.\n\nUnmodified source reference snapshot; binary releases omitted. "
            "See FILES.json for staged paths. This is not proof of compatibility with VRender0.\n",
            encoding="utf-8")
    except Exception as error:
        result.update(status="failed", error=f"{type(error).__name__}: {error}")
    return result


def stage_local():
    reference = ROOT / "docs" / "reference" / "mame"
    paths = ["src/mame/misc/crystal.cpp", "src/devices/cpu/se3208",
             "src/devices/machine/vrender0.cpp", "src/devices/machine/vrender0.h",
             "src/devices/machine/vr0uart.cpp", "src/devices/machine/ds1302.cpp",
             "src/devices/machine/ds1302.h", "src/devices/machine/intelfsh.cpp",
             "src/devices/machine/intelfsh.h", "src/devices/machine/nvram.cpp",
             "src/devices/machine/nvram.h", "src/devices/video/vrender0.cpp",
             "src/devices/video/vrender0.h", "src/devices/sound/vrender0.cpp",
             "src/devices/sound/vrender0.h", "src/version.cpp", "COPYING"]
    inventory = []
    for relative in paths:
        source = MAME / relative
        if not source.exists():
            continue
        sources = list(source.rglob("*")) if source.is_dir() else [source]
        for file in sources:
            if not file.is_file():
                continue
            target = reference / file.relative_to(MAME)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
            inventory.append({"path": str(file.relative_to(MAME)).replace("\\", "/"), "sha256": sha256(target), "bytes": target.stat().st_size})
    reference.mkdir(parents=True, exist_ok=True)
    (reference / "SOURCE_MANIFEST.json").write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
    romdir = ROOT / "roms"
    romdir.mkdir(exist_ok=True)
    rom_inventory = []
    for filename in ["crysking.zip", "crysbios.zip"]:
        target = romdir / filename
        if not target.exists():
            shutil.copy2(ROMPATH / filename, target)
        with zipfile.ZipFile(target) as archive:
            bad = archive.testzip()
            if bad:
                raise RuntimeError(f"ROM ZIP failed CRC validation: {filename}/{bad}")
            members = [{"name": x.filename, "size": x.file_size, "crc32": f"{x.CRC:08x}"} for x in archive.infolist() if not x.is_dir()]
        rom_inventory.append({"archive": filename, "sha256": sha256(target), "bytes": target.stat().st_size, "members": members})
    (ROOT / "docs" / "rom_manifest.json").write_text(json.dumps(rom_inventory, indent=2) + "\n", encoding="utf-8")
    exe = MAME_EXE
    outputs = {}
    for name, arguments in [("version", ["-version"]), ("listxml", ["crysking", "-listxml"]),
                            ("verifyroms", ["crysking", "-rompath", str(romdir), "-verifyroms"])]:
        run = subprocess.run([str(exe), *arguments], capture_output=True, timeout=60)
        (reference / f"mame_{name}.txt").write_bytes(run.stdout)
        (reference / f"mame_{name}.stderr.txt").write_bytes(run.stderr)
        outputs[name] = {"exit_code": run.returncode, "stdout_bytes": len(run.stdout), "stderr_bytes": len(run.stderr)}
    (reference / "MAME_COMMANDS.json").write_text(json.dumps({"executable": str(exe), "source": str(MAME), "commands": outputs}, indent=2) + "\n", encoding="utf-8")
    return {"reference_files": len(inventory), "roms": rom_inventory, "mame": outputs}


def main():
    local = stage_local()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        donors = list(executor.map(stage_donor, DONORS))
    (ROOT / "donors" / "manifest.json").write_text(json.dumps(donors, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"local_reference_files": local["reference_files"], "mame": local["mame"],
                      "donors": [{k: d[k] for k in ("name", "repository", "status", "revision", "files", "error") if k in d} for d in donors]}, indent=2))
    return int(any(d["status"] != "staged" for d in donors) or any(x["exit_code"] for x in local["mame"].values()))


if __name__ == "__main__":
    raise SystemExit(main())
