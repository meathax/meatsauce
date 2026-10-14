"""Qualify actual v3 terminal and strict Boolean noise/reset scope; no replay."""
from pathlib import Path
import csv,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
NAME="kyros_active_noise_reset_v3"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    paths={k:ROOT/"research"/(NAME+"_"+k+".json") for k in ["job","build_exit","exit","check_exit","verification"]}
    data={k:json.loads(p.read_text()) for k,p in paths.items()}
    assert all(data[k]["exit_code"]==0 for k in ["build_exit","exit","check_exit"])
    original=data["verification"];job=data["job"];reset=original["actual_reset"]
    checks=original["checks"].copy()
    key="actual_noise_only_nonzero_before_reset"
    assert len(checks)==20 and all(v is True for k,v in checks.items() if k!=key)
    assert isinstance(checks[key],int) and not isinstance(checks[key],bool)
    cap=ROOT/"sim/captures/rtl"/NAME
    with (cap/"active_noise_reset.csv").open(newline="") as f: rows=list(csv.DictReader(f))
    pre=[r for r in rows if r["phase"]=="0"]
    held=[r for r in rows if r["phase"]=="1"]
    post=[r for r in rows if r["phase"]=="2"]
    noise_changes=channel_changes=0
    def active(r):return bool((int(r["mixer"])&2) and not(int(r["mixer"])&16) and (int(r["volume_b"])&31))
    for a,b in zip(pre,pre[1:]):
        if active(a) and active(b) and a["mixer"]==b["mixer"] and a["volume_b"]==b["volume_b"] and int(b["tick"])>int(a["tick"]):
            noise_changes+=a["noise"]!=b["noise"]
            channel_changes+=a["channel_b"]!=b["channel_b"]
    strict_pre=bool(pre and active(pre[-1]) and reset["pre_active_ticks"]>=64 and reset["pre_nonzero_ticks"]>=64 and noise_changes>=4 and channel_changes>=4)
    assert strict_pre and checks[key]==(int(pre[-1]["volume_b"])&31)
    checks[key]=strict_pre
    assert len(held)==64 and all(r["reset"]=="1" and r["channel_b"]=="0" and r["cold_reset"]=="0" and r["downloading"]=="0" for r in held)
    assert int(reset["release_tick"])-int(reset["assert_tick"])==64
    assert int(reset["post_end_tick"])-int(reset["release_tick"])==500000
    assert post and int(post[-1]["tick"])==reset["post_end_tick"] and all(r["channel_b"]=="0" for r in post)
    assert reset["post_nonzero_ticks"]==0 and reset["post_stale_nonzero_ticks"]==0 and reset["post_ay2_data_writes"]==0
    assert original["trace_sha256"]==sha(cap/"active_noise_reset.csv")
    assert all(sha(ROOT/p)==digest for p,digest in job["source_pins"].items())
    assert sha(cap/"alpha68kn_active_noise_reset_sim")==job["executable_sha256"]
    assert original["finite_active_noise_cpu_reset_pass"] and not original["full_B03_acceptance"] and not original["whole_game_acceptance"] and not original["canonical_graphics_pass"]
    out=ROOT/"research"/(NAME+"_terminal_qualification.json");assert not out.exists()
    result={"scope":"Finite actualCPU noise-active punch warm-reset: authentic build/simulation/postcheck exits plus strict Boolean precondition independently recomputed from captured existing signal observations. No rerun or production state mutation.","checks":checks,"all20_checks_strict_boolean_true":all(type(v) is bool and v for v in checks.values()),"actual_terminal_exits":{k:data[k]["exit_code"] for k in ["build_exit","exit","check_exit"]},"actual_reset":reset,"independent_observed_noise_transitions":noise_changes,"independent_observed_channel_transitions":channel_changes,"prefix_rgb_count":len(original["prefix_rgb_images"]),"prefix_sound_rows":original["prefix_sound_rows"],"prefix_epoch_rows":original["prefix_epoch_rows"],"serialization_correction":{"original_check":key,"original_integer_value":original["checks"][key],"meaning":"Python and-chain returned the observed nonzero volume2; original terminal/check exit and original receipt are preserved.","strict_boolean":strict_pre},"evidence_pins":{str(p.relative_to(ROOT)):sha(p) for p in paths.values()},"observer_trace_sha256":sha(cap/"active_noise_reset.csv"),"qualifier_sha256":sha(Path(__file__)),"finite_active_noise_cpu_reset_pass":True,"full_B03_acceptance":False,"whole_game_acceptance":False,"canonical_graphics_pass":False,"limits":["Exactly64 held master ticks and500000 postrelease ticks; no physical reset/clock claim.","Postrelease AY2datawrites are0 and channelB samples remain0; other channels/whole-board PCM alignment are not qualified.","Full Japan/death animation/precise MAME-native PCM and release/resource/physical acceptance remain separate."]}
    assert result["all20_checks_strict_boolean_true"]
    out.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"output":str(out),"sha256":sha(out),"qualifier_sha256":result["qualifier_sha256"],"actual_exits":result["actual_terminal_exits"],"strict_checks":20,"completed_fields":reset["completed_fields"],"noise_transitions":noise_changes,"channel_transitions":channel_changes,"prefix_rgb_count":result["prefix_rgb_count"],"finite_pass":True,"full_B03":False}))
if __name__=="__main__":main()
