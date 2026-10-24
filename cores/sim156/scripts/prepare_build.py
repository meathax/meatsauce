"""Audit the generated source boundary and write the complete queued RBF plan."""
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    # A source-only checkout has no generated output directories yet.
    (ROOT / "docs").mkdir(exist_ok=True)
    (ROOT / "build").mkdir(exist_ok=True)
    snapshot = Path(sys.argv[1]).resolve()
    work = snapshot / "project"
    project = "Arcade-SIMPLE156"
    qsf = work / f"{project}.qsf"
    qpf = work / f"{project}.qpf"
    qpf_text, revisions = re.subn(r'^PROJECT_REVISION\s*=.*$', f'PROJECT_REVISION = "{project}"', qpf.read_text(), flags=re.M)
    assert revisions == 1
    qpf.write_text(qpf_text)
    qip = work / "files.qip"
    qip_rows = qip.read_text().splitlines()
    assert sum("/syn/sys.qip" in row for row in qip_rows) == 1
    assert sum("/syn/pll7000.qip" in row for row in qip_rows) == 1
    assert sum("sdram_clk48.sdc" in row for row in qip_rows) == 1
    # The core declares the actual forwarded c0 source explicitly. The donor
    # selector mistakes active c1 capture for the forwarded pin driver.
    qip.write_text("\n".join(row for row in qip_rows if "sdram_clk48.sdc" not in row) + "\n")
    # Native stage plans do not run quartus_sh's pre-flow build-ID hook.
    (work / "build_id.v").write_text('`define BUILD_DATE "20261021"\n`define BUILD_TIME "000000"\n')
    text = qsf.read_text()
    initial_rows = text.splitlines()
    assert sum("QIP_FILE" in row and "sys/sys.qip" in row for row in initial_rows) <= 1
    text = "\n".join(row for row in initial_rows if not ("QIP_FILE" in row and "sys/sys.qip" in row)) + "\n"
    if not re.search(r"set_global_assignment -name SEED ", text):
        text += "set_global_assignment -name SEED 1\n"
    singleton = {"TIMEQUEST_MULTICORNER_ANALYSIS", "COMPRESSION_MODE", "ON_CHIP_BITSTREAM_DECOMPRESSION", "SEED"}
    rows = text.splitlines()
    last = {}
    for index, row in enumerate(rows):
        match = re.match(r'set_global_assignment -name (\w+) ', row)
        if match and match.group(1) in singleton:
            last[match.group(1)] = index
    text = "\n".join(row for index, row in enumerate(rows) if not (match := re.match(r'set_global_assignment -name (\w+) ', row)) or match.group(1) not in singleton or last[match.group(1)] == index) + "\n"
    # Follow creation of SDRAM_CLK with the core's physical I/O contract.
    if "sdram_io.sdc" not in text:
        text += f'\nset_global_assignment -name SDC_FILE "{snapshot.as_posix()}/cores/osman/syn/sdram_io.sdc"\n'
    text = "\n".join(row for row in text.splitlines() if not ("FAST_INPUT_REGISTER" in row and ("u_core|dq_ff" in row or "dq_capture" in row))) + "\n"
    fast_input = 'set_instance_assignment -name FAST_INPUT_REGISTER ON -to "SDRAM_DQ[*]"'
    if fast_input not in text:
        text += fast_input + "\n"
    # Qualify both sides: fast clock and command/address/DQM output pads.
    # Keep the external timing contract; refit the physical clock output instead.
    text, count = re.subn(r'^(set_instance_assignment -name SLEW_RATE )0( -to SDRAM_[^\n]+)$', r'\g<1>1\2', text, flags=re.M)
    assert count == 10, "expected ten donor SDRAM clock/control slew assignments"
    qsf.write_text(text)
    for macro in ("JTFRAME_RELEASE=1", "JTFRAME_OSD_NOLOGO=1", "JTFRAME_NOMRA_DIP=1", "JTFRAME_OSD_HU_LAYOUT=1"):
        assert f'"{macro}"' in text, macro
    assert '"JTFRAME_CREDITS=1"' not in text, "credits still enabled"
    assert '"JTFRAME_MCLK=56000000"' in text
    for macro in ("JTFRAME_SHIFT=1", "JTFRAME_180SHIFT=1", "JTFRAME_DQ_CAPTURE=1", "JTFRAME_SDRAM_HF=1", "JTFRAME_SDRAM_INIT_CYCLES=12000"):
        assert f'"{macro}"' in text, macro
    assert "COMPRESSION_MODE ON" in text and "ON_CHIP_BITSTREAM_DECOMPRESSION ON" in text
    menu = bytes.fromhex((work / "cfgstr.hex").read_text()).rstrip(b'\0').decode()
    assert "P1,Video Settings;" in menu and "P2,Game Settings;" in menu
    assert "Service mode" in menu and "R0,Reset;" in menu
    assert "credits" not in menu.lower() and "DIP;" not in menu
    (work / "cfgstr-decoded.txt").write_text(menu)
    paths = []
    for row in (work / "files.qip").read_text().splitlines():
        match = re.match(r'set_global_assignment .*?-name (?:VERILOG_FILE|SYSTEMVERILOG_FILE|VHDL_FILE|QIP_FILE|SDC_FILE) (.*)', row)
        if not match:
            continue
        file = Path(match.group(1).strip().strip('"{}'))
        if not file.is_absolute():
            file = work / file
        assert file.is_file(), f"source missing: {file}"
        paths.append(str(file))
    # Establish the actual generated clock source, rather than inferring it from a macro name.
    evidence = []
    for file in (snapshot / "modules" / "jtframe" / "target" / "mister" / "hdl").rglob("*"):
        if file.is_file() and file.suffix in (".v", ".sv") and ("pll7000" in str(file) or file.name == "jtframe_mister.v"):
            for number, row in enumerate(file.read_text(errors="replace").splitlines(), 1):
                if re.search(r'output_clock_frequency|phase_shift|assign clk_|outclk_[0-9]|clk_video\s*=|clk_sys\s*=', row):
                    evidence.append(f"{file.relative_to(snapshot)}:{number}: {row.strip()}")
    out = ROOT / "docs" / "preflight.json"
    report = {"source_files": len(paths), "menu": menu, "qsf_sha256": hashlib.sha256(qsf.read_bytes()).hexdigest(), "clock_source": evidence}
    out.write_text(json.dumps(report, indent=2) + "\n")
    platform_plls = snapshot / "modules/jtframe/target/mister/hdl/sys/pll_q17.qip"
    pll_rows = platform_plls.read_text().splitlines()
    assert sum("rtl/pll.qip" in row for row in pll_rows) == 1
    platform_plls.write_text("\n".join(row for row in pll_rows if "rtl/pll.qip" not in row) + "\n")
    system_tcl = snapshot / "modules/jtframe/target/mister/hdl/sys/sys.tcl"
    system_rows = system_tcl.read_text().splitlines()
    assert sum("QIP_FILE sys/sys.qip" in row for row in system_rows) == 1
    system_tcl.write_text("\n".join(row for row in system_rows if "QIP_FILE sys/sys.qip" not in row) + "\n")
    manifest_file = snapshot / "source-manifest.json"
    manifest = json.loads(manifest_file.read_text())
    for file in (qsf, qpf, work / "build_id.v", qip, platform_plls, system_tcl):
        manifest[file.relative_to(snapshot).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")
    quartus = Path("D:/q17/quartus/bin64")
    steps = []
    for stage in ("map", "fit", "sta"):
        command = [str(quartus / f"quartus_{stage}.exe"), project, "-c", project]
        if stage in ("map", "fit"):
            command += ["--read_settings_files=on", "--write_settings_files=off"]
        steps.append({"command": command})
    steps.append({"command": [str(quartus / "quartus_sta.exe"), "-t", str(ROOT / "scripts" / "qualify.tcl")]})
    steps.append({"command": [sys.executable, str(ROOT / "scripts" / "verify_timing.py"), str(work / "output_files" / f"{project}.sta.rpt")]})
    steps.append({"command": [str(quartus / "quartus_asm.exe"), project, "-c", project, "--read_settings_files=on", "--write_settings_files=off"]})
    steps.append({"command": [str(quartus / "quartus_cpf.exe"), "-c", "-o", "bitstream_compression=on", f"output_files/{project}.sof", f"output_files/{project}.rbf"]})
    plan = {"cwd": str(work), "steps": steps}
    destination = ROOT / "build" / "rbf-plan.json"
    destination.write_text(json.dumps(plan, indent=2) + "\n")
    print(json.dumps({"plan": str(destination), "source_files": len(paths), "menu": menu, "clock_evidence": str(out)}, indent=2))

if __name__ == "__main__":
    main()
