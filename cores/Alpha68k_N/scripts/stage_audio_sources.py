"""Reproduce the pinned audio imports and documented external AY adaptations."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REVISIONS = {
    "donors/jt12": "dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257",
    "donors/jt12/jt49": "7f6abfd08a2af9a92dbd5b32c71ea773248a77e2",
    "donors/jt49": "47301ed51374d6d41db4db846b7643fecf75e417",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    for folder, expected in REVISIONS.items():
        actual = subprocess.check_output(["git", "-C", folder, "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        if actual != expected:
            raise ValueError(f"unqualified donor revision: {folder}: {actual}")
    donor = ROOT / "donors/jt12"
    staged = ROOT / "rtl/vendor/jt12"
    planned, seen = [], set()

    def qip(path):
        if path in seen:
            return
        seen.add(path)
        planned.append((path, staged / path.relative_to(donor), path.read_bytes(), "byte-identical"))
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.search(r"-name (VERILOG_FILE|VHDL_FILE|QIP_FILE)\s+\[file join \$::quartus\(qip_path\)\s+([^\s\]]+)", line)
            if not match:
                raise ValueError("unparsed QIP line: " + line)
            source = (path.parent / match[2]).resolve()
            source.relative_to(donor.resolve())
            if match[1] == "QIP_FILE":
                qip(source)
            else:
                planned.append((source, staged / source.relative_to(donor), source.read_bytes(), "byte-identical"))

    qip(donor / "target/quartus/jt03.qip")
    for source in (donor / "LICENSE", donor / "jt49/LICENSE"):
        planned.append((source, staged / source.relative_to(donor), source.read_bytes(), "byte-identical"))
    # Preserve donor defaults; select a separate, uncompressed YMFM curve locally.
    ymfm_path = Path(r"D:\Arcade\AI\mame289\3rdparty\ymfm\src\ymfm_ssg.cpp")
    ymfm_bytes = ymfm_path.read_bytes()
    amplitude_block = re.search(r"s_amplitudes\[32\]\s*=\s*\{([^}]+)\}", ymfm_bytes.decode())
    amplitudes = [int(x) for x in re.findall(r"\d+", amplitude_block[1])]
    if len(amplitudes) != 32 or amplitudes[0] != 0 or amplitudes[-1] != 16382:
        raise ValueError("unqualified YMFM SSG amplitude table")
    ym_curve = [(x * 255 + 8191) // 16382 for x in amplitudes]
    adapted = []
    for source, output, data, adaptation in planned:
        text = data.decode() if output.suffix == ".v" else ""
        if output.name in ("jt03.v", "jt12_top.v", "jt49.v", "jt49_exp.v"):
            text = text.replace("\r\n", "\n")
        if output.name == "jt03.v":
            text = text.replace("parameter YM2203_LUMPED=0;", "parameter SSG_COMP=3'd1; // donor default; project can select YMFM curve 5\nparameter YM2203_LUMPED=0;", 1)
            text = text.replace(".YM2203_LUMPED(YM2203_LUMPED) )", ".SSG_COMP(SSG_COMP), .YM2203_LUMPED(YM2203_LUMPED) )", 1)
        elif output.name == "jt12_top.v":
            text = text.replace("parameter mask_div=1;", "parameter SSG_COMP=3'd1; // retain donor compression unless explicitly overridden\nparameter mask_div=1;", 1)
            text = text.replace(".COMP(3'b01)", ".COMP(SSG_COMP)", 1)
        elif output.name == "jt49.v":
            for index in (8, 9, 10):
                original = "{ regarray[%2d][3:0], regarray[%2d][3] }" % (index, index)
                if original not in text:
                    raise ValueError("YM fixed-volume integration changed")
                replacement = "(COMP == 3'd5 ? (regarray[%2d][3:0] == 0 ? 5'd0 : {regarray[%2d][3:0], 1'b1}) : %s)" % (index, index, original)
                text = text.replace(original, replacement, 1)
        elif output.name == "jt49_exp.v":
            text = text.replace("lut[0:159]", "lut[0:191]", 1)
            table = "// Project curve 5: MAME 0.289 YMFM SSG, normalized to eight bits.\n"
            table += "".join(f"    lut[{160+i}] = 8'd{v};\n" for i, v in enumerate(ym_curve))
            text = text.replace("\nend\nendmodule", "\n" + table + "end\nendmodule", 1)
            if not all(f"lut[{160+i}] = 8'd{v};" in text for i, v in enumerate(ym_curve)):
                raise ValueError("YMFM SSG table insertion failed")
        required = {"jt03.v": ".SSG_COMP(SSG_COMP)",
                    "jt12_top.v": ".COMP(SSG_COMP)",
                    "jt49.v": "COMP == 3'd5", "jt49_exp.v": "lut[0:191]"}
        if output.name in required and required[output.name] not in text:
            raise ValueError("YMFM SSG integration missing: " + output.name)
        if output.name in required:
            text = "\n".join(line.rstrip() for line in text.splitlines()) + "\n"
        if text and text.encode() != data:
            data = text.encode()
            adaptation = "Project SSG_COMP plumbing / curve 5 / YM fixed-volume indexing; donor defaults retained."
        adapted.append((source, output, data, adaptation))
    planned = adapted

    mame_path = Path(r"D:\Arcade\AI\mame289\src\devices\sound\ay8910.cpp")
    mame_bytes = mame_path.read_bytes()
    mame = mame_bytes.decode()
    start = mame.index("static const ay8910_device::ay_ym_param ay8910_param", mame.index("#endif", mame.index("#if 0")))
    block = mame[start:mame.index("};", start)]
    resistors = [15950,15350,15090,14760,14275,13620,12890,11370,10600,8590,7190,5985,4820,3945,3017,2345]
    if not all(str(value) in block for value in [800000,8000000,*resistors]):
        raise ValueError("MAME resistor model differs from the qualified input")

    def curve(envelope):
        values = []
        for level, resistance in enumerate(resistors):
            total, pullup = 1/8000000 + 1/1000 + 1/resistance, 1/resistance
            if envelope or level:
                total += 1/800000
                pullup += 1/800000
            values.append(pullup / total)
        low, high = min(values), max(values)
        return [round(255*(value-low)/(high-low)) for value in values]

    curves = [curve(False), curve(True)]
    names = ["jt49.v","jt49_bus.v","jt49_div.v","jt49_cen.v","jt49_eg.v","jt49_exp.v","jt49_noise.v"]
    for name in names:
        source = ROOT / "donors/jt49/hdl" / name
        planned.append((source, ROOT / "rtl/vendor/ay49/original" / name, source.read_bytes(), "byte-identical"))
        text = re.sub(r"\bjt49(?:_[A-Za-z0-9]+)?\b", lambda m: m[0].replace("jt49", "a68n_ay49", 1), source.read_text())
        if name == "jt49.v":
            for channel, index in zip("ABC", (8,9,10)):
                original = "{ regarray[%2d][3:0], regarray[%2d][3] }" % (index,index)
                if original not in text or f"use_env{channel} ? envelope : vol{channel}" not in text:
                    raise ValueError("external PSG volume integration changed")
                text = text.replace(original, "{ regarray[%2d][3:0], 1'b0 }" % index)
                text = text.replace(f"use_env{channel} ? envelope : vol{channel}", f"use_env{channel} ? {{envelope[4:1],1'b1}} : vol{channel}")
        if name == "jt49_eg.v":
            text = text.replace("always @(posedge clk) begin\n    if( restart ) rst_latch <= 1;", "always @(posedge clk, negedge rst_n) begin\n    if( !rst_n ) rst_latch <= 0;\n    else if( restart ) rst_latch <= 1;")
            text = text.replace("gain    <= 5'h1F;\n        inv", "last_step <= 0;\n        gain    <= 5'h1F;\n        inv", 1)
        if name == "jt49_exp.v":
            text = text[:text.index("module ")] + "// AY16 resistor transfer from MAME 0.289 legacy RL=1000.\n// din[0]: envelope/fixed curve. Legacy half-scale and offset belong in mixer.\nmodule a68n_ay49_exp(input clk,input [2:0] comp,input [4:0] din,output reg [7:0] dout);\nreg [7:0] lut[0:31];\nalways @(posedge clk) dout <= lut[din];\ninitial begin\n"
            text += "".join(f"    lut[{2*i+env}] = 8'd{curves[env][i]};\n" for i in range(16) for env in range(2)) + "end\nendmodule\n"
        output = ROOT / "rtl/vendor/ay49/hdl" / name.replace("jt49", "a68n_ay49")
        planned.append((source, output, text.encode(), "Namespace a68n_ay49; AY16 envelope/transfer and envelope reset; original retained."))
    source = ROOT / "donors/jt49/LICENSE"
    planned.append((source, ROOT / "rtl/vendor/ay49/LICENSE", source.read_bytes(), "byte-identical"))
    manifest = []
    for source, output, data, adaptation in planned:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)
        manifest.append({"origin": str(source.relative_to(ROOT)), "path": str(output.relative_to(ROOT)),
                         "origin_sha256": digest(source.read_bytes()), "staged_sha256": digest(data), "adaptation": adaptation})
    ym_license_source = ymfm_path.parent.parent / "LICENSE"
    ym_license_output = staged / "jt49/YMFM_LICENSE"
    ym_license_bytes = ym_license_source.read_bytes()
    ym_license_output.write_bytes(ym_license_bytes)
    manifest.append({"origin": str(ym_license_source), "path": str(ym_license_output.relative_to(ROOT)),
                     "origin_sha256": digest(ym_license_bytes), "staged_sha256": digest(ym_license_bytes),
                     "adaptation": "byte-identical; YMFM BSD-3-Clause notice for normalized SSG amplitude data"})
    record = {"donor_revisions": REVISIONS, "files": manifest, "license": "GPL-3.0-or-later donor code; YMFM data BSD-3-Clause; original notices/licenses retained",
              "ym_ssg_transfer": {"mame_source": str(ymfm_path), "sha256": digest(ymfm_bytes),
                                  "amplitudes_s16": amplitudes, "curve_u8": ym_curve,
                                  "selected_comp": 5, "donor_default_comp": 1,
                                  "credit": "YMFM, Copyright (c) 2021 Aaron Giles; jt49/YMFM_LICENSE",
                                  "scope": "YMFM unipolar curve; fixed volume n selects 2*n+1 except zero. Eight-bit amplitude quantization remains."},
              "ay_transfer": {"mame_source": str(mame_path), "sha256": digest(mame_bytes),
                              "fixed_u8": curves[0], "envelope_u8": curves[1],
                              "scope": "Normalized per-channel resistor curve; MAME half-scale and offset applied in mixer."}}
    (ROOT / "rtl/vendor/audio_sources.json").write_text(json.dumps(record, indent=2)+"\n", newline="\n")
    qip_text = "".join("set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) "+name+"]\n" for name in ("alpha68kn_soundchips.sv", "alpha68kn_mixer.sv", "alpha68kn_audio.sv"))
    qip_text += "set_global_assignment -name QIP_FILE [file join $::quartus(qip_path) vendor/jt12/target/quartus/jt03.qip]\n"
    qip_text += "".join("set_global_assignment -name VERILOG_FILE [file join $::quartus(qip_path) vendor/ay49/hdl/"+name.replace("jt49", "a68n_ay49")+"]\n" for name in names)
    (ROOT / "rtl/alpha68kn_audio.qip").write_text(qip_text, newline="\n")
    print(json.dumps({"staged_files": len(manifest), "ay_fixed": curves[0], "ay_envelope": curves[1]}))


if __name__ == "__main__":
    main()
