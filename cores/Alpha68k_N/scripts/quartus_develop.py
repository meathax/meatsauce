"""Retired queued preassembly entrypoint; use the visible reviewed frontend."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if __name__ == "__main__":
    project = ROOT / "Alpha68k_N.qpf"
    sys.stderr.write(
        "This obsolete queued preassembly entrypoint is retired. "
        "Prepare/review the immutable check project and Template build-ID/microcode "
        "prerequisites as documented in docs/LOADER_AND_CLOCKS.md, then invoke "
        "C:\\Users\\meath\\QuartusFast\\quartus-fast.ps1 build --project "
        + str(project) + " (or the reviewed overlay QPF), without --allow-rbf. "
        "Check-only map/fit/STA uses no production queue lane.\n"
    )
    raise SystemExit(2)
