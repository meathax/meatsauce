"""One terminal qualification, displayed-image lineage and bounded visual sheet."""
from pathlib import Path
import csv
import hashlib
import json
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = ROOT / "research/kyros_restart_acceptance"
OLD_CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart3901"
CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart_actions4101"
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out = HERE / "verification.json"
    if out.exists():
        raise SystemExit("Verification receipt exists; preserve it.")
    terminal = json.loads((HERE / "exit.json").read_text())
    job = json.loads((HERE / "job.json").read_text())
    base_v = json.loads((BASE / "verification.json").read_text())
    states = list(csv.DictReader((CAPTURE / "frame_states.csv").open()))
    prior = list(csv.DictReader((OLD_CAPTURE / "frame_states.csv").open()))
    events = list(csv.DictReader((CAPTURE / "inputs.csv").open()))
    actual = [[int(x["frame"]),x["port"],int(x["mask"]),int(x["active"])] for x in events if int(x["frame"]) > 3900]
    checks = {"actual_terminal0":terminal["exit_code"]==0,"no_Lua_failure":not terminal["failure_file"],
              "actual4101_fields":len(states)==4101,"actual_stop4101":"frames=4101" in (terminal["complete"] or ""),
              "all3901_full_state_prefix_exact":states[:3901]==prior,
              "all_DIPs206":{int(x["in1"]) for x in states}=={206},
              "exact_legal_extension_events":actual==job["extension_events"],
              "frozen_verification_unchanged":H(BASE / "verification.json")==job["frozen3901_verification_sha256"],
              "pinned_actual_MAME":H(Path(job["command"][0]))==job["mame_sha256"],
              "derived_Lua_unchanged":H(HERE / "capture_restart_actions.lua")==job["derived_lua_sha256"]}
    for name,mask,start,end in [("right",4,3921,3960),("button2",32,3981,3984),("button1",16,4041,4054)]:
        checks[name+"_actual_port_rows"] = all(int(states[n]["in0"])&mask for n in range(start,end+1))
        checks[name+"_release"] = not (int(states[end+1]["in0"])&mask)
    transform = base_v["display_transform"]
    ops = {"identity":None,"rotate90":Image.Transpose.ROTATE_90,"rotate180":Image.Transpose.ROTATE_180,
           "rotate270":Image.Transpose.ROTATE_270,"flip_lr":Image.Transpose.FLIP_LEFT_RIGHT,
           "flip_tb":Image.Transpose.FLIP_TOP_BOTTOM,"transpose":Image.Transpose.TRANSPOSE,
           "transverse":Image.Transpose.TRANSVERSE}
    snapshots=[]
    for png in sorted(CAPTURE.glob("frame_*.png")):
        field=int(png.stem.split("_")[1]);im=Image.open(png).convert("RGB")
        if ops[transform] is not None: im=im.transpose(ops[transform])
        assert im.size==(256,224)
        display=png.with_suffix(".display.rgb")
        with display.open("xb") as f: f.write(im.tobytes())
        item={"field":field,"png_sha256":H(png),"canonical_display_sha256":H(display),
              "work_sha256":H(png.with_suffix(".work.bin")),"sprites_sha256":H(png.with_suffix(".sprites.bin"))}
        if field<=3900 and (OLD_CAPTURE / display.name).exists():
            item["frozen_display_exact"]=display.read_bytes()==(OLD_CAPTURE / display.name).read_bytes()
        snapshots.append(item)
    checks["all44_frozen_display_checkpoints_exact"] = sum("frozen_display_exact" in x for x in snapshots)==44 and all(x.get("frozen_display_exact",True) for x in snapshots)
    checks["all_extension_every5_snapshots_present"] = all((CAPTURE / f"frame_{n:06d}.png").exists() for n in range(3900,4101,5))
    # Actual portrait PNGs, unaltered except labelled contact-sheet placement.
    groups={"movement":[3900,3920,3930,3940,3950,3960],
            "button2":[3980,3985,3990,3995,4000,4005,4010,4020,4030],
            "button1":[4040,4045,4050,4055,4060,4070,4080,4090,4100]}
    sheets=[]
    for name,fields in groups.items():
        sheet=Image.new("RGB",(224*3,276*((len(fields)+2)//3)),"#202020");draw=ImageDraw.Draw(sheet)
        for i,n in enumerate(fields):
            im=Image.open(CAPTURE / f"frame_{n:06d}.png").convert("RGB")
            assert im.size==(224,256)
            x=(i%3)*224;y=(i//3)*276
            sheet.paste(im,(x,y+20));draw.text((x+4,y+3),str(n),fill="white")
        path=HERE / (name+"_actual_contact.png");sheet.save(path)
        sheets.append({"path":str(path),"sha256":H(path),"fields":fields})
    result={"schema":"kyros_restart_actions_reference_v1","checks":checks,"finite_reference_prefix_and_inputs_pass":all(checks.values()),
            "scope":"Actual legal-input MAME oracle; visual semantic qualification separately required; no native execution",
            "fields":4101,"display_transform":transform,"snapshots":snapshots,"contact_sheets":sheets,
            "input_path":str(CAPTURE / "frame_states.csv"),"input_sha256":H(CAPTURE / "frame_states.csv"),
            "source_pins":{"job":H(HERE / "job.json"),"terminal":H(HERE / "exit.json"),"Lua":H(HERE / "capture_restart_actions.lua"),
                           "verifier":H(Path(__file__)),"frozen3901_verification":H(BASE / "verification.json")},
            "native_restart_movement_actions_pass":False,"effective_movement": "Requires actual displayed inspection",
            "successful_jump":"unknown","successful_punch":"unknown","hit":"unknown","pickup":"unknown"}
    out.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"verification":str(out),"sha256":H(out),"checks":checks,"input":result["input_path"],
                      "input_sha256":result["input_sha256"],"sheets":sheets,"snapshots":len(snapshots)}))


if __name__ == "__main__":
    main()
