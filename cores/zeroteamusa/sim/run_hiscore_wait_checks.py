#!/usr/bin/env python3
"""Compile the actual hiscore wait predicate and prove its unsigned equivalence."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path("/mnt/r/Verilator/zero-hiscore-wait-checks")
build.mkdir(parents=True, exist_ok=True)
source = (root / "rtl/hiscore.v").read_text()
predicate = re.search(
    r"function automatic check_wait_elapsed;.*?endfunction", source, re.S
)
if predicate is None:
    raise RuntimeError("Actual RTL wait predicate not found")
harness = build / "hiscore_wait_checks.sv"
harness.write_text("""module hiscore_wait_predicate #(parameter RAM_READ_PIPELINED=0)
 (input [31:0] timer,previous_hold, input [15:0] hold_cycles, output ready);
""" + predicate.group() + """
assign ready = check_wait_elapsed(timer, hold_cycles, previous_hold);
endmodule
module hiscore_wait_checks(input [31:0] timer,previous_hold, input [15:0] hold_cycles,
 output ready_one, output ready_two);
hiscore_wait_predicate #(.RAM_READ_PIPELINED(0)) a(timer,previous_hold,hold_cycles,ready_one);
hiscore_wait_predicate #(.RAM_READ_PIPELINED(1)) b(timer,previous_hold,hold_cycles,ready_two);
endmodule
""")
log = root / "sim/results/hiscore-wait-build.log"
log.parent.mkdir(parents=True, exist_ok=True)
with log.open("w") as output:
    subprocess.run([
        "verilator", "--cc", "--exe", "--build", "-j", "4", "--no-timing",
        "--top-module", "hiscore_wait_checks", "--Mdir", str(build),
        str(harness), str(root / "sim/hiscore_wait_checks.cpp"),
        "-CFLAGS", "-std=c++17 -O2",
    ], stdout=output, stderr=subprocess.STDOUT, check=True)
subprocess.run([str(build / "Vhiscore_wait_checks")], check=True)
