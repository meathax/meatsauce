"""Independent epoch schema qualification; retain original exact-all-columns verifier failure."""
from pathlib import Path
import csv,json,hashlib
R=Path(__file__).resolve().parents[1];N="kyros_sound_rom_q61"
A=R/"sim/captures/rtl"/N;B=R/"sim/captures/rtl/kyrosj_current720_curvefixed_drive"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):
 with p.open(newline="") as f:
  d=csv.DictReader(f);return d.fieldnames,list(d)
ah,a=read(A/"epoch_events.csv");bh,b=read(B/"epoch_events.csv");b=[x for x in b if int(x["frame"])<61]
oldhost=Path(r"D:\vibes\fpga\temp\alpha68kn-system.fmv0Nt/system_main.cpp")
newhost=R/"sim/captures/diagnostics"/(N+"_source")/"system_main.cpp"
src=[]
for p in [oldhost,newhost]:
 ls=p.read_text().splitlines();ids=[i for i,l in enumerate(ls) if "epoch_events<<" in l or "previous_main" in l or "main_transactions" in l and "!=" in l]
 chosen=set()
 for i in ids:chosen.update(range(max(0,i-1),min(len(ls),i+7)))
 src.append({"path":str(p),"sha256":sha(p),"lines":[{"line":i+1,"text":ls[i]} for i in sorted(chosen)]})
projected=[{k:x[k] for k in bh} for x in a] if set(bh)<=set(ah) else []
v=R/"research"/(N+"_verification.json");orig=json.loads(v.read_text())
checks={"actual_original_16of17":sum(x is True for x in orig["checks"].values())==16,
"only_original_epoch_full_schema_failed":[k for k,x in orig["checks"].items() if x is not True]==["main_epoch_irq_latch_rows_tick_exact"],
"original_native_reference_pin":sha(oldhost)=="53ce5cd66b0611095d18a2e5972cb64022a1c2d2467e5ab2db28a25f71c78485",
"all_original_columns_retained":set(bh)<=set(ah),
"only_new_raster_columns":set(ah)-set(bh)=={"raster_x","raster_y"},
"actual_rows_nonvacuous_and_counts_exact":len(a)==len(b) and len(a)>0,
"every_shared_epoch_column_tick_byte_exact":projected==b,
"new_source_header_has_raster":'tick,frame,raster_x,raster_y,address,iack' in newhost.read_text(),
"old_source_header_without_raster":'tick,frame,address,iack' in oldhost.read_text(),
"all_other_original_checks_true":all(x is True for k,x in orig["checks"].items() if k!="main_epoch_irq_latch_rows_tick_exact")}
# Hash equality is qualified against retained actual build manifest, never assumed from a host filename.
manifest=R/"research/current_system720_curvefixed_inputs.sha256"
text=manifest.read_text()
checks["original_native_reference_pin"]=any(sha(oldhost) in l and "system_main.cpp" in l for l in text.splitlines())
out={"scope":"Finite shared epoch schema comparison; added raster observation columns retained. Original all-columns comparison failure remains immutable.",
"checks":checks,"original_header":bh,"candidate_header":ah,"original_rows":len(b),"candidate_rows":len(a),
"first_shared_difference":next(({"index":i,"candidate":x,"reference":y} for i,(x,y) in enumerate(zip(projected,b)) if x!=y),None),
"source":src,"original_verification_sha256":sha(v),"retained_manifest_sha256":sha(manifest),
"finite_q61_shared_epoch_pass":all(x is True for x in checks.values()),"fullP5pass":False,"canonical_MAME_graphics_pass":False,"resources_timing_pass":False}
p=R/"research"/(N+"_epoch_schema_qualification.json");p.write_text(json.dumps(out,indent=2)+"\n")
print(json.dumps({"checks":checks,"headers":[bh,ah],"counts":[len(b),len(a)],"first_shared_difference":out["first_shared_difference"],"finite_pass":out["finite_q61_shared_epoch_pass"],"receipt_sha256":sha(p)}))
raise SystemExit(0 if out["finite_q61_shared_epoch_pass"] else 1)
