"""Finite existing evidence join; no CPU/memory edit or additional replay."""
from pathlib import Path
import csv
import hashlib
import json
from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CAPTURE=ROOT / "sim/captures/kyros/idle_death_restart_actions4401"
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=HERE / "action_semantic_review.json"
    if out.exists():raise SystemExit("Action review exists; preserve it.")
    v=json.loads((HERE / "visible_movement_qualification.json").read_text())
    assert v["reference_legal_restart_and_visible_movement_pass"]
    states=list(csv.DictReader((CAPTURE / "frame_states.csv").open()))
    isolated=ROOT / "sim/captures/kyros/punch_release1081"
    oldstates=list(csv.DictReader((isolated / "frame_states.csv").open()))
    source=ROOT / "sim/mame/capture_punch_release1081.lua"
    assert H(source)=="a2c6327072386de51e1124bb3f3f1ab4e674f92ffa4212e4cb9785af10ff9be8"
    checks={"current_actual4401_rows":len(states)==4401,
            "current_button2_only_control4281_4284":all(int(states[n]["in0"])==32 for n in range(4281,4285)),
            "current_button1_only_control4341_4354":all(int(states[n]["in0"])==16 for n in range(4341,4355)),
            "current_button2_release4285":int(states[4285]["in0"])==0,
            "current_button1_release4355":int(states[4355]["in0"])==0,
            "prior_isolated_button1_only711_724":all(int(oldstates[n]["in0"])==16 for n in range(711,725)),
            "prior_isolated_button1_release725":int(oldstates[725]["in0"])==0,
            "prior_actual_isolated_swing_image720_present":(isolated / "frame_000720.png").exists()}
    head=[]
    for n in [4280,4285,4290]:
        p=CAPTURE / f"frame_{n:06d}.png";im=Image.open(p).convert("RGB")
        points=[(x,y) for y in range(180,232) for x in range(100,160)
                if (lambda c:c[0]>=200 and c[1]>=140 and c[2]<=80)(im.getpixel((x,y)))]
        assert points,n
        head.append({"field":n,"visually_identified_yellow_head_bounds":[min(x for x,y in points),min(y for x,y in points),max(x for x,y in points),max(y for x,y in points)],"png_sha256":H(p)})
    named={"current_input":CAPTURE / "frame_states.csv","current_legal_Lua":HERE / "capture_restart_actions.lua",
           "visible_movement":HERE / "visible_movement_qualification.json",
           "prior_isolated_Lua":source,"prior_isolated_job":ROOT / "research/kyros_punch_release1081_job.json",
           "prior_isolated_cleanup":ROOT / "research/kyros_punch_release1081_cleanup_prefix.json",
           "prior_isolated_input":isolated / "frame_states.csv","prior_isolated_swing720":isolated / "frame_000720.png",
           "historical_action_audit":ROOT / "research/kyros_action_coverage_existing.json",
           "mame_driver":Path("D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp"),"reviewer":Path(__file__)}
    result={"schema":"kyros_restart_action_semantics_finite_v1","checks":checks,"finite_input_source_join_pass":all(checks.values()),
        "scope":"Existing actual legal MAME observations and historical isolated punch evidence; no new replay or ROM-state injection",
        "source_pins":{k:{"path":str(p),"sha256":H(p)} for k,p in named.items()},
        "PCB_control_semantics":{"right":"IN0mask4, MAME alpha68k_n.cpp577, Kyros active-high definition630",
            "button1":"IN0mask16, MAME579/630; original isolated Lua110 uses only16 and actual720 shows swing, supporting established punch-control interpretation",
            "button2":"IN0mask32, MAME580/630; generic BUTTON2 name alone does not prove jump dispatch or successful landing"},
        "historical_punch":{"legal_actual_rows":[711,724],"visual_swing_field":720,"AY2_B_noise_onset_field":715,
                            "AY2_B_noise_cleanup_field":733,"enemy_hit_proven":False,"current_executable_qualified":False},
        "current_button2_head_observations":head,
        "current_visual_observations":{"button2":"Short head rise4280→4285→4290 precedes horizontal fall4295 and observed loss of green health, near an enemy. This is compatible with jump followed by contact but does not establish successful jump/landing or causation from a qualified ROM dispatch.",
            "button1":"Player and enemies remain clustered4340+; sprite changes are not independently attributable to the legal button1 pulse and do not prove a hit.",
            "movement":"Separately qualified under legal right input; strict red-centroid classifier failure preserved in originalreceipt."},
        "ROM_qualified_button_dispatch":"Unknown: no exact existing action opcode/dispatch receipt was identified in the bounded inspected evidence; no arbitrary work offsets were labelled",
        "successful_jump":"unknown","successful_punch_this_recording":"unknown","enemy_hit":"unknown","pickup":"unknown",
        "current_native_actions_pass":False,"full_P5_P7_pass":False,
        "contact_sheets":[{"path":str(HERE / n),"sha256":H(HERE / n)} for n in ["button2_actual_contact.png","button1_actual_contact.png","movement_actual_contact.png"]]}
    out.write_text(json.dumps(result,indent=2)+"\n")
    md=HERE / "action_semantic_review.md"
    md.write_text("# Finite current action attribution\n\nMAME defines active-high right4, button1=16 and button2=32. Actual4401 rows4281–4284 apply button2 alone;4341–4354 apply button1 alone, with verified releases. The earlier isolated script selected only16 at710–723, and its actual720 image shows a swing with AY2-B onset715/cleanup733. This supports the established punch-control interpretation, not a successful enemy hit.\n\nThe current button2 sheet shows a short head rise at4280/4285/4290, then a horizontal fall4295 beside an enemy and loss of green health. Jump followed by contact is a plausible interpretation, but no ROM-qualified dispatch/landing proof was found in bounded existing evidence. Successful jump remains unknown. The current button1 sheet shows overlapping player/enemies; successful punch and hit cannot be attributed from these images alone. Pickup remains unknown.\n\nEffective movement is separately qualified by visible player translation under actual right input. No new MAME/native run, build, CPU/RAM edit or guessed work-variable semantics was used for this review. Full P5/P7 and current native action acceptance remain pending.\n")
    manifest={"schema":"kyros_action_review_import_v1","entries":[{"source":str(HERE / n),"destination":"research/kyros_restart_actions4401/"+n,"sha256":H(HERE / n)} for n in ["review_action_semantics.py","action_semantic_review.json","action_semantic_review.md"]],
              "same_frozen4401_input_sha256":v["input_sha256"],"no_rerun":True}
    mp=HERE / "action_review_import_manifest.json";mp.write_text(json.dumps(manifest,indent=2)+"\n")
    print(json.dumps({"checks":checks,"pass":all(checks.values()),"head_observations":head,"review_sha256":H(out),
                      "manifest":str(mp),"manifest_sha256":H(mp),"existing_main_manifest_sha256":H(HERE / "import_manifest_v3.json")}))


if __name__=="__main__":main()
