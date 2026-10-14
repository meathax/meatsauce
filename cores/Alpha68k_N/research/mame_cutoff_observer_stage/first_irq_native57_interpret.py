from pathlib import Path
import csv,json,hashlib
OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N');S=OLD/'research/mame_cutoff_observer_stage';P=S/'first_irq_native57_proposal';R=S/'first_irq_native57_released1';OUT=R/'interpretation';CAP=OLD/'sim/captures/rtl/irq_first_enabled57'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)}
def rows(p):
 with p.open(newline='')as f:return list(csv.DictReader(f))
def save(n,obj):
 with(OUT/n).open('x',encoding='utf8')as f:f.write(json.dumps(obj,indent=2)+'\n')
 return pin(OUT/n)
assert not OUT.exists(),'Preserve prior interpretation'
q=json.loads((P/'qualification.json').read_text());ex=json.loads((R/'qualification_exit.json').read_text())
assert q['accepted'] and ex['actual_exit_code']==0 and ex['baseline_files_unchanged'],'Do not interpret unqualified observations'
r=rows(CAP/'first_irq_bus.csv');v=lambda x,k:int(x[k]);assert len(r)==1701
OUT.mkdir()
as_edges=[x for x in r if v(x,'asn_before')==1 and v(x,'asn_after')==0]
ds_edges=[x for x in r if v(x,'attrs_before')&3==3 and v(x,'attrs_after')&3!=3]
def brief(x):
 return {k:v(x,k)for k in['tick','address_before','address_after','attrs_before','attrs_after','asn_before','asn_after','clks_before','clks_after','cpu_phase_before','cpu_phase_after','tstate_before','tstate_after','wclk_before','wclk_after','vpai_before','vpai_after','vpan_external_before','vpan_external_after','e_counter_before','e_counter_after','e_derived_from_counter_before','e_derived_from_counter_after','vma_n_before','vma_n_after','xvma_derived_before','xvma_derived_after','dtack_n_before','dtack_n_after','rdtack_before','rdtack_after','microaddr_before','microaddr_after','nanoaddr_before','nanoaddr_after','nano_ir2ird_before','nano_ir2ird_after','transactions_before','transactions_after','pc_before','pc_after','ir_before','ir_after','ird_before','ird_after']}
commits=q['stack_commits'];low=next(x for x in commits if x['tick']==45732642);sr=next(x for x in commits if x['tick']==45732850);high=next(x for x in commits if x['tick']==45732882)
def bus_for(commit):
 a=next(x for x in reversed(as_edges)if v(x,'tick')<=commit['tick'] and v(x,'address_after')==commit['address'])
 d=next(x for x in reversed(ds_edges)if v(x,'tick')<=commit['tick'] and v(x,'address_after')==commit['address'])
 return {'AS':brief(a),'DS':brief(d),'accept_and_RAM_commit':commit,'AS_to_DS':v(d,'tick')-v(a,'tick'),'DS_to_accept':commit['tick']-v(d,'tick')}
stackbus={'PClo':bus_for(low),'SR':bus_for(sr),'PChi':bus_for(high)}
iack=[x for x in r if(v(x,'attrs_before')|v(x,'attrs_after'))&8]
assert iack and any(v(x,'vma_n_after')==0 for x in iack)
start=v(iack[0],'tick');end=v(iack[-1],'tick')
changes=[]
for x in r:
 if start-32<=v(x,'tick')<=end+48 and any(v(x,k+'_before')!=v(x,k+'_after')for k in['asn','attrs','vpai','vpan_external','e_counter','vma_n','xvma_derived','wclk','microaddr','rdtack']):changes.append(brief(x))
ird=[brief(x)for x in r if(v(x,'clks_before')&2)and v(x,'tstate_before')==4 and not v(x,'wclk_before')and v(x,'nano_ir2ird_before')]
CPUcapture=[brief(x)for x in r if(v(x,'clks_before')&1)and(v(x,'to_irc_before')or v(x,'to_dbin_before'))and start-64<=v(x,'tick')<=sr['tick']]
ackaccept=[brief(x)for x in iack if v(x,'transactions_after')>v(x,'transactions_before')]
MAME={'PClo_write_callback_tick':45732591,'IACK_after_before_time_callback_tick':45732719,'SR_write_callback_tick':45732791,'PChi_write_callback_tick':45732823,'PClo_to_IACK_callback':128,'IACK_callback_to_SR_callback':72,'PClo_to_SR_callback':200}
offsets={'PClo_AS_minus_callback':stackbus['PClo']['AS']['tick']-MAME['PClo_write_callback_tick'],'SR_AS_minus_callback':stackbus['SR']['AS']['tick']-MAME['SR_write_callback_tick'],'PChi_AS_minus_callback':stackbus['PChi']['AS']['tick']-MAME['PChi_write_callback_tick'],'native_PClo_accept_to_SR_accept':sr['tick']-low['tick'],'native_PClo_AS_to_SR_AS':stackbus['SR']['AS']['tick']-stackbus['PClo']['AS']['tick'],'MAME_PClo_callback_to_SR_callback':200}
report={'actual_guest_invariance_accepted':True,'frozen_temporal_baseline_scope':'Original69-source graph; not current43b complete-game qualification.','qualification':pin(P/'qualification.json'),'actual_statuses':{'build':json.loads((OLD/'research/irq_first_enabled57_build_exit.json').read_text())['exit_code'],'simulation':json.loads((OLD/'research/irq_first_enabled57_exit.json').read_text())['exit_code'],'worker':json.loads((R/'native_worker_exit.json').read_text())['actual_exit_code'],'qualifier':ex['actual_exit_code'],'controller':json.loads((R/'controller_exit.json').read_text())['actual_exit_code']},'stack_word_bus_boundaries':stackbus,'MAME_actual_retained_callbacks':MAME,'offsets_and_same_write_elapsed_intervals':offsets,'IACK_actual_native':{'first_selection_tick':start,'last_selection_tick':end,'AS_edges':[brief(x)for x in as_edges if v(x,'attrs_after')&8],'DS_edges':[brief(x)for x in ds_edges if v(x,'attrs_after')&8],'board_acceptance':ackaccept,'ordered_E_VPA_VMA_clock_micro_changes':changes,'CPU_read_capture_enable_samples':CPUcapture,'IR_to_IRD_actual_enabled_edges':ird},'interpretation_limits':'IACK board acceptance is early board transaction bookkeeping, not CPU buscompletion; E/VMA/wClk/AS termination and actualread-capture/IR-to-IRD edges are separately retained. MAMEIACK callback happens after vpa_sync before_time, and after_delay1 follows it; do not equate callback withAS or assumeCPUcycles*8 asactualmachine time. DerivedE/xVma/Iac/waitbus have pinnedsource contracts and runtime guards. NoPCB/donorfix is promoted by a model difference. Additional24 initial42→late66 residual is not automatically closed byfirst8tickinterval.','B16_closed':False,'physical_cause_proven':False,'no_CPU_or_clock_or_IRQ_patch':True,'source_contract':pin(P/'source_contract.json'),'no_MAME_rerun':True,'guest_runs':1}
rp=save('report.json',report)
manifest={'files':[pin(p)for p in OUT.rglob('*')if p.is_file()]+[pin(Path(__file__))],'report':rp,'released_receipts':[pin(p)for p in R.glob('*')if p.is_file()],'proposal_receipts':[pin(p)for p in P.glob('*')if p.is_file()],'native_actual_build_run_receipts':[pin(OLD/f'research/irq_first_enabled57_{name}.json')for name in['job','build_exit','exit']],'raw_native_evidence':[pin(p)for p in CAP.rglob('*')if p.is_file()],'MAME_reference':[pin(OLD/'sim/captures/kyros/mame_cutoff_observer61/events.csv'),pin(OLD/'sim/captures/kyros/mame_cutoff_observer61/cpu_space_iack.csv')],'baseline_graph':pin(R/'CAS_admission.json'),'B16_closed':False}
mp=save('import_manifest.json',manifest)
print(json.dumps({'manifest':mp,'report':rp,'statuses':report['actual_statuses'],'offsets':offsets,'stack_AS_DS_accept':{k:[z['AS']['tick'],z['DS']['tick'],z['accept_and_RAM_commit']['tick']]for k,z in stackbus.items()},'IACK_start_end':[start,end],'IACK_AS':[x['tick']for x in report['IACK_actual_native']['AS_edges']],'VPA_registered_low_first':next((v(x,'tick')for x in iack if v(x,'vpai_before')==1 and v(x,'vpai_after')==0),None),'VMA_low_first':next((v(x,'tick')for x in iack if v(x,'vma_n_before')==1 and v(x,'vma_n_after')==0),None),'microchanges':[{k:z[k]for k in['tick','e_counter_before','e_counter_after','vma_n_before','vma_n_after','wclk_before','wclk_after','asn_before','asn_after','microaddr_before','microaddr_after']}for z in changes],'B16_closed':False}))
