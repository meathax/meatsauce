"""Compile the production I2S CE generator verbatim, then check its pin phases."""
from pathlib import Path
import hashlib
import os
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / "sys/audio_out.sv").read_text()
generator = source[source.index("localparam AUDIO_RATE"):source.index("i2s i2s")]
target = root / "sim/results/timing/audio_phase_top.sv"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text("""module timing_audio_phase(
input clk, reset, sample_rate,
input [15:0] left_chan, right_chan,
output sclk, lrclk, sdata);
localparam CLK_RATE = 24576000;
""" + generator + """
i2s i2s(.reset(reset),.clk(clk),.ce(i2s_ce),
    .left_chan(left_chan),.right_chan(right_chan),
    .sclk(sclk),.lrclk(lrclk),.sdata(sdata));
endmodule
""")
print("Production CE generator sha256=" + hashlib.sha256(generator.encode()).hexdigest())
if os.name == "nt":
    raise SystemExit(subprocess.call([
        "wsl.exe", "-d", "Ubuntu", "--cd", str(root), "--exec", "python3",
        "sim/run_timing_audio_phase.py",
    ]))
identity = hashlib.sha256(generator.encode())
for dependency in (root / "sys/i2s.v", root / "sim/timing_audio_phase.cpp"):
    identity.update(dependency.read_bytes())
build_root = Path(os.environ.get("VERILATOR_BUILD_ROOT", "/mnt/r/Verilator"))
build_dir = build_root / ("zero-timing-audio-" + identity.hexdigest()[:16])
build_log = target.parent / "audio-phase-build.log"
with build_log.open("w") as log:
    code = subprocess.call([
        "verilator", "--cc", "--exe", "--build", "-j", "2",
        "--top-module", "timing_audio_phase", "-Wno-fatal",
        "--Mdir", str(build_dir), str(target), str(root / "sys/i2s.v"),
        str(root / "sim/timing_audio_phase.cpp"),
    ], cwd=root, stdout=log, stderr=subprocess.STDOUT)
if code:
    print("\n".join(build_log.read_text().splitlines()[-8:]))
    raise SystemExit(code)
result = subprocess.run([str(build_dir / "Vtiming_audio_phase")],
                        cwd=root, capture_output=True, text=True)
(target.parent / "audio-phase-run.log").write_text(result.stdout + result.stderr)
print(result.stdout + result.stderr, end="")
raise SystemExit(result.returncode)
