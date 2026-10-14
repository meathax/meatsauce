"""Inspect existing pre-IRQ ordinary-cycle coverage; never launch a replay."""
from pathlib import Path
import csv,hashlib,json
HERE=Path(__file__).resolve().parent
OLD=HERE.parents[1]
paths=dict(native_dispatch=OLD/'sim/captures/rtl/irq_dispatch61/dispatch.csv',native_requests=OLD/'sim/captures/rtl/kyros_instruction60_diagnostic/instruction_events.csv',native_latches=OLD/'sim/captures/rtl/irq_sampling_edge_latch61/latch_phase.csv',MAME_events=OLD/'sim/captures/kyros/mame_cutoff_observer61/events.csv',MAME_cutoffs=HERE/'run61_qualification.json')
windows=[dict(level=1,assertion=47849465,addresses=[0x411b0,0x411b2]),dict(level=2,assertion=48000000,addresses=[0x41502,0x41504])]
out={name:[] for name in ['native_dispatch','native_requests','native_latches','MAME_events']}
headers={}
total_rows={}
for name in out:
    with paths[name].open(newline='') as stream:
        reader=csv.DictReader(stream);headers[name]=reader.fieldnames;count=0
        for raw in reader:
            count+=1
            tick=int(raw['master_ticks'] if name=='MAME_events' else raw['tick'])
            if any(w['assertion']-800<=tick<w['assertion'] for w in windows):out[name].append(raw)
        total_rows[name]=count
results=[]
for w in windows:
    in_window=lambda r,name:w['assertion']-800<=int(r['master_ticks'] if name=='MAME_events' else r['tick'])<w['assertion']
    ds=[r for r in out['native_dispatch'] if in_window(r,'native_dispatch') and int(r['address']) in w['addresses'] and int(r['data_out'])==32 and r['attrs_before']=='3' and r['attrs_after']=='0']
    accepted=[r for r in out['native_requests'] if in_window(r,'native_requests') and int(r['address']) in w['addresses'] and r['rw']=='0' and r['uds_n']==r['lds_n']=='0' and int(r['data_out'])==32]
    callbacks=[r for r in out['MAME_events'] if in_window(r,'MAME_events') and int(r['address']) in w['addresses'] and int(r['data'])==32 and int(r['mask'])==65535]
    latch_rows=[r for r in out['native_latches'] if in_window(r,'native_latches')]
    rom_reads=[r for r in out['MAME_events'] if in_window(r,'MAME_events') and 0x850<=int(r['address'])<=0x85f]
    ds.sort(key=lambda r:int(r['address']));callbacks.sort(key=lambda r:int(r['address']));accepted.sort(key=lambda r:int(r['address']))
    pairs=[dict(address=int(n['address']),value=32,native_strobe_transition_tick=int(n['tick']),MAME_write_callback_tick=int(m['master_ticks']),callback_minus_strobe=int(m['master_ticks'])-int(n['tick']),native_request_acceptance_tick=next((int(r['tick']) for r in accepted if r['address']==n['address']),None)) for n,m in zip(ds,callbacks)]
    results.append(dict(level=w['level'],assertion=w['assertion'],native_strobe_rows=ds,MAME_write_callback_rows=callbacks,native_accepted_request_rows=accepted,pairs=pairs,native_strobe_period=int(ds[1]['tick'])-int(ds[0]['tick']) if len(ds)==2 else None,MAME_store_period=int(callbacks[1]['master_ticks'])-int(callbacks[0]['master_ticks']) if len(callbacks)==2 else None,preIRQ_native_latch_row_count=len(latch_rows),preIRQ_MAME_ordinary_ROM_read_count=len(rom_reads)))
checks=dict(two_pairs_per_IRQ=all(len(r['pairs'])==2 for r in results),matching_destination_order=all([p['address'] for p in r['pairs']]==w['addresses'] for r,w in zip(results,windows)),same_finite_combined_loop_period=all(r['native_strobe_period']==r['MAME_store_period']==176 for r in results),constant_preIRQ_phase_offset=all([p['callback_minus_strobe'] for p in r['pairs']]==[-74,-74] for r in results),ordinary_native_CPU_latch_coverage_is_absent=all(r['preIRQ_native_latch_row_count']==0 for r in results),ordinary_MAME_ROM_read_coverage_is_absent=all(r['preIRQ_MAME_ordinary_ROM_read_count']==0 for r in results),IRQ1_accepted_request_coverage_missing=len(results[0]['native_accepted_request_rows'])==0,IRQ2_native_accepts_one_tick_after_strobe=all(p['native_request_acceptance_tick']==p['native_strobe_transition_tick']+1 for p in results[1]['pairs']))
def pin(p):return dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size)
recipe=dict(native_observer='Extend only the existing read-only latch host capture predicate to master-tick intervals [47848665,47849965] and [47999200,48000500], including field58. Keep actual source graph/ROM/inputs/reset/clocks identical. Export ASn, lanes/RW/address/data, actual board main_accept/transaction edge, external and registered DTACK, enPhi1/enPhi2, toIRC/toDBIN, qualified preedge DIN, IR/IRD/IRC, micro/nano address, wait and cycle-end controls. Preserve original observation columns and qualify all original61 states/19 images before interpreting.',MAME_observer='Clone the qualified Lua recorder and retain custom PE cb9ac0f56d97ac0cac97190b2e9e028fa68f7dc9c19235d9b3e364387c218c6d. Add a passthrough program-space read tap only at 0x850..0x85F, limited to the same two tick windows; export address/data/mask and distinct CPU-local/machine times to a separate CSV. Preserve every original CSV and all9 whole arrays, plus the existing cutoff sequence. No MAME rebuild is needed.',comparison='Pair complete preceding loop iterations by destination/data/order and source-qualified prefetch transfers. Compare store-to-store periods first, then native request→qualified DTACK→final CPU capture and MAME source-defined read callback intervals. Never label request acceptance, DS transition, read callback or input capture as the same edge. Identify the first producer difference rather than tuning phase.',execution_status='Proposal only. No new native/MAME process or CPU/clock/scheduler patch launched.')
result=dict(checks=checks,finite_coverage_review_pass=all(checks.values()),cases=results,raw_row_counts=total_rows,headers=headers,provenance=[pin(p) for p in paths.values()],known='The two preceding loop iterations per IRQ have equal176-master-tick store periods and constant MAME-callback-minus-native-strobe phase -74. There is no observed growth in the combined MOVE+DBRA loop period over this finite prefix.',limits='This rules out net per-iteration inflation in these two combined-loop intervals, not individual-cycle waits compensated elsewhere or earlier startup drift. Ordinary pre-IRQ latch/DTACK rows and genuine MAME ROM-read callbacks are absent. IRQ1 accepted request rows are also missing from the existing field59/60 request selector. No physical edge equivalence or responsible RTL defect is established.',missing_evidence_recipe=recipe,B16_closed=False,CPU_or_clock_fix_justified=False,new_replay_launched=False)
artifact=HERE/'ordinary_cycle_coverage.json';artifact.write_text(json.dumps(result,indent=2)+'\n')
files=[]
for p in [Path(__file__),artifact]:
    entry=pin(p);entry['relative_path']=p.relative_to(HERE).as_posix();files.append(entry)
manifest=HERE/'ordinary_cycle_coverage_import_manifest.json';manifest.write_text(json.dumps(dict(files=files,no_RTL_or_replay_change=True,B16_closed=False),indent=2)+'\n')
print(json.dumps(dict(checks=checks,manifest=pin(manifest),cases=[dict(level=r['level'],pairs=r['pairs'],native_period=r['native_strobe_period'],MAME_period=r['MAME_store_period'],native_latch_rows=r['preIRQ_native_latch_row_count'],MAME_ROM_read_rows=r['preIRQ_MAME_ordinary_ROM_read_count']) for r in results])))
if not all(checks.values()):raise SystemExit(1)
