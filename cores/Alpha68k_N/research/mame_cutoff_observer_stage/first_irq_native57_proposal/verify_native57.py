from pathlib import Path
import csv,json,hashlib,wave
HERE=Path(__file__).resolve().parent;OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N');N=OLD/'sim/captures/rtl/irq_first_enabled57';B=OLD/'sim/captures/rtl/irq_sampling_edge_latch61'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def rows(p):
 with p.open(newline='')as f:return list(csv.DictReader(f))
admitted=json.loads((HERE/'admission.json').read_text());checks={'source_and_observer_pins_unchanged':all(sha(p)==h for p,h in admitted['required_pins'].items()),'source_contract_pins_unchanged':all(sha(p)==h for p,h in admitted['source_contract_pins'].items()),'actual_native_exit0':json.loads((OLD/'research/irq_first_enabled57_exit.json').read_text())['exit_code']==0,'frames57':len(rows(N/'frames.csv'))==57}
arrays={p.name:sha(p)==sha(B/p.name)for p in N.glob('frame_*.*')if p.suffix in{'.bin','.rgb','.png'}and(B/p.name).exists()}
checks['all_shared_original_snapshot_arrays_exact']=bool(arrays)and all(arrays.values());unavailable=[p.name for p in N.glob('frame_*.*')if p.suffix in{'.bin','.rgb','.png'}and not(B/p.name).exists()]
csvchecks={}
for p in N.glob('*.csv'):
 if not(B/p.name).exists():continue
 if p.name=='snapshot_state.csv':
  reference={r['frame']:r for r in rows(B/p.name)};csvchecks[p.name]=all(r==reference[r['frame']]for r in rows(p)if r['frame']in reference)
 else:
  new=rows(p);csvchecks[p.name]=new==rows(B/p.name)[:len(new)]
checks['all_original_shared_CSVs_exact']=all(csvchecks.values())and len(csvchecks)==9
with wave.open(str(N/'audio.wav'),'rb')as a,wave.open(str(B/'audio.wav'),'rb')as b:
 checks['available_audio_PCM_prefix_exact']=(a.getnchannels(),a.getsampwidth(),a.getframerate())==(b.getnchannels(),b.getsampwidth(),b.getframerate())and a.readframes(a.getnframes())==b.readframes(a.getnframes())
r=rows(N/'first_irq_bus.csv');v=lambda x,k:int(x[k]);checks['all1701_exact_ticks']=[v(x,'tick')for x in r]==list(range(45731800,45733501))
accepted=[x for x in r if v(x,'transactions_after')>v(x,'transactions_before')]
stack=[x for x in accepted if v(x,'attrs_before')&4==0 and 0x20ff0<=v(x,'address_before')<0x21000]
records=[]
for x in stack:
 a=v(x,'address_before');mask=(0xff00 if v(x,'attrs_before')&2==0 else 0)|(0xff if v(x,'attrs_before')&1==0 else 0)
 before=v(x,f'stack_{a:06x}_before');after=v(x,f'stack_{a:06x}_after')
 records.append({'tick':v(x,'tick'),'address':a,'data':v(x,'dout_before'),'mask':mask,'actual_RAM_before':before,'actual_RAM_after':after,'committed_word_exact':(after&mask)==(v(x,'dout_before')&mask),'pc':v(x,'pc_before'),'IRD':v(x,'ird_before'),'microaddr':v(x,'microaddr_before')})
checks['stack_actual_RAM_commits_exact']=bool(records)and all(x['committed_word_exact']for x in records)
checks['first_PClo_SR_PChi_tick_address_data_exact']=all(any(x['tick']==t and x['address']==a and x['data']==d for x in records)for t,a,d in[(45732642,0x20ff6,0x7da),(45732850,0x20ff2,0x2000),(45732882,0x20ff4,0)])
checks['IACK_VPA_VMA_observed']=any(v(x,'attrs_after')&8 and v(x,'vpan_external_after')==0 and v(x,'vpai_after')==0 and v(x,'vma_n_after')==0 for x in r)
checks['wait_derivation_valid_all_edges']=all(v(x,'wait_derivation_valid_before')and v(x,'wait_derivation_valid_after')for x in r)
checks['waitbus_enables_microstates_observed']=any(v(x,'wait_bus_cycle_derived_before')==1 for x in r)and any(v(x,'nano_ir2ird_before')and v(x,'clks_before')&2 and v(x,'tstate_before')==4 and not v(x,'wclk_before')for x in r)
result={'checks':checks,'accepted':all(checks.values()),'arrays':arrays,'CSV':csvchecks,'unavailable_original_final56_arrays':unavailable,'original_snapshot_shared_frames_only':True,'stack_commits':records,'B16_closed':False,'physical_cause_proven':False,'limit':'Qualify source/no-guest-change and observercoverage before E/VPA interpretation. Newfinal56snapshots lack old61 final56reference; shared0/30snapshots compare exactly. MAMEearlyIRQrawretained, noMAMErerun.'}
(HERE/'qualification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'checks':checks,'accepted':result['accepted'],'qualification':pin(HERE/'qualification.json')}));raise SystemExit(0 if result['accepted']else 1)
