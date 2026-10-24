"""Generate an isolated Windows Quartus project from the Simple156 source snapshot.

Run this helper in Ubuntu WSL. It only generates project files; native Quartus
work must subsequently use the machine-wide fpga_mcp queue.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from datetime import date


ROOT = Path(__file__).resolve().parents[1]
CORE = "osman"
PROJECT = "Arcade-SIMPLE156"

SOURCE_ASSIGNMENT = re.compile(
    r"(?im)^(\s*set_global_assignment\s+-name\s+"
    r"(?:VERILOG_FILE|SYSTEMVERILOG_FILE|VHDL_FILE|AHDL_FILE|QIP_FILE|SDC_FILE|"
    r"MIF_FILE|HEX_FILE|SOURCE_FILE)\s+)\{([^{}\r\n]*)\}(\s*(?:#.*)?)$"
)


def windows_paths(text: str) -> str:
    return text.replace("/mnt/d/", "D:/").replace("/mnt/c/", "C:/")


def write_utf8(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--jtframe", required=True, type=Path)
    parser.add_argument("--mame-xml", type=Path)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--preseeded", action="store_true", help="source trees were freshly copied by seed_snapshot.py")
    args = parser.parse_args()

    snapshot = args.snapshot.resolve()
    tool = args.jtframe.resolve()
    if " " in str(snapshot):
        raise SystemExit("snapshot path must not contain spaces")
    if not (ROOT / "cores" / CORE).is_dir() or not (ROOT / "modules" / "jtframe").is_dir():
        raise SystemExit("Osman or JTFRAME source is missing")
    if tool.read_bytes()[:4] != b"\x7fELF":
        raise SystemExit("JTFRAME tool must be a Linux ELF")

    required = [snapshot / "cores" / CORE]
    required.extend(snapshot / "modules" / module for module in (
        "jtframe", "jt6295", "jteeprom",
    ))
    if snapshot.exists():
        if not args.resume:
            raise SystemExit(f"refusing to overwrite existing snapshot: {snapshot}")
        missing = [str(path) for path in required if not path.is_dir()]
        if missing:
            raise SystemExit(f"cannot resume incomplete snapshot; missing: {missing}")
    else:
        if args.resume:
            raise SystemExit(f"cannot resume missing snapshot: {snapshot}")
        snapshot.mkdir(parents=True)
        shutil.copytree(ROOT / "cores" / CORE, snapshot / "cores" / CORE, symlinks=True)
        for donor in ("cninja",):
            shutil.copytree(ROOT / "cores" / donor, snapshot / "cores" / donor, symlinks=True)
        (snapshot / "modules").mkdir()
        # JTFRAME resolves the core's dependencies from files.yaml and the JTFRAME
        # manifest. Keep the generation snapshot limited to those module trees.
        for module in ("jtframe", "jt6295", "jteeprom"):
            shutil.copytree(
                ROOT / "modules" / module,
                snapshot / "modules" / module,
                symlinks=True,
                ignore=shutil.ignore_patterns(".git"),
            )

    # Refresh reviewed source changes when resuming an existing generated snapshot.
    if args.preseeded and (snapshot / "project" / "generation.json").exists():
        raise RuntimeError("--preseeded requires a fresh snapshot, not an existing generation")
    changed = [] if args.preseeded else subprocess.check_output(
        ["git", "-C", str(ROOT), "diff", "--name-only"], text=True,
    ).splitlines()
    for relative in changed:
        source = ROOT / relative
        destination = snapshot / relative
        if relative.startswith(("cores/", "modules/")) and source.is_file() and destination.exists():
            shutil.copy2(source, destination)

    # Git for Windows may check out mode-120000 links as small text files.
    # Resolve only links belonging to this snapshot, within the imported repository.
    entries = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-s"], text=True,
    ).splitlines()
    for entry in entries:
        if not entry.startswith("120000 "):
            continue
        relative = entry.split("\t", 1)[1]
        if not relative.startswith((
            "modules/jtframe/target/mister/", "modules/jtframe/hdl/",
            "cores/osman/hdl/", "cores/osman/syn/", "cores/cninja/hdl/",
        )):
            continue
        source = ROOT / relative
        destination = snapshot / relative
        if not destination.exists() or not destination.is_file():
            continue
        link = source.readlink() if source.is_symlink() else Path(source.read_text().strip())
        referent = (source.parent / link).resolve()
        if not referent.is_relative_to(ROOT) or not referent.exists():
            raise RuntimeError(f"unavailable imported dependency: {relative} -> {link}")
        destination.unlink()
        if referent.is_dir():
            shutil.copytree(referent, destination, symlinks=True)
        else:
            shutil.copy2(referent, destination)
        print(f"Resolved dependency: {relative} -> {link}", flush=True)

    source_commit = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if re.fullmatch(r"[0-9a-fA-F]{40}", source_commit) is None:
        raise RuntimeError(f"invalid source commit id: {source_commit!r}")
    subprocess.run(["git", "-C", str(snapshot), "init", "--quiet"], check=True)
    with (snapshot / ".git" / "HEAD").open("w", encoding="ascii", newline="\n") as stream:
        stream.write(source_commit + "\n")
    snapshot_commit = subprocess.run(
        ["git", "-C", str(snapshot), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    if snapshot_commit.lower() != source_commit.lower():
        raise RuntimeError("snapshot Git HEAD does not match source checkout")

    doc = snapshot / "doc"
    (doc / "mame").mkdir(parents=True, exist_ok=True)
    if args.mame_xml:
        mame_xml = args.mame_xml.resolve()
        shutil.copy2(mame_xml, doc / "mame.xml")
        shutil.copy2(mame_xml, doc / "mame" / "mame.xml")

    work = snapshot / "project"
    work.mkdir(exist_ok=True)
    env = dict(os.environ,
        JTROOT=str(snapshot),
        JTFRAME=str(snapshot / "modules" / "jtframe"),
        MODULES=str(snapshot / "modules"),
        CORES=str(snapshot / "cores"),
        ROM=str(snapshot / "rom"),
        RLS=str(snapshot / "release"),
        MRA=str(snapshot / "release" / "mra"),
        JTBIN=str(snapshot / "release"),
        MAME=str(doc / "mame"),
    )
    receipt_file = work / "generation.json"
    receipts: list[dict[str, object]] = (
        json.loads(receipt_file.read_text(encoding="utf-8"))
        if receipt_file.is_file() else []
    )
    if args.resume:
        for path in work.iterdir():
            if path == receipt_file:
                continue
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        release = snapshot / "release"
        if release.exists():
            shutil.rmtree(release)

    def run(arguments: list[str], output: str | None = None) -> str:
        result = subprocess.run(
            [str(tool), *arguments], cwd=work, env=env,
            capture_output=True, text=True,
        )
        receipts.append({
            "arguments": arguments,
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        })
        write_utf8(work / "generation.json", json.dumps(receipts, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(
                f"JTFRAME command failed: {arguments}\n"
                f"stdout:\n{result.stdout[-4000:]}\n"
                f"stderr:\n{result.stderr[-4000:]}"
            )
        if output:
            write_utf8(work / output, result.stdout)
        return result.stdout

    # MRA generation emits jtosman_header.v, required by files.yaml.
    if args.mame_xml:
        run(["mra", CORE, "--mainonly", "--skipROM", "--skipPocket"])
    run(["mem", CORE, "--target=mister", "--local", "--nodbg"])
    run(["mmr", CORE])
    run(["files", "syn", CORE, "--target=mister", "--local"])
    template = snapshot / "modules" / "jtframe" / "target" / "mister"
    for suffix in ("qpf", "qsf"):
        run([
            "parse", CORE, str(template / f"mister.{suffix}"),
            "--target=mister", "--output", str(work / f"{PROJECT}.{suffix}"),
        ])

    qpf = work / f"{PROJECT}.qpf"
    write_utf8(
        qpf,
        qpf.read_text(encoding="utf-8")
        .replace("${CORENAME}", PROJECT)
        .replace("${DATE}", date.today().isoformat()),
    )
    run(["cfgstr", CORE, "--target=mister", "--output=quartus", "--nodbg"], "macros.qsf")
    run(["cfgstr", CORE, "--target=mister", "--output=cfgstr", "--nodbg"])
    if not (work / "cfgstr.hex").is_file():
        raise RuntimeError("JTFRAME cfgstr did not generate cfgstr.hex")

    qsf = work / f"{PROJECT}.qsf"
    text = qsf.read_text(encoding="utf-8")
    text += "\n" + (work / "macros.qsf").read_text(encoding="utf-8")
    text += f'\nset_global_assignment -name SEARCH_PATH "{snapshot / "cores" / CORE / "hdl"}"\n'
    text += "set_global_assignment -name SEED 1\n"
    text += "set_global_assignment -name COMPRESSION_MODE ON\n"
    text += "set_global_assignment -name ON_CHIP_BITSTREAM_DECOMPRESSION ON\n"
    text += "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS ON\n"
    write_utf8(qsf, text)

    for directory in (
        snapshot / "cores" / CORE / "hdl",
        snapshot / "modules" / "jtframe" / "hdl" / "sound",
        snapshot / "modules" / "jtframe" / "hdl" / "video",
        snapshot / "modules" / "jtframe" / "bin",
    ):
        if not directory.is_dir():
            continue
        for source in directory.glob("*.hex"):
            target = work / source.name
            if target.exists():
                if target.read_bytes() != source.read_bytes():
                    raise RuntimeError(f"conflicting initialization file: {source}")
            else:
                shutil.copy2(source, target)

    for path in work.iterdir():
        if path.suffix.lower() not in (".qpf", ".qsf", ".qip"):
            continue
        content = windows_paths(path.read_text(encoding="utf-8"))
        content = SOURCE_ASSIGNMENT.sub(r'\1"\2"\3', content)
        write_utf8(path, content)
        if path.read_bytes().startswith(b"\xef\xbb\xbf"):
            raise RuntimeError(f"unexpected UTF-8 BOM: {path}")

    manifest: dict[str, str] = {}
    for parent in (snapshot / "cores" / CORE, snapshot / "modules"):
        for path in sorted(parent.rglob("*")):
            if path.is_file() and ".git" not in path.parts:
                manifest[str(path.relative_to(snapshot))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(work.iterdir()):
        if path.is_file() and path.suffix.lower() in (".qpf", ".qsf", ".qip", ".hex", ".v", ".vh", ".txt"):
            manifest[str(path.relative_to(snapshot))] = hashlib.sha256(path.read_bytes()).hexdigest()
    write_utf8(snapshot / "source-manifest.json", json.dumps(manifest, indent=2) + "\n")

    mras = sorted(str(path) for path in (snapshot / "release" / "mra").rglob("*.mra"))
    print(json.dumps({
        "project": str(qpf).replace("/mnt/d/", "D:/").replace("/mnt/c/", "C:/"),
        "snapshot": str(snapshot),
        "source_files_hashed": len(manifest),
        "mra_files": mras,
        "compiler_invoked": False,
    }, indent=2))


if __name__ == "__main__":
    main()
