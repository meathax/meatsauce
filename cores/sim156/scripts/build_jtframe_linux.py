"""Build the pinned JTFRAME CLI as a Linux ELF using the Windows Go toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    source = ROOT / "modules" / "jtframe" / "src" / "jtframe"
    go = shutil.which("go") or shutil.which("go.exe")
    if not source.is_dir():
        raise SystemExit(f"missing JTFRAME source: {source}")
    if not go:
        raise SystemExit("Go is missing from the Windows PATH")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(GOOS="linux", GOARCH="amd64", CGO_ENABLED="0")
    result = subprocess.run(
        [go, "build", "-o", str(args.output.resolve()), "."],
        cwd=source,
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(result.stderr[-4000:] or f"go build exited {result.returncode}")

    binary = args.output.resolve().read_bytes()
    if binary[:4] != b"\x7fELF":
        raise SystemExit("cross-compiled JTFRAME tool is not a Linux ELF")
    print(json.dumps({
        "tool": str(args.output.resolve()),
        "sha256": hashlib.sha256(binary).hexdigest(),
        "bytes": len(binary),
        "compiler_invoked": False,
    }, indent=2))


if __name__ == "__main__":
    main()
