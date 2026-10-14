"""Correct v1 observer path/count defects, without rerunning MAME or modifying images."""
from pathlib import Path
import csv
import hashlib
import json
from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CAPTURE=ROOT / "sim/captures/kyros/idle_death_restart_actions4401"
PRIOR=ROOT / "sim/captures/kyros/idle_death_restart_actions4101"
PRIOR_V=ROOT / "research/kyros_restart_actions4101/verification.json"
FROZEN=ROOT / "research/kyros_restart_acceptance/verification.json"
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=HERE / "verification_v2.json"
    if out.exists():raise SystemExit("Corrected receipt already exists; preserve it.")
    v1_path=HERE / "verification.json"
    assert H(v1_path)=="1f24c5526dc540b547cd7348db74e178ef8b81dadf946958b8ac75ab4a0a9ff5"
    v1=json.loads(v1_path.read_text());terminal=json.loads((HERE / "exit.json").read_text())
    job=json.loads((HERE / "job.json").read_text());prior_v=json.loads(PRIOR_V.read_text())
    states=list(csv.DictReader((CAPTURE / "frame_states.csv").open()))
    prior=list(csv.DictReader((PRIOR / "frame_states.csv").open()))
    ignored={"actual4401_fields","all4101_full_state_prefix_exact","all84_frozen_display_checkpoints_exact"}
    checks={k:v for k,v in v1["checks"].items() if k not in ignored}
    checks.update(actual4401_rows=len(states)==4401, actual_rows_contiguous=[int(x["frame"]) for x in states]==list(range(4401)),
                  actual4101_frozen_state_prefix_exact=states[:4101]==prior,
                  actual4101_verification_pin=H(PRIOR_V)=="84fae3c3d8be28a8050cb70aefc28a61d3042ad9b304b7edcd5ad608d0229e74",
                  original3901_verification_pin=H(FROZEN)=="0b4e054649d1d9c2248a8ee8caf85fd4fb92d7648c0eed694c2bef41a9380206",
                  actual_terminal_job_pin=terminal["job_sha256"]==H(HERE / "job.json"),
                  unchanged_input_pin=H(CAPTURE / "frame_states.csv")==v1["input_sha256"])
    comparisons=[]
    for item in prior_v["snapshots"]:
        n=item["field"];name=f"frame_{n:06d}.display.rgb"
        old=PRIOR / name;new=CAPTURE / name
        comparisons.append({"field":n,"old_sha256":H(old),"new_sha256":H(new),"equal":old.read_bytes()==new.read_bytes()})
        assert H(old)==item["canonical_display_sha256"]
    checks["actual84_frozen_display_checkpoints_exact"]=len(comparisons)==84 and all(x["equal"] for x in comparisons)
    for item in v1["snapshots"]:
        for suffix,key in [(".png","png_sha256"),(".display.rgb","canonical_display_sha256"),
                           (".work.bin","work_sha256"),(".sprites.bin","sprites_sha256")]:
            assert H(CAPTURE / f"frame_{item['field']:06d}{suffix}")==item[key]
    movement=[]
    for n in [4220,4230,4240,4250,4260]:
        p=CAPTURE / f"frame_{n:06d}.png";im=Image.open(p).convert("RGB")
        # Visually identified red player in this bounded lower-courtyard region.
        points=[(x,y) for y in range(180,244) for x in range(70,180)
                if (lambda c:c[0]>=180 and c[1]<=80 and c[2]<=80)(im.getpixel((x,y)))]
        assert points,n
        bounds=[min(x for x,y in points),min(y for x,y in points),max(x for x,y in points),max(y for x,y in points)]
        movement.append({"field":n,"red_player_bounds":bounds,"red_player_center_x":(bounds[0]+bounds[2])/2,
                         "png_sha256":H(p),"canonical_display_sha256":H(p.with_suffix(".display.rgb"))})
    dx=movement[-1]["red_player_center_x"]-movement[0]["red_player_center_x"]
    checks["postready_visible_rightward_player_travel"]=dx>=12 and all(b["red_player_center_x"]>=a["red_player_center_x"] for a,b in zip(movement,movement[1:]))
    result={"schema":"kyros_restart_actions4401_corrected_v2","scope":"Actual pinned MAME reference; one native replay still pending",
            "checks":checks,"finite_reference_prefix_inputs_and_visible_movement_pass":all(checks.values()),
            "fields":4401,"input_path":str(CAPTURE / "frame_states.csv"),"input_sha256":H(CAPTURE / "frame_states.csv"),
            "canonical_display_transform":v1["display_transform"],"actual_mame_pid":terminal["mame_pid"],"actual_exit":terminal["exit_code"],
            "frozen_display_comparisons":comparisons,"snapshots":v1["snapshots"],"movement":movement,"player_rightward_delta_pixels":dx,
            "visual_observations":["GET READY visible4060–4100; original4101 controls ineffective and preserved.",
                "Active courtyard4220–4260 shows identified red player moving right under actual right input.",
                "Button2 window overlaps enemy contact, player fall and loss of green health bar; no successful jump conclusion.",
                "Button1 applied/released4341–4354 while enemies overlap player; successful punch/hit/pickup remains unknown."],
            "v1_supersession":{"path":str(v1_path),"sha256":H(v1_path),"verifier_sha256":H(HERE / "verify_reference.py"),
                "defects":["A broad replacement turned len(states)==4401 into8401.","A sequential path replacement made OLD_CAPTURE equal current CAPTURE, invalidating v1 prefix/display qualification."],
                "correction":"Count exactly4401 actual rows and independently compare the real frozen4101 capture; keep v1 failures immutable, no rerun."},
            "source_pins":{"job":H(HERE / "job.json"),"terminal":H(HERE / "exit.json"),"Lua":H(HERE / "capture_restart_actions.lua"),
                           "corrected_verifier":H(Path(__file__)),"prior4101_receipt":H(PRIOR_V),"frozen3901_receipt":H(FROZEN)},
            "native_restart_movement_actions_pass":False,"successful_jump":"unknown","successful_punch":"unknown","hit":"unknown","pickup":"unknown",
            "no_memory_semantic_labels":True}
    out.write_text(json.dumps(result,indent=2)+"\n")
    (HERE / "review.md").write_text(
        "# Actual legal restart and movement oracle\n\n"
        "MAME PID13184 ended0 with4401 fields. Corrected verification independently compares every one of the4101 prior state rows and84 prior displayed snapshots, and pins all144 current snapshots. Legal PCB right4220–4259 produces visible rightward player travel4220–4260. Replay the actual frame_states.csv; recorded port rows are4221–4260.\n\n"
        "The frozen3901 and4101 oracles remain immutable. The4101 images revealed GET READY through4100, so its earlier controls were ineffective. The4401 extension was limited to300 extra fields, anchored to the prior first-game effective punch711+3500 second-start displacement.\n\n"
        "Button2 and button1 pulses are applied and released, but their visible windows overlap enemy contact. A fall and health loss are observed; successful jump, successful punch, enemy hit and pickup remain unknown. No invented work offsets, CPU/RAM edits or native rebuilds are used.\n\n"
        "The first4401 verifier had two observer defects (wrong8401 count and self-comparison path); its source and failed receipt are preserved. verification_v2.json qualifies actual4401 rows and the real frozen4101 input/display prefix without rerunning MAME or changing capture bytes. The launcher's inherited printed4101 field label is stale; actual job, environment, completion and CSV prove4401. Native restart/movement and final full-feature acceptance remain pending.\n")
    names=["stage_extension.py","prepare_reference.py","verify_reference.py","verify_reference_v2.py","derivation.json",
           "capture_restart_actions.lua","job.json","launcher.json","running.json","exit.json","verification.json","verification_v2.json","review.md"]
    entries=[{"source":str(HERE / n),"destination":"research/kyros_restart_actions4401/"+n,"sha256":H(HERE / n)} for n in names]
    prior_names=["prepare_reference.py","verify_reference.py","capture_restart_actions.lua","job.json","launcher.json","running.json","exit.json","verification.json","visual_limit.md","scenario.md"]
    prior_here=ROOT / "research/kyros_restart_actions4101"
    entries += [{"source":str(prior_here / n),"destination":"research/kyros_restart_actions4101/"+n,"sha256":H(prior_here / n)} for n in prior_names]
    refs=[{"path":str(CAPTURE / n),"sha256":H(CAPTURE / n)} for n in ["frame_states.csv","inputs.csv","complete.txt"]]
    for item in v1["snapshots"]:
        for suffix in [".png",".display.rgb",".work.bin",".sprites.bin",".rgb"]:
            p=CAPTURE / f"frame_{item['field']:06d}{suffix}";refs.append({"path":str(p),"sha256":H(p)})
    manifest={"schema":"kyros_restart_actions_import_v2","entries":entries,"ignored_capture_references":refs,
              "capture_root":str(CAPTURE),"input_sha256":result["input_sha256"],"native_pending":True,
              "no_new_native_build":True,"preserved_frozen3901":str(FROZEN),"scope":"Reference originals retained; no silent observer receipt substitution"}
    manifest_path=HERE / "import_manifest.json";manifest_path.write_text(json.dumps(manifest,indent=2)+"\n")
    assert all(H(Path(x["source"]))==x["sha256"] for x in entries)
    print(json.dumps({"checks":checks,"pass":all(checks.values()),"corrected_verification_sha256":H(out),
        "input":result["input_path"],"input_sha256":result["input_sha256"],"movement":movement,"delta_pixels":dx,
        "manifest":str(manifest_path),"manifest_sha256":H(manifest_path),"portable_entries":len(entries),"capture_refs":len(refs)}))


if __name__=="__main__":main()
