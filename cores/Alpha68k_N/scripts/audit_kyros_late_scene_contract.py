"""Audit existing full RGB late fixtures against canonical acceptance contract."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
CANONICAL=Path(r"D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(n):return json.loads((ROOT/"research"/n).read_text())
def mapped(s):
    return Path("D:/"+s[7:]) if s.startswith("/mnt/d/") else ROOT/s
def main():
    plan=CANONICAL/"plan.md"
    phrases=["Real fx68k and Z80 RTL execute","Graphics match pinned MAME","A debugger/Lua-created checkpoint","Stage-5/ending fixture coverage","Exercise Kyros stage 5","Avoid claiming extended-play completion","with the necessary late-scene fixtures"]
    excerpts=[{"line":i+1,"text":s} for i,s in enumerate(plan.read_text(encoding="utf-8").splitlines()) if any(p in s for p in phrases)]
    assert len(excerpts)==7
    common=load("kyros_ending_renderer_job.json")
    pins=common["fixture_source_sha256"];assert len(pins)==11
    source_bad=[p for p,d in pins.items() if sha(ROOT/p)!=d]
    assert not source_bad
    cases=[]
    for name in ["kyros_candidate5_lastroom_renderer","kyrosj_candidate5_lastroom_renderer","kyros_ending_renderer"]:
        j=load(name+"_verification.json")
        shared=j["shared_native_dut_paths"]
        canonical_bad=[p for p in shared if sha(CANONICAL/p)!=pins[p]]
        assert len(shared)==9 and not canonical_bad and j["passed"]
        fields=[]
        for q in j["results"]:
            assert q["exit_code"]==0 and q["passed"] and q["complete_rgb_mismatches"]==0
            assert q["result"]["pixels"]==57344 and q["result"]["deadline_misses"]==0 and q["result"]["row_overflows"]==0
            cmd=q["command"]
            assert sha(mapped(cmd[6]))==j["executable_sha256"]
            oracle=mapped(cmd[-1]);folder=mapped(cmd[-3])
            matching=[p for p in folder.glob("*.rgb") if sha(p)==q["actual_sha256"]]
            assert matching,"Retained complete RGB absent: "+str(folder)
            actual=matching[0]
            assert sha(oracle)==q["oracle_sha256"] and actual.read_bytes()==oracle.read_bytes()
            assert len(actual.read_bytes())==57344*3
            fields.append({"field":q["field"],"actual_exit_code":q["exit_code"],"pixels":57344,"full_rgb_differences":0,"actual_path":str(actual),"oracle_path":str(oracle),"actual_sha256":sha(actual),"oracle_sha256":sha(oracle)})
        assert len(fields)==5
        cases.append({"name":name,"receipt_sha256":sha(ROOT/"research"/(name+"_verification.json")),"source_parent":j["source_parent"],"executable_sha256":j["executable_sha256"],"compiled_pins_exact":11,"shared_current_canonical_pins_exact":9,"fields":fields,"original_scope":j["scope"],"natural_cpu_progression_proven":False})
    bug=json.loads((ROOT/"docs/bug_coverage.json").read_text())
    assert all(bug["B01"]["late_room_cases"][p]["fault_probe_changed_pixels"]==500 for p in ["kyros","kyrosj"])
    pilot=load("kyros_legal_route_pilot_v1_verification.json")
    assert pilot["integrity_pass"] and len(pilot["checks"])==9 and load("kyros_legal_route_pilot_v1_exit.json")["exit_code"]==0
    audit={"scope":"Existing Kyros late-scene fixtures against exact canonical plan; no replay or broad P7 closure.","plan":{"path":str(plan),"sha256":sha(plan),"excerpts":excerpts},"correction":"Earlier kyros_late_game_acceptance_gap.json overstated natural control-only stage5/ending progression as a mandatory first missing requirement. Its retained actualCPU RAM facts remain valid.","contract_interpretation":"P1 explicitly permits debugger/Lua-created rendering checkpoints. P7 requires realCPU attract/controllablegameplay plus necessary late-scene fixtures. Natural RTL CPU ending progression is not explicitly required; fixture coverage never replaces actual attract/gameplay.","fixture_cases":cases,"B01_required_targeted_fixture_covered":True,"B01_profiles":["kyros","kyrosj"],"B01_nonvacuous_fault_changed_pixels":{"kyros":500,"kyrosj":500},"B02_required_targeted_fixture_covered":True,"B02_profile":"kyros","B02_semantics":"Guarded explicit MAME boss-state fixture selects actual ROM staff-text ending and observed character/text overlap; existing strip priority preserved. No legal playthrough claim.","natural_cpu_stage5_progression_proven":False,"natural_cpu_ending_progression_proven":False,"whole_game_acceptance":False,"P7_complete":False,"remaining_required_work":"Reuse15 immutable complete RGB fields in final hash-bound bug disposition; resolve genuine realCPU startup/attract/gameplay atomic mismatches and remaining profile/feature/audio coverage. Re-run only invalidated dependent evidence.","limits":["No original-board attachment-image equivalence claim.","World ending fixture does not supply Japan ending; add that fixture only if profile-specific changes require it.","Original zero-effect entry/corridor negative probes remain failures."],"pilot":{"actual_exit_code":0,"fields":673,"integrity_checks_passed":9,"result":pilot["result"],"diagnosis":"Retained PC34ee/352a is in ROM3414..355e stage-announcement loop and screenshot659 displaysSTAGE3. The12-field rawUP sample found no coordinate change; this does not diagnose a production input defect or movement axes. Further pilots paused."}}
    out=ROOT/"research/kyros_late_scene_contract_audit.json";md=ROOT/"research/kyros_late_scene_contract_audit.md"
    assert not out.exists() and not md.exists()
    out.write_text(json.dumps(audit,indent=2)+"\n",encoding="utf-8")
    md.write_text("# Kyros late-scene contract audit\n\nThe canonical plan combines real CPU attract and controllable gameplay with necessary late-scene fixtures. P1 expressly permits debugger/Lua-created rendering checkpoints. Natural RTL CPU progression into stage5 and the ending is unproven, but is not an explicit additional acceptance prerequisite. The earlier gap audit overstated it as mandatory; its observed RAM facts remain valid.\n\nWorld and Japan stage-five late-room cases each match five complete57344-pixel MAME fields. Both nonvacuous color-ff suppression cases change500 pixels. World ending supplies five complete matching fields with actual staff-text state and preserved character/text priority. All15 retained native/oracle byte arrays, actual executable hashes,11 compiled sources and9 current canonical production renderer/SDRAM sources were checked. These are reusable finite targeted B01/B02 coverage, not whole-game graphics or P7 closure.\n\nThe legal route pilot exited0 at673 fields with9 integrity checks and no cheats or state writes. Its short movement sample occurred in the ROM stage-announcement loop while the screenshot still displayedSTAGE3. No production input defect or axis interpretation follows. Further pilots are paused.\n\nKeep the15 existing fixture identities in final acceptance. Resolve realCPU startup/attract/gameplay atomic mismatches and the remaining profile/feature/audio requirements; repeat only source-invalidated checks. Natural late-stage progression remains an explicitly unproven optional investigation.\n",encoding="utf-8")
    q=json.loads(out.read_text());assert sum(len(x["fields"]) for x in q["fixture_cases"])==15 and not q["P7_complete"]
    print(json.dumps({"outputs":{str(out):sha(out),str(md):sha(md)},"full_rgb_fields_checked":15,"compiled_source_pins":11,"canonical_shared_pins_per_case":9,"actual_elfs_pinned":3,"audit_pass":True}))
if __name__=="__main__":main()
