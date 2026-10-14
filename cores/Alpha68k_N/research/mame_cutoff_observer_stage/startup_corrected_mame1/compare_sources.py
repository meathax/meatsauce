from pathlib import Path
import json,csv,hashlib
HERE=Path(__file__).resolve().parent;OUT=HERE/'source_comparison';OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
M=OLD/'sim/captures/kyros/mame_startup_phase2/startup_reads.csv';N=OLD/'sim/captures/rtl/irq_startup_phase1/startup_bus.csv'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def rows(p):
 with p.open(newline='')as f:return list(csv.DictReader(f))
def lines(p,a,b):return [{'line':i,'text':s}for i,s in enumerate(p.read_text().splitlines(),1)if a<=i<=b]
assert json.loads((HERE/'qualification.json').read_text())['accepted']
assert sha(HERE/'import_manifest.json')=='24e1c4f797cfe800e8147a7a6bc0ba25b449c21d6e24b026c150fe4cb18a7e0f'
assert not OUT.exists();OUT.mkdir()
m=rows(M);n=rows(N);v=lambda r,k:int(r[k])
aset=[r for r in n if v(r,'asn_before')==1 and v(r,'asn_after')==0]
ird=[r for r in n if v(r,'ird_before')!=v(r,'ird_after')]
joined=[]
assert len(m)==58 and len(aset)==57
for r,c in zip(aset,m):
 assert v(r,'address_after')==v(c,'address')
 # Compare data at the actual board acceptance row, distinct from AS assertion.
 accepted=next(x for x in n if v(x,'tick')>v(r,'tick')and v(x,'transactions_after')>v(x,'transactions_before'))
 assert v(accepted,'address_before')==v(c,'address')and v(accepted,'din_after')==v(c,'data')
 joined.append({'address':v(c,'address'),'data':v(c,'data'),'native_AS_tick':v(r,'tick'),'native_accept_tick':v(accepted,'tick'),'MAME_actual_callback_tick':v(c,'machine_ticks'),'callback_minus_AS':v(c,'machine_ticks')-v(r,'tick'),'callback_minus_accept':v(c,'machine_ticks')-v(accepted,'tick')})
fx=OLD/'rtl/vendor/fx68k/fx68k.sv';sdf=Path(r'D:\Arcade\AI\mame289\src\devices\cpu\m68000\m68000-sdf.cpp');cpp=sdf.parent/'m68000.cpp';board=OLD/'rtl/alpha68kn_board.sv'
st=sdf.read_text();reset=st.split('void m68000_device::state_reset_df()')[1].split('void m68000_device::state_bus_error_df()')[0]
region=reset.split('// 34c mmrw3')[1].split('m_edb = m_opcodes.read_interruptible')[0]
assert 'm_ird = m_ir;'in region and 'm_icount'not in region
first402=next(r for r in m if v(r,'address')==0x402)
assert v(first402,'inst_state')==0 and v(first402,'inst_substate')==0
first=ird[0];assert v(first,'ird_after')==v(first402,'ird')==0x323c
assert v(first,'clks_before')&2 and v(first,'tstate_before')==4 and v(first,'wclk_before')==0 and v(first,'nano_ir2ird_before')==1
en=[r for r in n if(v(r,'clks_before')&2)and v(r,'tstate_before')==4 and not v(r,'wclk_before')]
report={'checks':{'all57_common_reset_prefetch_loop_addresses_data_order_exact':True,'all57_callback_minus_native_AS_minus42':all(r['callback_minus_AS']==-42 for r in joined),'all57_callback_minus_native_accept_minus43':all(r['callback_minus_accept']==-43 for r in joined),'source_bounded_first_MAME_IRD_assignment_before402_without_cycle_charge':True,'native_first_IRD_exact_enT1_Nanod_enable':True},'joined':joined,'MAME_one_unmatched_tail_callback':m[len(aset):],'unmatched_tail_limit':'The MAME2031 callback would correspond to nativeAS2073 if42offset continued; native observer ends2048, so this tail is not qualified or extrapolated.','first_IRD':{'native_actual_postedge_tick':v(first,'tick'),'native_value':v(first,'ird_after'),'MAME402_read_callback_actual_machine_tick':v(first402,'machine_ticks'),'MAME_IRD_getter_at_callback':v(first402,'ird'),'native_minus_callback_ticks':v(first,'tick')-v(first402,'machine_ticks'),'source_contract':'MAME state_reset_df at micro34c assignsIRD fromIR, then computes status and read_interruptible402; no m_icount debit between assignment and callback. Assignment shares virtual CPUlocal-time bin with callback when this full reset handler runs. This is source-bounded emulated-time equivalence, not a physical IRD edge measured by the tap. NativeIRD changes at exact clockedge with enT1 and Nanod.Ir2Ird qualified.'},'first_native_execution_micro_samples':[{'tick':v(r,'tick'),'microaddr_before':v(r,'microaddr_before'),'microaddr_after':v(r,'microaddr_after'),'nanoaddr_before':v(r,'nanoaddr_before')}for r in en[:10]],'native_first_sample':n[0],'source_contracts':{'MAME_reset':[pin(sdf),lines(sdf,120,169)],'native_IRD':[pin(fx),lines(fx,317,324)],'native_microcycle_enable':[pin(fx),lines(fx,174,179)],'native_phase_reset':[pin(board),lines(board,216,235)],'MAME_opcode_space_and_reset':[pin(cpp),lines(cpp,225,243),lines(cpp,398,423)]},'phase_origin_conclusion':'Initial native/MAME busoffset42 is constant through resetvectors, firstprefetch and bootloop within2048ticks. The later previouslyaccepted ordinaryloop offset66 is24ticks larger, so the complete lateoffset is not solely initialresetepoch/powerwait. This capture does not include the transition. Startup ordinarywaits/loop intervals show no accumulating drift; no CPUclock or IRQgate patch is justified.','responsible_layer_or_fix':'No guest fix yet. First source-only candidate is locate the first microinstruction/transfer producing the additional24ticks in retained intermediateboot evidence, comparing exactaddress/data/order and sourcecycleplacement; do not tune clocks or IRQeligibility to force latercutoff alignment.','B16_closed':False,'physical_cause_proven':False,'new_guest_replay':False,'callback_IRD_not_presented_as_physical_edge':True}
assert all(report['checks'].values())
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
manifest={'accepted':True,'raw_binding':[pin(M),pin(N)],'corrected_pair_binding':pin(HERE/'import_manifest.json'),'files':[pin(OUT/'report.json'),pin(Path(__file__))],'B16_closed':False}
(OUT/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'manifest':pin(OUT/'import_manifest.json'),'checks':report['checks'],'firstIRD':report['first_IRD'],'first_enT1_samples':report['first_native_execution_micro_samples'],'joined_rows':len(joined),'no_guest_patch':True}))
