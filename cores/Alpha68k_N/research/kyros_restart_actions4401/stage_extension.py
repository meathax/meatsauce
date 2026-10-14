"""Focused extra300-field oracle after actual4101 revealed GET READY, no action."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PRIOR = ROOT / "research/kyros_restart_actions4101"
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    if (HERE / "prepare_reference.py").exists():
        raise SystemExit("Extension already staged; do not relaunch.")
    assert H(PRIOR / "verification.json") == "84fae3c3d8be28a8050cb70aefc28a61d3042ad9b304b7edcd5ad608d0229e74"
    t=json.loads((PRIOR / "exit.json").read_text());assert t["exit_code"]==0
    text=(PRIOR / "prepare_reference.py").read_text().replace("actions4101","actions4401").replace('"4101"','"4401"').replace(': 4101',': 4401').replace('"76"','"82"')
    old='        if frame == 4054 then set_input("IN0",0x10,false) end\n        return'
    new='''        if frame == 4054 then set_input("IN0",0x10,false) end
        -- Actual4101 still showed GET READY; original effective punch711+3500 anchors active4211+.
        if frame == 4220 then set_input("IN0",4,true) end
        if frame == 4260 then set_input("IN0",4,false) end
        if frame == 4280 then set_input("IN0",0x20,true) end
        if frame == 4284 then set_input("IN0",0x20,false) end
        if frame == 4340 then set_input("IN0",0x10,true) end
        if frame == 4354 then set_input("IN0",0x10,false) end
        return'''
    assert text.count(old)==1;text=text.replace(old,new)
    old='[4054,"IN0",16,0]],'
    new='[4054,"IN0",16,0],[4220,"IN0",4,1],[4260,"IN0",4,0],[4280,"IN0",32,1],[4284,"IN0",32,0],[4340,"IN0",16,1],[4354,"IN0",16,0]],'
    assert text.count(old)==1;text=text.replace(old,new)
    (HERE / "prepare_reference.py").write_text(text,encoding="utf8",newline="\n")
    text=(PRIOR / "verify_reference.py").read_text()
    text=text.replace('OLD_CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart3901"','OLD_CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart_actions4101"')
    text=text.replace('CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart_actions4101"','CAPTURE = ROOT / "sim/captures/kyros/idle_death_restart_actions4401"')
    text=text.replace('len(states)==4101','len(states)==4401').replace('"actual4101_fields"','"actual4401_fields"').replace('"actual_stop4101"','"actual_stop4401"').replace('"frames=4101"','"frames=4401"')
    text=text.replace('"all3901_full_state_prefix_exact":states[:3901]==prior','"all4101_full_state_prefix_exact":states[:4101]==prior')
    text=text.replace('("button1",16,4041,4054)]','("button1",16,4041,4054),("postready_right",4,4221,4260),("postready_button2",32,4281,4284),("postready_button1",16,4341,4354)]')
    text=text.replace('field<=3900','field<=4100').replace('"all44_frozen_display_checkpoints_exact"','"all84_frozen_display_checkpoints_exact"').replace(')==44',')==84').replace('range(3900,4101,5)','range(3900,4401,5)')
    text=text.replace('[3900,3920,3930,3940,3950,3960]','[4200,4220,4230,4240,4250,4260]').replace('[3980,3985,3990,3995,4000,4005,4010,4020,4030]','[4280,4285,4290,4295,4300,4305,4310,4320,4330]').replace('[4040,4045,4050,4055,4060,4070,4080,4090,4100]','[4340,4345,4350,4355,4360,4370,4380,4390,4400]')
    text=text.replace('"fields":4101','"fields":4401')
    (HERE / "verify_reference.py").write_text(text,encoding="utf8",newline="\n")
    (HERE / "derivation.json").write_text(json.dumps({"source_prepare_sha256":H(PRIOR / "prepare_reference.py"),
        "source_verifier_sha256":H(PRIOR / "verify_reference.py"),"frozen4101_verification_sha256":H(PRIOR / "verification.json"),
        "derived_prepare_sha256":H(HERE / "prepare_reference.py"),"derived_verifier_sha256":H(HERE / "verify_reference.py"),
        "reason":"Actual4101 visual GET READY through4100; first controls were ineffective, preserved. Minimum300field extension uses original effective punch711+second-start delta3500 active4211+ anchor.",
        "scope":"No production edits, new native build or altered frozen receipts"},indent=2)+"\n")
    code=subprocess.call([sys.executable,"-X","utf8",str(HERE / "prepare_reference.py")]);raise SystemExit(code)


if __name__=="__main__":main()
