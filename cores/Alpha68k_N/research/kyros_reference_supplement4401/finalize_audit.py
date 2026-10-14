"""Record an empty, honest supplement and precise retained-reference coverage."""
from pathlib import Path
import hashlib
import json

HERE=Path(__file__).resolve().parent
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=HERE / "reference_supplement_manifest.json"
    if out.exists():raise SystemExit("Supplement already finalized; preserve it.")
    inv_path=HERE / "candidate_inventory.json"
    assert H(inv_path)=="c8f49297918e93a99d6bc45dbc1bf5c542695b955cdba701761d428d8065b082"
    inv=json.loads(inv_path.read_text())
    assert (inv["expected_native_checkpoint_count"],inv["current_common_count"],inv["current_missing_count"])==(167,49,118)
    assert len(inv["missing_fields"])==118
    assert all(not x.get("extras_with_complete_actual_state_prefix",[]) for x in inv["candidates"])
    original=next(x for x in inv["candidates"] if x["capture"].endswith("idle_death7200_v2"))
    assert original["all_state_prefix_exact_rows"]==3621 and original["all_input_prefix_exact_rows"]==3621
    assert original["first_state_mismatch"]["field"]==3621
    data={"schema":"kyros_retained_reference_supplement_v1","entries":[],"provided_checkpoints":[],
          "scope":"Bounded retained-reference supplement only; no extra capture, replay, build, mask, frame shift or synthesis",
          "target_input_path":inv["target_input_path"],"target_input_sha256":inv["target_input_sha256"],
          "expected_native_checkpoint_count":167,"already_available_common_checkpoints":49,
          "new_qualified_supplement_count":0,"remaining_missing_count":118,"missing_fields":inv["missing_fields"],
          "inventory_path":str(inv_path),"inventory_sha256":H(inv_path),"finalizer_sha256":H(Path(__file__)),
          "candidate_decisions":[{"capture":x["capture"],"job_sha256":x.get("job_sha256"),
              "all_state_prefix_exact_rows":x.get("all_state_prefix_exact_rows"),
              "first_state_mismatch":x.get("first_state_mismatch"),
              "usable_extra_fields":x.get("extras_with_complete_actual_state_prefix",[]),
              "missing_required_metadata_or_states":x.get("missing_required_metadata_or_states",False),
              "historical_ROM_pins_present":bool(x.get("ROM_pin_fields"))} for x in inv["candidates"]],
          "finite_existing_reference_audit_complete":True,"new_supplement_qualified":False,
          "full167_graphics_coverage_pass":False,"native_graphics_pass":"Pending actual native terminal verification; no claim from this audit",
          "limits":["Original idle_death7200_v2 actual MAME recording ran7200 fields; its complete state/input prefix matches0–3620, then differs at legal second coin3621. No missing native checkpoint in that matching prefix has additional arrays.",
                    "IRQ61/combat3600_v2/punch1081 have IN1=142 atfield0, versus final206. No DIP mask or same-game compatibility inference is used.",
                    "Original idle_death7200 lacks frame_states.csv needed for exact nine-column prefix qualification.",
                    "Inspected historical job metadata lacks explicit ROM pin fields; equality of a ROM directory path is not a historical byte pin.",
                    "Existing49 common new-oracle checkpoints remain available as whole RGB/work/strip arrays; this audit neither waives their differences nor fills118 gaps."]}
    out.write_text(json.dumps(data,indent=2)+"\n")
    note=HERE / "review.md"
    note.write_text("# Retained reference supplement audit\n\nNo new checkpoint qualifies. The current native target expects167 checkpoints;49 have the final4401 MAME oracle, while118 remain without that reference. This manifest provides zero arrays and records all118 missing field numbers.\n\nThe original idle_death7200_v2 MAME recording actually ran7200 fields; the earlier3601 stop was the native replay. Its complete nine-column state and input prefix equals the final recording through3620. The second coin changes IN2 at3621. None of its available whole-frame arrays fills a missing native checkpoint before that boundary, and later snapshots cannot be reused across the changed input history.\n\nIRQ61, combat3600_v2 and isolated punch1081 differ in the DIP byte atfield0:142 versus206. They are excluded without masking or a same-game assumption. The older idle_death7200 capture lacks the required frame_states.csv. Inspected historical jobs do not include explicit ROM-byte pin fields, so no equality is inferred merely from a shared ROM directory path.\n\nThe investigator read only five selected capture state files and their flat array filename inventories; no recursive large-capture rescan or new replay was performed. The acceptance verifier must compare all49 common whole RGB/work/strip arrays and preserve the118 gaps. This audit does not claim full graphics coverage or native success.\n")
    names=["inspect_candidates.py","finalize_audit.py","candidate_inventory.json","reference_supplement_manifest.json","review.md"]
    manifest={"schema":"kyros_reference_supplement_audit_import_v1","entries":[{"source":str(HERE / n),"destination":"research/kyros_reference_supplement4401/"+n,"sha256":H(HERE / n)} for n in names]}
    mp=HERE / "import_manifest.json";mp.write_text(json.dumps(manifest,indent=2)+"\n")
    assert all(H(Path(x["source"]))==x["sha256"] for x in manifest["entries"])
    print(json.dumps({"audit_complete":True,"qualified_supplement_count":0,"common":49,"missing":118,
        "supplement":str(out),"supplement_sha256":H(out),"import_manifest":str(mp),"import_manifest_sha256":H(mp),"portable_files":len(names)}))


if __name__=="__main__":main()
