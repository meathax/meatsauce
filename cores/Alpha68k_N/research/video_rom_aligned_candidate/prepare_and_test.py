"""Stage a cycle-aligned video memory candidate and compare the real RTL."""
from pathlib import Path
import hashlib
import json
import subprocess
import difflib

STAGE = Path(__file__).resolve().parent
SOURCE = Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\rtl\alpha68kn_video_rom.sv")
TOOLS = Path(r"D:\vibes\fpga\toolchains\msys64\ucrt64\bin")
expected = "b000479a8d41ac4d17fcd60fc129912c6a437cf2f690873fc7d62aac4094d10e"
raw = SOURCE.read_bytes()
assert hashlib.sha256(raw).hexdigest() == expected
source = raw.decode().replace("\r\n", "\n")
candidate = source
edits = [
    ("output reg [7:0] color_data", "output wire [7:0] color_data"),
    ("output reg [23:0] rgb", "output wire [23:0] rgb"),
    ("    reg [7:0] indirect;\n    wire [15:0] lo=clut_lo[pen[7:1]],hi=clut_hi[pen[7:1]];\n    wire [15:0] r=red[indirect[7:1]],g=green[indirect[7:1]],b=blue[indirect[7:1]];",
     "    // Full-word synchronous reads; aligned selectors preserve each original cycle.\n    reg [15:0] color_q,lo,hi,r,g,b;\n    reg color_lane,pen_lane,pen_background,rgb_lane;\n    reg [7:0] background_q;\n    wire [7:0] indirect=pen_background ? background_q :\n        pen_lane ? {hi[11:8],lo[11:8]} : {hi[3:0],lo[3:0]};\n    assign color_data=color_lane ? color_q[15:8] : color_q[7:0];"),
    ("wire [3:0] rn=indirect[0]?", "wire [3:0] rn=rgb_lane?"),
    ("wire [3:0] gn=indirect[0]?", "wire [3:0] gn=rgb_lane?"),
    ("wire [3:0] bn=indirect[0]?", "wire [3:0] bn=rgb_lane?"),
    ("    wire [15:0] debug_clut=", "    assign rgb={rn,rn,gn,gn,bn,bn};\n    wire [15:0] debug_clut="),
    ("        color_data<=color_addr[0]?color_rom[color_addr[12:1]][15:8]:color_rom[color_addr[12:1]][7:0];\n        indirect<=pen[8] ? background :\n            pen[0] ? {hi[11:8],lo[11:8]} : {hi[3:0],lo[3:0]};\n        rgb<={rn,rn,gn,gn,bn,bn};",
     "        color_q<=color_rom[color_addr[12:1]];\n        color_lane<=color_addr[0];\n        lo<=clut_lo[pen[7:1]];\n        hi<=clut_hi[pen[7:1]];\n        pen_lane<=pen[0];\n        pen_background<=pen[8];\n        background_q<=background;\n        r<=red[indirect[7:1]];\n        g<=green[indirect[7:1]];\n        b<=blue[indirect[7:1]];\n        rgb_lane<=indirect[0];"),
]
for old, new in edits:
    assert candidate.count(old) == 1, old
    candidate = candidate.replace(old, new)
(STAGE / "alpha68kn_video_rom.sv").write_text(candidate, newline="\n")
(STAGE / "original_video_rom.sv").write_text(source.replace("module alpha68kn_video_rom (", "module original_video_rom ("), newline="\n")
patch = "".join(difflib.unified_diff(source.splitlines(True), candidate.splitlines(True), fromfile="a/rtl/alpha68kn_video_rom.sv", tofile="b/rtl/alpha68kn_video_rom.sv"))
(STAGE / "video_rom.patch").write_text(patch, newline="\n")
compile_cmd = [str(TOOLS / "iverilog.exe"), "-g2012", "-s", "video_rom_miter_tb", "-o", str(STAGE / "miter.vvp"), str(STAGE / "original_video_rom.sv"), str(STAGE / "alpha68kn_video_rom.sv"), str(STAGE / "video_rom_miter_tb.sv")]
compiled = subprocess.run(compile_cmd, capture_output=True, text=True)
receipt = {"source_sha256": expected, "compile_command": compile_cmd, "compile_exit": compiled.returncode, "compile_stderr": compiled.stderr, "scope": "Original versus candidate complete video-ROM RTL, cycle-aligned outputs including runtime loader collisions; no synthesis or actual-game claim"}
if compiled.returncode == 0:
    run = subprocess.run([str(TOOLS / "vvp.exe"), str(STAGE / "miter.vvp")], capture_output=True, text=True)
    receipt.update(run_exit=run.returncode, run_stdout=run.stdout, run_stderr=run.stderr)
receipt["files"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in STAGE.iterdir() if p.suffix in (".sv", ".py", ".patch")}
(STAGE / "miter_exit.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({k: v for k, v in receipt.items() if k not in ("files", "compile_command")}))
assert compiled.returncode == 0
assert receipt["run_exit"] == 0
assert "PASS video ROM cycle miter 131072" in receipt["run_stdout"]
