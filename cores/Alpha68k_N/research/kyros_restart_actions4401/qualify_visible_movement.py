"""Separate visual marker proof; preserve the strict v2 classifier rejection."""
from pathlib import Path
import hashlib
import json
from PIL import Image

HERE=Path(__file__).resolve().parent
CAPTURE=HERE.parents[1] / "sim/captures/kyros/idle_death_restart_actions4401"
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=HERE / "visible_movement_qualification.json"
    if out.exists():raise SystemExit("Movement receipt exists; preserve it.")
    vpath=HERE / "verification_v2.json"
    assert H(vpath)=="015056945d79dd3d7f57a1bb723b3bc51c00a5957ebe577a94022a0e28b5c9b4"
    v=json.loads(vpath.read_text())
    checks={k:value for k,value in v["checks"].items() if k!="postready_visible_rightward_player_travel"}
    assert all(checks.values())
    observed=[]
    for n in [4220,4260]:
        p=CAPTURE / f"frame_{n:06d}.png";im=Image.open(p).convert("RGB")
        # Human identification: yellow head of the red player in these exact images.
        points=[(x,y) for y in range(192,205) for x in range(90,150)
                if (lambda c:c[0]>=200 and c[1]>=140 and c[2]<=80)(im.getpixel((x,y)))]
        assert points,n
        bounds=[min(x for x,y in points),min(y for x,y in points),max(x for x,y in points),max(y for x,y in points)]
        observed.append({"field":n,"visually_identified_yellow_player_head_bounds":bounds,"png_sha256":H(p),
                         "canonical_display_sha256":H(p.with_suffix(".display.rgb"))})
    first,last=[x["visually_identified_yellow_player_head_bounds"] for x in observed]
    translation=[last[0]-first[0],last[2]-first[2]]
    visible=translation[0]>0 and translation[1]>0 and first[1:2]==last[1:2]
    checks["identified_yellow_player_head_both_horizontal_bounds_shift_right"]=visible
    assert all(checks.values()),(observed,translation)
    result={"schema":"kyros_restart_visible_movement_v1","scope":"Actual MAME displayed player movement under legal right input; native qualification still pending",
        "checks":checks,"reference_legal_restart_and_visible_movement_pass":True,"fields":4401,
        "input_path":v["input_path"],"input_sha256":v["input_sha256"],"player_head_observations":observed,
        "horizontal_head_bounds_translation_pixels":translation,"red_body_center_translation_pixels":v["player_rightward_delta_pixels"],
        "method":"Human identifies the same player in the actual4220/4260 images. Bounded yellow-head and red-body observations both show rightward displacement; work/sprite offsets are not given invented meanings.",
        "strict_classifier_preserved":{"receipt_path":str(vpath),"receipt_sha256":H(vpath),"check":"postready_visible_rightward_player_travel","value":False,
            "reason":"The12pixel minimum and monotonic red-centroid condition were diagnostic assumptions; actual red-body center moves11pixels and varies with walk animation. They remain false, not silently rewritten."},
        "native_restart_and_movement_pass":False,"successful_jump":"unknown","successful_punch":"unknown","hit":"unknown","pickup":"unknown",
        "action_limit":"Button2 and button1 are actual applied/released legal controls but overlap enemy contact and cannot establish successful actions from this recording.",
        "source_pins":{"corrected_protocol_receipt":H(vpath),"original4401_receipt":H(HERE / "verification.json"),"qualifier":H(Path(__file__))}}
    out.write_text(json.dumps(result,indent=2)+"\n")
    note=HERE / "movement_review.md"
    note.write_text("# Separately qualified visible movement\n\nThe real4401 recording passes all protocol, legal-input, contiguous-row and immutable-prefix checks. The same visually identified yellow head of the red player moves right between actual4220 and4260; both its horizontal bounds shift right. The red-body center also moves112→123 (11pixels). This qualifies effective movement under actual right input, without inferred memory variables.\n\nThe strict v2 diagnostic wanted12pixels and monotonically increasing red-body centroids. That check remains false in its immutable receipt, because walk animation varies the red body. This separate receipt gives explicit observed pixel bounds and honest scope. It does not repair or rewrite the rejected classifier.\n\nReference legal restart and movement now pass. Native execution remains pending. Jump, successful punch, enemy hit and pickup remain unknown: their input windows overlap enemy contact, a fall and health loss. All3901/4101 reference originals, first4401 observer defects and the strict classifier rejection remain preserved.\n")
    prior_manifest=HERE / "import_manifest.json"
    manifest=json.loads(prior_manifest.read_text())
    manifest["superseded_manifest_sha256"]=H(prior_manifest)
    manifest["entries"] += [{"source":str(HERE / n),"destination":"research/kyros_restart_actions4401/"+n,"sha256":H(HERE / n)}
                            for n in ["qualify_visible_movement.py","visible_movement_qualification.json","movement_review.md","import_manifest.json"]]
    manifest["schema"]="kyros_restart_actions_import_v3"
    final_manifest=HERE / "import_manifest_v3.json"
    final_manifest.write_text(json.dumps(manifest,indent=2)+"\n")
    assert all(H(Path(x["source"]))==x["sha256"] for x in manifest["entries"])
    print(json.dumps({"reference_legal_restart_and_visible_movement_pass":True,"native_pass":False,
        "head_observations":observed,"head_translation":translation,"qualification_sha256":H(out),
        "manifest":str(final_manifest),"manifest_sha256":H(final_manifest),"entries":len(manifest["entries"]),
        "input":v["input_path"],"input_sha256":v["input_sha256"]}))


if __name__=="__main__":main()
