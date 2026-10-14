"""Verify development frontend wiring and MRA; this is not game acceptance."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import mra
import sim

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim/obj_dir/mister_verify"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    descriptor = ROOT / "releases/The Crystal of Kings.mra"
    tree = ET.parse(descriptor).getroot()
    assembled = mra.build_image(descriptor, [ROOT / "roms/crysking.zip", ROOT / "roms/crysbios.zip"])
    expected = (ROOT / "roms/images/crysking.bin").read_bytes() + (ROOT / "roms/images/bios.bin").read_bytes()
    assert tree.find("rom").get("address") == "0x30000000", "MRA must load the image directly into DDR3"
    assert assembled == expected, "MRA stream differs from the audited simulation images"
    assert tree.find("switches").get("default") == "FF"
    dips = tree.findall("switches/dip")
    assert {int(d.get("bits")) for d in dips} == set(range(8))
    assert all(d.get("ids") == "On,Off" for d in dips)
    assert all(2 + len(d.get("name")) + 3 <= 28 for d in dips)
    driver = (ROOT / "docs/reference/mame/src/mame/misc/crystal.cpp").read_text()
    ports = driver.split("INPUT_PORTS_START( crystal )", 1)[1].split("INPUT_PORTS_END", 1)[0]
    masks = re.findall(r"PORT_DIPNAME\(\s*(0x\w+),\s*(0x\w+),", ports)
    assert [(int(m, 16), int(v, 16)) for m, v in masks] == [(1 << i, 1 << i) for i in range(8)]
    assert 'PORT_SERVICE_NO_TOGGLE( 0x80, IP_ACTIVE_LOW )' in ports
    names = tree.find("buttons").get("names")
    assert names in (ROOT / "CrystalSystem.sv").read_text()
    assert not re.search(r"Button\s*\d", names, re.I)
    assert tree.find("nvram").attrib == {"index": "4", "size": "65536"}
    framework_diff = subprocess.run(["git", "diff", "HEAD", "--", "sys"], cwd=ROOT, capture_output=True, text=True)
    assert framework_diff.returncode == 0 and not framework_diff.stdout, "sys/ changed"
    qsf = (ROOT / "CrystalSystem.qsf").read_text()
    assert '\nset_global_assignment -name VERILOG_MACRO "MISTER_FB=1"' in qsf
    assert not re.search(r'^set_global_assignment.*MISTER_DISABLE_YC', qsf, re.M)
    assert '.output_clock_frequency0("85.909080 MHz")' in (ROOT / "rtl/pll/pll_0002.v").read_text()
    # Port/type lint uses genuine video framework RTL, with explicitly bounded
    # black boxes for HPS transport and the unsimulatable Intel PLL primitive.
    header = (ROOT / "sys/hps_io.sv").read_text().split('module hps_io', 1)[1].split('\n);', 1)[0]
    port_params = '\n'.join(re.findall(r'localparam\s+(?:DW|VD|AW)\s*=[^;]+;', (ROOT / 'sys/hps_io.sv').read_text()))
    (OUT / "hps_stub.sv").write_text('module hps_io' + header + '\n);\n' + port_params + '\nendmodule\n')
    (OUT / "pll_stub.sv").write_text('module pll(input refclk,rst,output outclk_0,outclk_1,locked); assign outclk_0=refclk; assign outclk_1=refclk; assign locked=~rst; endmodule\n')
    (OUT / "altddio_stub.sv").write_text('module altddio_out #(parameter width=1,parameter intended_device_family="",parameter power_up_high="",parameter oe_reg="")(input outclock,outclocken,input [width-1:0] datain_h,datain_l,input aclr,aset,sclr,sset,oe,output [width-1:0] dataout,output oe_out); assign dataout=datain_h; assign oe_out=oe; endmodule\n')
    (OUT / "build_id.v").write_text('`define BUILD_DATE "verification"\n')
    env = os.environ.copy()
    env["PATH"] = str(sim.MSYS / "ucrt64/bin") + os.pathsep + str(sim.MSYS / "usr/bin") + os.pathsep + env.get("PATH", "")
    env["VERILATOR_PROJECT"] = "CrystalSystem"
    allocation = subprocess.run([str(sim.VERILATOR), "workspace"], cwd=ROOT, env=env, capture_output=True, text=True, check=True)
    env["VERILATOR_WORKSPACE"] = allocation.stdout.strip()
    files = list(dict.fromkeys([ROOT / "CrystalSystem.sv", *[ROOT / f for f in sim.TARGETS["host_boot"]["files"]], ROOT / "rtl/memory/cs_ddr_share.sv", ROOT / "rtl/board/cs_nvram_host.sv", *sorted((ROOT / "rtl/video").glob("cs_*.sv")), ROOT / "rtl/board/cs_mister_controls.sv", ROOT / "rtl/audio/cs_audio_interp.sv", ROOT / "credits/rtl/credits_overlay.sv", ROOT / "credits/generated/credits_rom.sv", OUT / "hps_stub.sv", OUT / "pll_stub.sv", OUT / "altddio_stub.sv", ROOT / "sys/arcade_video.v", ROOT / "sys/math.sv"]))
    model_dir = Path(env["VERILATOR_WORKSPACE"]) / "obj_dir"
    model_dir.mkdir(parents=True, exist_ok=True)
    # Module names differ from their framework filenames on case-sensitive tools.
    for module in ["Hq2x", "sync_fix"]:
        matches = [p for p in (ROOT / "sys").iterdir() if p.suffix in (".v", ".sv") and re.search(r"module\s+" + module + r"\b", p.read_text(errors="replace"))]
        assert matches, f"Missing framework module: {module}"
        for match in matches:
            if match not in files: files.append(match)
    command = [str(sim.VERILATOR), "--lint-only", "--Mdir", model_dir.as_posix(), "--top-module", "emu", "-Wno-fatal", "-Wno-PINMISSING", "-Wno-PROCASSWIRE", "--bbox-unsup", "-DMISTER_FB", "-I" + OUT.as_posix(), "-I" + ROOT.as_posix(), "-I" + (ROOT / "credits/generated").as_posix(), "-y", (ROOT / "sys").as_posix(), "+libext+.v+.sv", *(p.as_posix() for p in files)]
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    (OUT / "lint.log").write_text(result.stdout + result.stderr)
    reports = [json.loads((ROOT / f"docs/simulation_mister_{t}.json").read_text()) for t in ["controls", "nvram", "video", "rotate", "scale"]]
    reports += [json.loads((ROOT / f"docs/simulation_{t}.json").read_text()) for t in ["ddr_share", "nvram_host"]]
    for report in reports:
        for source in report["sources"]:
            assert hashlib.sha256((ROOT / source["path"]).read_bytes()).hexdigest() == source["sha256"], f"Stale test: {source['path']}"
    report = {"scope": "connected physical-board MiSTer wrapper port lint and focused interface regressions; not full-game or physical pin timing acceptance", "mra_bytes": len(assembled), "mra_sha256": hashlib.sha256(assembled).hexdigest(), "mra_equals_audited_bios_and_patched_cartridge": True, "dip_pins_checked_against_pinned_MAME": True, "sys_unchanged": True, "native_refresh_target_hz": 85909080 / 1430520, "physical_PLL_and_sync_unverified": True, "wrapper_lint_exit": result.returncode, "wrapper_lint_limit": "HPS/PLL black boxes; genuine video framework RTL; legacy hq2x procedural-wire diagnostic suppressed; no FPGA synthesis", "wrapper_lint_log": str((OUT / "lint.log").relative_to(ROOT)), "unit_exits": {r["target"]: r["exit_code"] for r in reports}, "game_boot_complete": False, "game_highscore_persistence_verified": False, "rbf_built": False}
    (ROOT / "docs/mister_feature_verification.json").write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if result.returncode:
        print('\n'.join(l for l in (result.stdout + result.stderr).splitlines() if '%Error' in l))
    return int(result.returncode != 0 or any(r["exit_code"] for r in reports))


if __name__ == "__main__":
    raise SystemExit(main())
