"""One isolated obsolete-color-filter fault injection; never alter production RTL."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bounds(pixels):
    return {"min_x": min(p[0] for p in pixels), "max_x": max(p[0] for p in pixels),
            "min_y": min(p[1] for p in pixels), "max_y": max(p[1] for p in pixels)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", choices=("kyros", "kyrosj"), default="kyros")
    parser.add_argument("--label", default="candidate5_entry_renderer")
    parser.add_argument("--field", type=int, default=1500)
    args = parser.parse_args()
    assert args.label.replace("_", "").isalnum()
    evidence = ROOT / "research" / f"{args.set}_{args.label}_verification.json"
    verified = json.loads(evidence.read_text())
    assert verified["passed"]
    case = next(r for r in verified["results"] if r["field"] == args.field)
    original = case["command"]
    ram = ROOT / original[8]
    oracle = ROOT / original[12]
    payload = ROOT / original[7]
    assert sha(ram) == case["ram_sha256"] and sha(oracle) == case["oracle_sha256"]
    assert sha(payload) == verified["payload_sha256"]
    assert all(sha(ROOT / name) == digest for name, digest in verified["fixture_source_sha256"].items())
    binary = ROOT / "sim/captures/diagnostics/combat_hud_prewrite_fixtures/alpha68kn_render_fixture_sim"
    assert sha(binary) == verified["executable_sha256"]
    baseline = ROOT / original[10] / "actual.rgb"
    assert sha(baseline) == case["actual_sha256"] and baseline.read_bytes() == oracle.read_bytes()
    image = payload.read_bytes()
    raw = bytearray(ram.read_bytes())
    modifications = []
    for offset in range(0x800, 0x2000, 2):
        data = int.from_bytes(raw[offset:offset+2], "big")
        clut_address = ((data >> 1) & 0x1000) | (data & 0xffc) | ((data >> 14) & 3)
        if data != 0x20 and image[0x31000 + clut_address] == 255:
            modifications.append({"byte_offset": offset, "before": data, "after": 0x20,
                                  "clut_address": clut_address})
            raw[offset:offset+2] = b"\x00\x20"
    assert modifications
    name = f"{args.set}_candidate5_color_ff_suppression"
    if args.label != "candidate5_entry_renderer" or args.field != 1500:
        name = f"{args.set}_{args.label}_color_ff_suppression_{args.field:06d}"
    out = ROOT / "sim/captures/renderer" / name
    if out.exists():
        raise SystemExit("Refusing to overwrite an existing color-filter probe")
    out.mkdir(parents=True)
    fixture = out / "suppressed.sprites.bin"
    fixture.write_bytes(raw)
    command = list(original)
    command[8] = fixture.relative_to(ROOT).as_posix()
    command[10] = (out / f"field_{args.field:06d}").relative_to(ROOT).as_posix()
    run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
    (out / "run.log").write_text(run.stdout + run.stderr, encoding="utf-8")
    values = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
    result = values[-1] if values else {}
    actual = out / f"field_{args.field:06d}/actual.rgb"
    data = actual.read_bytes() if actual.exists() else b""
    expected = oracle.read_bytes()
    changed = [i // 3 for i in range(0, len(expected), 3) if data[i:i+3] != expected[i:i+3]]
    checks = {"expected_graphics_rejection": run.returncode == 1,
              "complete_field": len(data) == len(expected) == 57344*3,
              "nonvacuous_color_ff_effect": len(changed) > 0,
              "independent_fixture_decoder_agrees": result.get("pixel_mismatches") == 0,
              "mame_difference_count": result.get("oracle_mismatches") == len(changed),
              "suppressed_ff_tiles": result.get("color_ff_tiles") == 0,
              "no_renderer_fault": result.get("deadline_misses") == result.get("row_overflows") == 0}
    native = [(p % 256, p // 256) for p in changed]
    portrait = [(223-y, x) for x, y in native]
    receipt = {"passed": all(checks.values()), "checks": checks, "field": args.field,
               "command": command, "exit_code": run.returncode, "result": result,
               "changed_pixels": len(changed), "modifications": modifications,
               "native_bounds": bounds(native) if native else None,
               "portrait_bounds": bounds(portrait) if portrait else None,
               "source_sha256": {str(evidence.relative_to(ROOT)): sha(evidence),
                                  str(ram.relative_to(ROOT)): sha(ram), str(oracle.relative_to(ROOT)): sha(oracle),
                                  str(payload.relative_to(ROOT)): sha(payload), str(binary.relative_to(ROOT)): sha(binary)},
               "fixture_sha256": sha(fixture), "actual_sha256": sha(actual) if actual.exists() else None,
               "scope": "Deliberate isolated RAM fault injection: replace CLUT255 tile words by the Kyros sentinel, equivalent to the obsolete color255 skip. Positive baseline stays unchanged and matches full MAME RGB. No old-MAME capture, RTL modification, screenshot mask or CPU gameplay acceptance."}
    (ROOT / "research" / f"{name}.json").write_text(json.dumps(receipt, indent=2)+"\n", encoding="utf-8")
    print(json.dumps({"passed": receipt["passed"], "changed_pixels": len(changed),
                      "portrait_bounds": receipt["portrait_bounds"]}))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
