"""Qualify original observed event domain, account for every source-authorized expanded row."""
from pathlib import Path
import csv,json,hashlib,collections
R=Path(__file__).resolve().parents[1];N="kyros_sound_rom_q61"
A=R/"sim/captures/rtl"/N;B=R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def rows(p):
 with p.open(newline="") as f:return list(csv.DictReader(f))
oldhost=Path(r"D:\vibes\fpga\temp\alpha68kn-system.fmv0Nt/system_main.cpp")
newhost=R/"sim/captures/diagnostics"/(N+"_source")/"system_main.cpp"
oldsrc=oldhost.read_text();newsrc=newhost.read_text()
oldrule="""if((attrs&8) || ((attrs&4)==0 && (address==0x0e0000 || (address>=0x20000 && address<=0x2000a)
                || (address>=0x40e1c && address<=0x40e3e))))"""
newrule="""if((attrs&8) || ((attrs&4)==0 && (address==0x060000 || address==0x0e0000 || (address>=0x20000 && address<=0x2000a)
                || (address>=0x40e1c && address<=0x40e3e)
                || (address>=0x40eea && address<=0x40ef0) || address==0x406c2
                || (frame>=330 && frame<=420 && address>=0x040000 && address<0x042000))))"""
norm=lambda x:"".join(x.split())
def olddomain(x):
 a=int(x["address"]);return int(x["iack"])!=0 or (int(x["rw"])==0 and (a==0xe0000 or 0x20000<=a<=0x2000a or 0x40e1c<=a<=0x40e3e))
def newdomain(x):
 a=int(x["address"]);f=int(x["frame"])
 return olddomain(x) or (int(x["rw"])==0 and (a==0x60000 or 0x40eea<=a<=0x40ef0 or a==0x406c2 or (330<=f<=420 and 0x40000<=a<0x42000)))
a=rows(A/"epoch_events.csv");b=[x for x in rows(B/"epoch_events.csv") if int(x["frame"])<61]
common=[x for x in a if olddomain(x)];extra=[x for x in a if not olddomain(x)]
original=R/"research"/(N+"_verification.json");orig=json.loads(original.read_text())
job=json.loads((R/"research"/(N+"_job.json")).read_text())
checks={"old_exact_compiled_predicate_pinned":norm(oldrule) in norm(oldsrc),
"new_exact_compiled_predicate_pinned":norm(newrule) in norm(newsrc),
"old_actual_compiled_host_matches_build_manifest":any(sha(oldhost) in l and "system_main.cpp" in l for l in (R/"research/current_system720_curvefixed_inputs.sha256").read_text().splitlines()),
"new_actual_compiled_host_pin":sha(newhost)==job["generated_host_sha256"],
"reference_events_all_within_original_domain":all(olddomain(x) for x in b),
"all_candidate_events_within_expanded_source_domain":all(newdomain(x) for x in a),
"all135_original_observed_rows_exact":common==b and len(b)==135,
"all32_extra_rows_accounted_by_expanded_source_domain":len(extra)==32 and all(newdomain(x) and not olddomain(x) for x in extra),
"common_ordered_rows_nothing_dropped_or_changed":len(common)==len(b) and common==b,
"original_failure_preserved_only_fulltrace_bijection":[k for k,x in orig["checks"].items() if x is not True]==["main_epoch_irq_latch_rows_tick_exact"]}
v2=dict(orig["checks"]);v2.pop("main_epoch_irq_latch_rows_tick_exact")
v2["main_epoch_original_observer_coverage_tick_exact"]=all(x is True for x in checks.values())
v2["expanded_observer_rows_source_accounted"]=checks["all32_extra_rows_accounted_by_expanded_source_domain"]
src=[]
for p in [oldhost,newhost]:
 ls=p.read_text().splitlines();ids=[i for i,l in enumerate(ls) if "if((attrs&8)" in l]
 src.append({"path":str(p),"sha256":sha(p),"lines":[{"line":n+1,"text":ls[n]} for i in ids for n in range(max(0,i-2),min(len(ls),i+9))]})
out={"scope":"ActualCPU61 exact-cycle soundROM/currentvideo, same original observer coverage. Entire old135 rows retained;32 expanded observer rows are accounted by exact compiled host predicates. No common rows/fields/ticks dropped.",
"checks":v2,"observer_checks":checks,"strict_boolean_all_true":all(x is True for x in v2.values()),"source":src,
"candidate_epoch_rows":len(a),"old_epoch_rows":len(b),"original_coverage_rows":len(common),"expanded_extra_rows":len(extra),
"extras_by_address":dict(collections.Counter(hex(int(x["address"])) for x in extra)),
"first_common_difference":next(({"index":i,"candidate":x,"reference":y} for i,(x,y) in enumerate(zip(common,b)) if x!=y),None),
"original_verification_sha256":sha(original),"original_exact_trace_pass":orig["finite_q61_pass"],
"ROM_contract":orig["ROM_contract"],"actual_frames":orig["frames"],"chip_writes":orig["chip_writes"],"DACwrites":orig["DACwrites"],
"finite_q61_same_observer_coverage_pass":all(x is True for x in v2.values()),"full_sound_acceptance":False,"canonical_MAME_graphics_pass":False,"resource_timing_pass":False,
"limits":["Original exact-entire-epoch-log verifier16/17 failure and independent header-schema failure retained unchanged.",
"Candidate soundROM hardware path is exercised with currentvideo54af; no asyncsimulationbypass.",
"Finite native61 prefix parity does not close known MAME atomic RGB/startup mismatch, P5 semantic effects, full720, resources, or physical acceptance."]}
p=R/"research"/(N+"_observer_v2_verification.json");p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"checks":v2,"observer_checks":checks,"counts":[len(a),len(b),len(extra)],"extras_by_address":out["extras_by_address"],"finite_pass":out["finite_q61_same_observer_coverage_pass"],"sha256":sha(p)}))
raise SystemExit(0 if out["finite_q61_same_observer_coverage_pass"] else 1)
