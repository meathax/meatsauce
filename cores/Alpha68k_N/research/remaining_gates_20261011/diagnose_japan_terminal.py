"""Read-only array/oracle lineage diagnosis; preserve the original verifier failure."""
from pathlib import Path
from PIL import Image
import hashlib, json
O = Path(__file__).resolve().parent
R = O.parents[1]
N = O / "japan_joined720"
C = N / "capture"
B = R / "sim/captures/rtl/kyrosj_current720_curvefixed_drive"
M = R / "sim/captures/kyrosj/gameplay"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {"path": str(p), "sha256": sha(p), "bytes": p.stat().st_size}
def js(p): return json.loads(p.read_text(encoding="utf-8-sig"))
original_qualification = js(R / "research/kyrosj_current720_qualification.json")
old_rgb = {x["frame"]: x for x in original_qualification["comparisons"]}
baseline = []
canonical = []
work = []
for field in (0, 30, 90, 240, 360, 600):
    prefix = f"frame_{field:06d}"
    for suffix in ("rgb", "work.bin", "sprites.bin"):
        n, b = C / f"{prefix}.{suffix}", B / f"{prefix}.{suffix}"
        if b.exists():
            aa, bb = n.read_bytes(), b.read_bytes()
            baseline.append({"field": field, "suffix": suffix, "new": pin(n), "original_native": pin(b), "different_bytes": sum(a != z for a, z in zip(aa, bb)) + abs(len(aa) - len(bb))})
        else:
            baseline.append({"field": field, "suffix": suffix, "new": pin(n), "original_native": None, "different_bytes": None, "limit": "Original720 host did not capture work/strip arrays; no original-native comparison is available."})
    png = M / f"{prefix}.png"
    display = M / f"{prefix}.display.rgb"
    raw = M / f"{prefix}.rgb"
    with Image.open(png) as image:
        assert image.size == (224, 256)
        canonical_rgb = image.transpose(Image.Transpose.ROTATE_90).convert("RGB").tobytes()
    native = (C / f"{prefix}.rgb").read_bytes()
    raw_rgb = raw.read_bytes()
    assert len(native) == len(canonical_rgb) == 256 * 224 * 3
    canonical.append({"field": field, "PNG": pin(png), "display_sidecar": pin(display), "raw_drawing_buffer": pin(raw),
        "normalized_PNG_sha256": hashlib.sha256(canonical_rgb).hexdigest(),
        "normalized_PNG_matches_display_sidecar": canonical_rgb == display.read_bytes(),
        "native_matches_original_qualified_native_sha256": sha(C / f"{prefix}.rgb") == old_rgb[field]["rtl_sha256"],
        "display_matches_original_qualified_oracle_sha256": sha(display) == old_rgb[field]["mame_sha256"],
        "different_native_PNG_pixels": sum(native[i:i+3] != canonical_rgb[i:i+3] for i in range(0, len(native), 3)),
        "different_raw_display_pixels": sum(raw_rgb[i:i+3] != canonical_rgb[i:i+3] for i in range(0, len(native), 3))})
    a, b = (C / f"{prefix}.work.bin").read_bytes(), (M / f"{prefix}.work.bin").read_bytes()
    diffs = [{"offset": i, "address_hex": f"0x{0x20000+i:06x}", "native": x, "MAME": y,
              "native_word_hex": a[i&~1:(i&~1)+2].hex(), "MAME_word_hex": b[i&~1:(i&~1)+2].hex()}
             for i, (x, y) in enumerate(zip(a, b)) if x != y]
    if diffs:
        work.append({"field": field, "differences": diffs})
result = {"scope": "No new replay or acceptance rewrite: characterize recorded exit1 against pinned displayed-PNG contract and original actual native720.",
    "original_native_exit": pin(R / "research/kyrosj_current720_curvefixed_exit.json"),
    "original_qualification": pin(R / "research/kyrosj_current720_qualification.json"),
    "MAME_lineage_manifest": pin(M / "manifest.json"),
    "normalizer_contract": pin(R / "scripts/normalize_oracle_display.py"),
    "oracle_contract_document": pin(R / "docs/REFERENCE_ORACLE.md"),
    "original_verifier_failure": pin(N / "verification.json"),
    "original_verifier_exit": pin(N / "verification_exit.json"),
    "original_baseline_arrays": baseline, "canonical_PNG_comparisons": canonical,
    "all18_new_original_native_arrays_exact": all(x["different_bytes"] == 0 for x in baseline),
    "available_original_native_arrays": sum(x["original_native"] is not None for x in baseline),
    "all_available_original_native_arrays_exact": all(x["different_bytes"] == 0 for x in baseline if x["original_native"] is not None),
    "all6_canonical_displayed_PNG_RGB_exact": all(x["different_native_PNG_pixels"] == 0 and x["normalized_PNG_matches_display_sidecar"] for x in canonical),
    "current_atomic_work_differences": work,
    "remaining": "Classify 3/1/4 atomic work bytes against retained CPU/IRQ/reference snapshot timing evidence; do not waive them or change phase. Original verifier exit1 remains immutable."}
output = N / "oracle_lineage_supplement.json"
assert not output.exists()
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"path": str(output), "sha256": sha(output),
    "all18_original_native_arrays_exact": result["all18_new_original_native_arrays_exact"],
    "available_original_native_arrays": result["available_original_native_arrays"],
    "all_available_original_native_arrays_exact": result["all_available_original_native_arrays_exact"],
    "canonical_RGB_differences": [{"field": x["field"], "different_pixels": x["different_native_PNG_pixels"]} for x in canonical],
    "work_differences": work}))
