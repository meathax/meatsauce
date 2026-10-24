"""Generate an isolated Windows Quartus project from the NARC source snapshot.

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
CORE = "narc"
PROJECT = "jtnarc"

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


def stable_generated_ports(text: str) -> str:
    # JTFRAME emits these two unordered maps differently between invocations.
    # Declarations and named connections can be sorted without changing wiring.
    for pattern, declaration in (
        (r"(?m)^// Additional ports\n(?P<body>(?:wire[^\n]*\n)+)",
         r"wire\s+(?:\[[^\]]+\]\s*)?([A-Za-z_]\w*)\s*;\s*"),
        (r"(?m)^    // Ports declared in mem.yaml\n(?P<body>(?:    \.[^\n]*\n)+)",
         r"    \.([A-Za-z_]\w*)\s*\(\s*[A-Za-z_]\w*\s*\),\s*"),
    ):
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            raise RuntimeError("expected one generated port block")
        block = matches[0]
        lines = block.group("body").splitlines(keepends=True)
        parsed = [re.fullmatch(declaration, line) for line in lines]
        if not all(parsed) or len({match.group(1) for match in parsed}) != len(lines):
            raise RuntimeError("unsupported or duplicate generated port")
        ordered = "".join(line for _, line in sorted(
            (match.group(1), line) for match, line in zip(parsed, lines)
        ))
        text = text[:block.start("body")] + ordered + text[block.end("body"):]
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--jtframe", required=True, type=Path)
    parser.add_argument("--mame-xml", type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    snapshot = args.snapshot.resolve()
    tool = args.jtframe.resolve()
    if " " in str(snapshot):
        raise SystemExit("snapshot path must not contain spaces")
    if not (ROOT / "cores" / CORE).is_dir() or not (ROOT / "modules" / "jtframe").is_dir():
        raise SystemExit("NARC or JTFRAME source is missing")
    if tool.read_bytes()[:4] != b"\x7fELF":
        raise SystemExit("JTFRAME tool must be a Linux ELF")

    required = [snapshot / "cores" / CORE]
    required.extend(snapshot / "modules" / module for module in (
        "jtframe", "jt680x", "jt51", "jt12", "tms34010",
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
        (snapshot / "modules").mkdir()
        # JTFRAME resolves the core's dependencies from files.yaml and the JTFRAME
        # manifest. Keep the generation snapshot limited to those module trees.
        for module in ("jtframe", "jt680x", "jt51", "jt12", "tms34010"):
            shutil.copytree(
                ROOT / "modules" / module,
                snapshot / "modules" / module,
                symlinks=True,
                ignore=shutil.ignore_patterns(".git"),
            )

    # Q17 requires the reserved high ASCALE mode bit to be explicit.
    sys_top = snapshot / "modules" / "jtframe" / "target" / "mister" / "hdl" / "sys" / "sys_top.v"
    old_mode = ".mode     ({~lowlat,LFB_EN ? LFB_FLT : |scaler_flt,2'b00})"
    new_mode = ".mode     ({1'b0,~lowlat,LFB_EN ? LFB_FLT : |scaler_flt,2'b00})"
    sys_text = sys_top.read_text(encoding="utf-8")
    if sys_text.count(old_mode) == 1:
        write_utf8(sys_top, sys_text.replace(old_mode, new_mode))
    elif not (args.resume and sys_text.count(new_mode) == 1):
        raise RuntimeError("expected exactly one ASCALE mode connection")

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
        .replace("${DATE}", date.today().isoformat())
        .replace(f'PROJECT_REVISION = "jt{PROJECT}"', f'PROJECT_REVISION = "{PROJECT}"'),
    )
    run(["cfgstr", CORE, "--target=mister", "--output=quartus", "--nodbg"], "macros.qsf")
    run(["cfgstr", CORE, "--target=mister", "--output=cfgstr", "--nodbg"], "cfgstr.txt")
    if not (work / "cfgstr.hex").is_file():
        raise RuntimeError("JTFRAME cfgstr did not generate cfgstr.hex")

    qsf = work / f"{PROJECT}.qsf"
    text = qsf.read_text(encoding="utf-8")
    text += "\n" + (work / "macros.qsf").read_text(encoding="utf-8")
    text += f'\nset_global_assignment -name SEARCH_PATH "{snapshot / "cores" / CORE / "hdl"}"\n'
    # Keep singleton settings canonical before freezing the build inputs.
    for name, value in (
        ("SEED", "1"),
        ("COMPRESSION_MODE", "ON"),
        ("ON_CHIP_BITSTREAM_DECOMPRESSION", "ON"),
        ("TIMEQUEST_MULTICORNER_ANALYSIS", "ON"),
        ("LAST_QUARTUS_VERSION", '"17.0.2 Lite Edition"'),
        ("ALM_REGISTER_PACKING_EFFORT", "HIGH"),
    ):
        text = re.sub(
            rf"(?m)^\s*set_global_assignment\s+-name\s+{name}\s+[^\r\n]*\r?\n?",
            "", text,
        )
        text += f"set_global_assignment -name {name} {value}\n"
    # These serializer FFs otherwise route through fabric to the HDMI pads.
    for port in ("HDMI_I2S", "HDMI_LRCLK", "HDMI_SCLK"):
        text += f"set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to {port}\n"
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

    if args.mame_xml:
        run(["mra", CORE, "--mainonly"])

    wrapper = work / f"{PROJECT}_game_sdram.v"
    write_utf8(wrapper, stable_generated_ports(wrapper.read_text(encoding="utf-8")))

    # NARC-only physical board timing. Keep generated children in their actual
    # root groups before those collections are evaluated. The old SDRAM file
    # targets a controller hierarchy absent from this burst-controller profile.
    sys_sdc = snapshot / "modules/jtframe/target/mister/hdl/sys/sys_top.sdc"
    # A resume rebuilds this generated transform from its pinned source.
    content = (ROOT / "modules/jtframe/target/mister/hdl/sys/sys_top.sdc").read_text(encoding="utf-8")
    marker = "derive_pll_clocks\n"
    if content.count(marker) != 1:
        raise RuntimeError("unexpected framework clock-derivation anchor")
    board_clocks = (snapshot / "cores/narc/syn/board_clocks.sdc").read_text(encoding="utf-8")
    content = content.replace(marker, marker + board_clocks + "\n")
    groups = (
        ("*|pll|pll_inst|altera_pll_i|*[*].*|divclk", "NARC_SDRAM_PAD NARC_DB15 NARC_HDMI_NATIVE"),
        ("pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk", "NARC_HDMI_SCALED"),
        ("pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk", "NARC_AUDIO_MCLK"),
    )
    for root, children in groups:
        anchor = root + "}]"
        if content.count(anchor) != 1:
            raise RuntimeError("unexpected framework clock group: " + root)
        content = content.replace(anchor, root + " " + children + "}]")
    write_utf8(sys_sdc, content)
    files_qip = work / "files.qip"
    content = files_qip.read_text(encoding="utf-8")
    obsolete = [line for line in content.splitlines() if "sdram_clk96.sdc" in line]
    if len(obsolete) != 1:
        raise RuntimeError("expected one obsolete SDRAM constraint file")
    content = content.replace(obsolete[0] + "\n", "")
    board_io = windows_paths(str(snapshot / "cores/narc/syn/board_io.sdc"))
    content += f'set_global_assignment -name SDC_FILE "{board_io}"\n'
    write_utf8(files_qip, content)
    shutil.copy2(ROOT / "scripts/quartus_board_reports.tcl", work / "board_reports.tcl")
    shutil.copy2(ROOT / "scripts/quartus_dq_controls.tcl", work / "dq_controls.tcl")

    # Keep the programmer mux/zero arm ahead of the actual pad data FFs,
    # instead of extracting unsupported simultaneous SLOAD/SCLR controls.
    # The fabric-input trial failed; preserve the donor input-cell packing.
    sys_tcl = snapshot / "modules/jtframe/target/mister/hdl/sys/sys.tcl"
    content = (ROOT / "modules/jtframe/target/mister/hdl/sys/sys.tcl").read_text(encoding="utf-8")
    content += '\n# NARC data-register controls and HDMI clock/data balance.\n'
    content += 'set_instance_assignment -name ALLOW_SYNCH_CTRL_USAGE OFF -to *|dq_pad[*]\n'
    content += 'set_instance_assignment -name CURRENT_STRENGTH_NEW 16MA -to HDMI_TX_CLK\n'
    content += 'set_instance_assignment -name D5_DELAY 16 -to HDMI_TX_CLK\n'
    content += 'set_instance_assignment -name GLOBAL_SIGNAL "GLOBAL CLOCK" -to *|outclk_wire\\[3\\]\n'
    content += 'set_instance_assignment -name GLOBAL_SIGNAL "REGIONAL CLOCK" -to *|outclk_wire\\[5\\]\n'
    content += 'set_instance_assignment -name SLEW_RATE 1 -to SDRAM_CLK\n'
    write_utf8(sys_tcl, content)

    # Preserve raw project inputs so native metadata exports can be checked.
    project_inputs = snapshot / "project-inputs.json"
    write_utf8(project_inputs, json.dumps({
        suffix: (work / f"{PROJECT}.{suffix}").read_text(encoding="utf-8")
        for suffix in ("qpf", "qsf")
    }, indent=2) + "\n")
    manifest: dict[str, str] = {
        "project-inputs.json": hashlib.sha256(project_inputs.read_bytes()).hexdigest(),
    }
    for parent in (snapshot / "cores" / CORE, snapshot / "modules"):
        for path in sorted(parent.rglob("*")):
            if path.is_file() and ".git" not in path.parts:
                manifest[str(path.relative_to(snapshot))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(work.iterdir()):
        if path.is_file() and path.suffix.lower() in (".qpf", ".qsf", ".qip", ".hex", ".v", ".vh", ".txt", ".tcl", ".sdc"):
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
