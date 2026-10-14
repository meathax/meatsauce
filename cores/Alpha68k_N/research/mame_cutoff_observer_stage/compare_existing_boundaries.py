"""Join existing actual IRQ boundaries without PC alignment or new execution."""
from pathlib import Path
import csv,hashlib,json
HERE=Path(__file__).resolve().parent
OLD=HERE.parents[1]
NATIVE=OLD/'research/irq_dispatch61/compact_acceptance_v2.json'
MAME=HERE/'run61_qualification.json'
CONTEXT=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\docs\IRQ_TIMING_CONTEXT.md')
def pin(p):return dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size)
n=json.loads(NATIVE.read_text());m=json.loads(MAME.read_text())
iack=Path(m['cutoff_log']['path']).parent/'cpu_space_iack.csv'
with iack.open(newline='') as stream:callbacks=list(csv.DictReader(stream))
cases=[]
for index,(native,window) in enumerate(zip(n['cases'],m['windows']),1):
    original=native['assertion']['tick']
    application=window['assertions'][0]
    before=next(r for r in window['records'] if r['event']=='cutoff_before' and r['sequence']>application['sequence'])
    after=next(r for r in window['records'] if r['event']=='cutoff_after' and r['sequence']==before['sequence']+1)
    entry=native['actual_interrupt_microsequence_entry']
    callback=next(r for r in callbacks if int(r['address'])==0xfffff0+2*index and application['local_ticks']<=int(r['master_ticks'])<=window['window'][1])
    cases.append(dict(level=index,native_assertion_frame_preserved=native['assertion']['frame'],original_assertion_tick=original,MAME_actual_input_application=application,MAME_application_minus_native_assertion=application['local_ticks']-original,native_pending_capture=native['actual_rInterrupt_capture'],native_first_IRtoIRD_and_ITLX1_entry=entry,MAME_first_following_cutoff_before=before,MAME_first_following_cutoff_after=after,native_IRD_written_value_source_qualified=entry['Ir_before'],MAME_IRD_written_value_observed=after['ird'],first_IRQ_taking_IRtoIRD_MAME_minus_native_master_ticks=after['local_ticks']-entry['tick'],native_assert_to_IRtoIRD_ticks=entry['tick']-original,MAME_input_application_to_IRtoIRD_ticks=after['local_ticks']-application['local_ticks'],native_Iac_signal=native['direct_Iac_signal_rise'],native_IACK_bus_attribute=native['observed_IACK_bus_attribute_rise'],MAME_cpu_space_read_tap=callback,IACK_observables_are_distinct_not_same_edge=True))
checks=dict(native_qualified=n['finite_native_boundary_interpretation_pass'] is True and all(v is True for v in n['checks'].values()),MAME_qualified=all(v is True for v in m['checks'].values()),exact_two_original_assertions=[c['original_assertion_tick'] for c in cases]==[47849465,48000000],native_direct_IRtoIRD_irq_entry=all(c['native_first_IRtoIRD_and_ITLX1_entry']['Ir2Ird_before'] is True and c['native_first_IRtoIRD_and_ITLX1_entry']['rInterrupt_before']==1 and c['native_first_IRtoIRD_and_ITLX1_entry']['microAddr_after']==452 for c in cases),MAME_direct_IRtoIRD_pending_selection=all(c['MAME_first_following_cutoff_after']['ird']==c['MAME_first_following_cutoff_after']['ir'] and c['MAME_first_following_cutoff_after']['next']==c['MAME_first_following_cutoff_after']['pending']!=0 and c['MAME_first_following_cutoff_after']['level']==c['level'] for c in cases),instruction_transfer_values_actually_differ=all(c['native_IRD_written_value_source_qualified']==0x30fc and c['MAME_IRD_written_value_observed']==0x51c8 for c in cases))
result=dict(checks=checks,finite_existing_boundary_join_pass=all(checks.values()),cases=cases,provenance=[pin(p) for p in [NATIVE,MAME,iack,CONTEXT,HERE/'terminal_import_manifest.json']],known='The two models first select these IRQs at different actual instruction-transfer boundaries. The relative ordering divergence is directly observed rather than inferred from PC.',likely_responsible_layer='Main CPU interrupt eligibility/clear-loop scheduling before graphics rendering; physical correctness of either implementation is unselected.',next_smallest_diagnostic='Source-level review of the same MOVE.W/DBRA microcode and actual eligibility gates in generated MAME versus fx68k. Join existing two deferred destination-write records to these source-qualified boundaries. No replay or CPU/clock edit is authorized by this analysis.',service_limits='MAME cpu-space read tap, native Iac assertion, native bus attribute and final vector latch are separate boundaries. Prior saved-PC/SR and write contexts remain independently qualified; the existing field60 18-pixel timed backdrop residual remains open.',B16_closed=False,physical_cause_proven=False,MAME_bug_proven=False,CPU_or_clock_correction_justified=False,new_replay_launched=False)
out=HERE/'existing_boundary_comparison.json';out.write_text(json.dumps(result,indent=2)+'\n')
entries=[]
for p in [Path(__file__),out]:
    e=pin(p);e['relative_path']=p.relative_to(HERE).as_posix();entries.append(e)
manifest=HERE/'boundary_comparison_import_manifest.json';manifest.write_text(json.dumps(dict(files=entries,B16_closed=False,no_new_replay_or_RTL_change=True),indent=2)+'\n')
print(json.dumps(dict(checks=checks,manifest=pin(manifest),deltas=[dict(level=c['level'],input_application=c['MAME_application_minus_native_assertion'],first_IRQ_taking_IRtoIRD=c['first_IRQ_taking_IRtoIRD_MAME_minus_native_master_ticks']) for c in cases])))
if not all(checks.values()):raise SystemExit(1)
