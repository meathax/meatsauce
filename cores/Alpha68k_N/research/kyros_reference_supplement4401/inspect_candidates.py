"""Bounded existing-capture inventory: no recursive evidence scan or new replay."""
from pathlib import Path
import csv
import hashlib
import itertools
import json

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
TARGET=ROOT / "sim/captures/kyros/idle_death_restart_actions4401"
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out=HERE / "candidate_inventory.json"
    if out.exists():raise SystemExit("Inventory exists; preserve it.")
    target=list(csv.DictReader((TARGET / "frame_states.csv").open()))
    assert len(target)==4401 and H(TARGET / "frame_states.csv")=="69a65cae5a880a6354eeee8598d4de91c7c73844b459dc25bfb213eadf385c2d"
    expected=sorted(set(range(17))|set(range(0,4401,30))|{119,179,1799,4400})
    current=json.loads((ROOT / "research/kyros_restart_actions4401/verification_v2.json").read_text())
    present={x["field"] for x in current["snapshots"]}
    missing=sorted(set(expected)-present)
    named=[("idle_death7200_v2","kyros_idle_death7200_v2_job.json"),
           ("idle_death7200","kyros_idle_death7200_job.json"),
           ("irq_sampling_edge_mame61","irq_sampling_edge_mame61_job.json"),
           ("combat3600_v2","kyros_combat3600_v2_job.json"),
           ("punch_release1081","kyros_punch_release1081_job.json")]
    candidates=[]
    for name,job_name in named:
        cap=ROOT / "sim/captures/kyros" / name
        jp=ROOT / "research" / job_name
        item={"capture":str(cap),"job_path":str(jp)}
        if not jp.exists() or not (cap / "frame_states.csv").exists():
            item["missing_required_metadata_or_states"]=True;candidates.append(item);continue
        job=json.loads(jp.read_text());item.update(job_sha256=H(jp),job_metadata_keys=sorted(job.keys()))
        with (cap / "frame_states.csv").open() as f:rows=list(itertools.islice(csv.DictReader(f),4401))
        item["bounded_state_rows_read"]=len(rows)
        item["state_file_sha256"]=H(cap / "frame_states.csv")
        exact=0;mismatch=None
        for a,b in zip(target,rows):
            keys=set(a)
            absent=sorted(keys-set(b));different=[k for k in a if k in b and a[k]!=b[k]]
            if absent or different:
                mismatch={"field":int(a["frame"]),"missing_columns":absent,
                          "differences":{k:{"target":a[k],"candidate":b[k]} for k in different}}
                break
            exact+=1
        ports=0
        for a,b in zip(target,rows):
            if any(a[k]!=b.get(k) for k in ["frame","in0","in1","in2"]):break
            ports+=1
        item.update(all_state_prefix_exact_rows=exact,all_input_prefix_exact_rows=ports,first_state_mismatch=mismatch,
                    observed_initial_DIPs=sorted({x.get("in1") for x in rows[:17]}))
        # Enumerate one known capture directory; never descend through its generated tree.
        fields={int(p.name.split("_")[1].split(".")[0]) for p in cap.glob("frame_*.work.bin")}
        extras=sorted(set(missing)&fields)
        item["native_missing_fields_available_in_candidate"]=extras
        item["extras_with_complete_actual_state_prefix"]=[n for n in extras if n<exact]
        item["extra_array_inventory"]=[{"field":n,"files":{s:(cap / f"frame_{n:06d}{s}").exists() for s in [".rgb",".display.rgb",".png",".work.bin",".sprites.bin"]}} for n in extras]
        item["MAME_pin_values"]={k:job[k] for k in job if "mame" in k.lower() and "sha" in k.lower()}
        item["ROM_pin_fields"]={k:job[k] for k in job if "rom" in k.lower()}
        cmd=job.get("command",[])
        if "-autoboot_script" in cmd:
            lua=Path(cmd[cmd.index("-autoboot_script")+1]);item["Lua_path"]=str(lua)
            if lua.exists():
                item["Lua_current_sha256"]=H(lua)
                item["Lua_memory_mutator_lines"]=[{"line":n,"text":line.strip()[:180]} for n,line in enumerate(lua.read_text().splitlines(),1)
                    if any(x in line for x in [":write_u8(",":write_u16(",":write_u32(",":write_range(",'.value ='])][:12]
        candidates.append(item)
    result={"scope":"Bounded five retained candidates, exact nine-column input/state prefix; no inferred historical ROM equality",
        "target_input_path":str(TARGET / "frame_states.csv"),"target_input_sha256":H(TARGET / "frame_states.csv"),
        "expected_native_checkpoint_count":len(expected),"current_common_count":len(set(expected)&present),
        "current_missing_count":len(missing),"missing_fields":missing,"candidates":candidates,
        "helper_sha256":H(Path(__file__)),"qualified_supplement_entries":[]}
    out.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"inventory":str(out),"sha256":H(out),"expected":len(expected),"common":result["current_common_count"],"missing":len(missing),
        "candidates":[{k:x.get(k) for k in ["capture","bounded_state_rows_read","all_state_prefix_exact_rows","all_input_prefix_exact_rows","first_state_mismatch","extras_with_complete_actual_state_prefix","ROM_pin_fields","MAME_pin_values"]} for x in candidates]}))


if __name__=="__main__":main()
