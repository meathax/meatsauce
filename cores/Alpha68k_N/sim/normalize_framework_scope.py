"""Explicit simulation-only adapter for the pinned video_mixer generate scope.

Declares existing RGB inputs at module scope and retains each branch's exact
continuous assignment. No clocks, values, latency, registers, memories or
filters are replaced. FPGA sys/ source remains pinned and untouched.
"""
from pathlib import Path
import hashlib
import json
import sys

source, receipt = map(Path, sys.argv[1:])
original = source.read_bytes()
text = original.decode().replace("\r\n", "\n")
old = """generate
	if(GAMMA && HALF_DEPTH) begin
		wire [7:0] R_in  = frz ? 8'd0 : {R,R};
		wire [7:0] G_in  = frz ? 8'd0 : {G,G};
		wire [7:0] B_in  = frz ? 8'd0 : {B,B};
	end else begin
		wire [DWIDTH:0] R_in = frz ? 1'd0 : R;
		wire [DWIDTH:0] G_in = frz ? 1'd0 : G;
		wire [DWIDTH:0] B_in = frz ? 1'd0 : B;
	end
endgenerate"""
new = """wire [((GAMMA && HALF_DEPTH) ? 7 : DWIDTH):0] R_in,G_in,B_in;
generate
	if(GAMMA && HALF_DEPTH) begin
		assign R_in = frz ? 8'd0 : {R,R};
		assign G_in = frz ? 8'd0 : {G,G};
		assign B_in = frz ? 8'd0 : {B,B};
	end else begin
		assign R_in = frz ? 1'd0 : R;
		assign G_in = frz ? 1'd0 : G;
		assign B_in = frz ? 1'd0 : B;
	end
endgenerate"""
if text.count(old) != 1:
    raise SystemExit("Pinned framework scope adapter no longer matches source")
adapted = text.replace(old, new).encode()
source.write_bytes(adapted)
receipt.write_text(json.dumps({
    "scope": "temporary simulation source only; FPGA sys/ unchanged",
    "original_sha256": hashlib.sha256(original).hexdigest(),
    "adapted_sha256": hashlib.sha256(adapted).hexdigest(),
    "change": "move existing R_in/G_in/B_in net declarations to module scope; preserve branch assignments/widths",
    "limit": "does not qualify Quartus binding, timing, or hardware",
}, indent=2) + "\n")
