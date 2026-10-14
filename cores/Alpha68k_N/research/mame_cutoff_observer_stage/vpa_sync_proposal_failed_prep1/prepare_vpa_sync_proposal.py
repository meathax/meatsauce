import csv
import difflib
import hashlib
import json
from pathlib import Path

stage = Path(__file__).resolve().parent
old = stage.parent.parent
out = stage / 'vpa_sync_proposal1'
assert not out.exists(), 'Frozen proposal already exists; do not overwrite'
private = Path('D:/vibes/fpga/temp/mame289-irq-cutoff-private')
cpp = private / 'src/devices/cpu/m68000/m68000.cpp'
pe = private / 'kyros_irqcut.exe'
def pin(p):
    data = p.read_bytes()
    return {'path': str(p), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
private_pin = pin(pe)
assert private_pin['sha256'] == 'cb9ac0f56d97ac0cac97190b2e9e028fa68f7dc9c19235d9b3e364387c218c6d'
original = cpp.read_bytes()
text = original.decode('utf-8')
start = text.index('u64 m68000_device::vpa_sync(offs_t, u64 current_time)')
end = text.index('\nu32 m68000_device::vpa_after', start)
body = text[start:end]
assert body.count('return m_last_vpa_time;') == 2
observer = '''
\t// BEGIN PRIVATE READONLY VPA REQUEST/RETURN OBSERVER
\tconst u64 observe_previous_vpa = m_last_vpa_time;
\tconst auto observe_vpa = [this, current_time, observe_previous_vpa](u64 result) -> u64 {
\t\tif (!strcmp(tag(), ":maincpu") && current_time >= 5500000 && current_time <= 6200000)
\t\t\tlogerror("IRQ_VPA,%llu,%llu,%llu,%llu,%llu,%d,%llu,%llu,%u,%u,%u,%u,%u,%u,%u,%u,%u\\n",
\t\t\t\tstatic_cast<unsigned long long>(current_time),
\t\t\t\tstatic_cast<unsigned long long>(observe_previous_vpa),
\t\t\t\tstatic_cast<unsigned long long>(result),
\t\t\t\tstatic_cast<unsigned long long>(current_time % 10),
\t\t\t\tstatic_cast<unsigned long long>(total_cycles()), m_icount,
\t\t\t\tstatic_cast<unsigned long long>(local_time().as_ticks(48000000)),
\t\t\t\tstatic_cast<unsigned long long>(machine().time().as_ticks(48000000)),
\t\t\t\tm_pc, m_ipc, m_ir, m_ird, m_irc, m_sr, m_int_level, m_int_next_state, m_next_state);
\t\treturn result;
\t};
\t// END PRIVATE READONLY VPA REQUEST/RETURN OBSERVER
'''
changed_body = body.replace('{\n', '{\n'+observer, 1).replace('return m_last_vpa_time;', 'return observe_vpa(m_last_vpa_time);')
restored = changed_body.replace(observer, '').replace('return observe_vpa(m_last_vpa_time);', 'return m_last_vpa_time;')
assert restored == body
candidate = text[:start]+changed_body+text[end:]
assert candidate.replace(observer, '').replace('return observe_vpa(m_last_vpa_time);', 'return m_last_vpa_time;').encode('utf-8') == original

mame = old / 'sim/captures/kyros/mame_cutoff_observer61'
native = old / 'sim/captures/rtl/irq_sampling_edge_latch61'
def csvrows(p):
    with p.open(newline='') as f:
        return list(csv.DictReader(f))
miacks = csvrows(mame/'cpu_space_iack.csv')
niacks = [r for r in csvrows(native/'epoch_events.csv') if r['iack'] == '1']
assert len(miacks) == len(niacks) == 10
matched = []
for m,n in zip(miacks,niacks):
    assert int(m['address']) == int(n['address'])
    assert int(m['next_pc']) == int(n['data_out'])
    matched.append({'frame': int(n['frame']), 'address': int(n['address']),
                    'stack_PC_low': int(n['data_out']), 'native_board_accept_tick': int(n['tick']),
                    'MAME_after_before_time_callback_tick': int(m['master_ticks']),
                    'MAME_CPU_callback_ticks': int(m['cpu_ticks']),
                    'boundary_note': 'Board IACK bookkeeping acceptance is not CPU completion or MAME callback-equivalent'})
events = csvrows(mame/'events.csv')
mwrites = [r for r in events if 0x20000 <= int(r['address']) <= 0x20fff]
nr = csvrows(native/'instruction_events.csv')
nwrites = [r for r in nr if r['rw']=='0' and 0x20000 <= int(r['address']) <= 0x20fff]
ep = csvrows(native/'e_phase.csv')
native_AS = [r for r in ep if int(r['attrs_before'])&4 and not(int(r['attrs_after'])&4)]
write_table_path = stage/'startup_corrected_mame1/retained_write_intervals/report.json'
write_table = json.loads(write_table_path.read_text())
prefix = write_table['exact_address_mask_data_order_prefix']
intervals=[]
for idx,(m,n) in enumerate(zip(miacks,niacks)):
    mt,nt = int(m['master_ticks']),int(n['tick'])
    ml = [r for r in mwrites if int(r['address'])==0x20ff6 and 0 <= mt-int(r['master_ticks']) <= 300 and int(r['data'])==int(n['data_out'])]
    ms = [r for r in mwrites if int(r['address'])==0x20ff2 and 0 <= int(r['master_ticks'])-mt <= 200]
    assert len(ml)==1 and len(ms)==1, (idx,'MAME stack coverage')
    if idx < 2:
        nl = [r for r in prefix if r['address']==0x20ff6 and 0 <= nt-r['native_tick'] <= 100 and r['data']==int(n['data_out'])]
        ns = [r for r in prefix if r['address']==0x20ff2 and 0 <= r['native_tick']-nt <= 300]
        if len(nl)==len(ns)==1:
            ntl,nts=nl[0]['native_tick'],ns[0]['native_tick']
            native_bound='acceptedRAMcommit; firstIRQ57 independently proves fixed9ticksAS→commit'
        else:
            ntl=nts=None
            native_bound='missing accepted stack writes'
    else:
        nl = [r for r in nwrites if int(r['address'])==0x20ff6 and 0<=nt-int(r['tick'])<=100 and int(r['data_out'])==int(n['data_out'])]
        ns = [r for r in nwrites if int(r['address'])==0x20ff2 and 0<=int(r['tick'])-nt<=300]
        ntl,nts=(int(nl[0]['tick']),int(ns[0]['tick'])) if len(nl)==len(ns)==1 else (None,None)
        native_bound='accepted CPU observer bus record; AS joined separately'
    mtl,mts=int(ml[0]['master_ticks']),int(ms[0]['master_ticks'])
    item={'IACK_index':idx,'frame':int(n['frame']), 'MAME_PClo_to_SR_callbacks':mts-mtl,
          'native_accepted_PClo_tick':ntl,'native_accepted_SR_tick':nts,
          'native_boundary_contract':native_bound,
          'MAME_PClo_callback_tick':mtl,'MAME_SR_callback_tick':mts}
    if ntl is not None:
        item.update(native_PClo_to_SR=nts-ntl, native_minus_MAME_interval=(nts-ntl)-(mts-mtl),
                    callback_minus_native_accept_before=mtl-ntl, callback_minus_native_accept_after=mts-nts)
        aslo=[r for r in native_AS if int(r['address_before'])==0x20ff6 and abs(int(r['tick'])-ntl)<=12]
        assr=[r for r in native_AS if int(r['address_before'])==0x20ff2 and abs(int(r['tick'])-nts)<=12]
        if len(aslo)==len(assr)==1:
            item.update(native_PClo_AS_tick=int(aslo[0]['tick']),native_SR_AS_tick=int(assr[0]['tick']),
                        native_PClo_AS_to_SR_AS=int(assr[0]['tick'])-int(aslo[0]['tick']))
    intervals.append(item)
join={'ten_IACKs_order_address_saved_PC_low_exact':matched, 'source_qualified_stack_intervals':intervals,
      'scope_limit': 'Native fullstack-write observers absent at IRQs2..5(frame57/58). Firsttwo56 matched prefix and laterfour59/60 observer records are finite, not continuous coverage.',
      'three_plus8_proven':False,'no_extra_runs':True,'no_CPU_clock_IRQ_patch':True,
      'native57_exact_source_bound':pin(stage/'first_irq_native57_released1/compact_cause/import_manifest.json'),
      'retained_write_interval_pin':pin(write_table_path),
      'input_pins':[pin(mame/'cpu_space_iack.csv'),pin(mame/'events.csv'),pin(native/'epoch_events.csv'),pin(native/'instruction_events.csv'),pin(native/'e_phase.csv')]}
out.mkdir()
(out/'m68000.cpp.original').write_bytes(original)
(out/'m68000.cpp.candidate').write_bytes(candidate.encode('utf-8'))
(out/'observer.patch').write_text(''.join(difflib.unified_diff(text.splitlines(True),candidate.splitlines(True),fromfile='a/src/devices/cpu/m68000/m68000.cpp',tofile='b/src/devices/cpu/m68000/m68000.cpp')),encoding='utf-8')
(out/'existing_IACK_join.json').write_text(json.dumps(join,indent=2)+'\n',encoding='utf-8')
proposal={'purpose':'Minimal CPU-local vpa_sync request/return observer; source-only, no build/runtime release',
          'observer_fields':['request_current_time','previous_last_vpa_time','return_cycle','request_cycle_mod10','total_cycles_at_callback','icount','CPU_local_time_as48MHz_ticks','machine_time_as48MHz_ticks','PC','instruction_PC','IR','IRD','IRC','SR','interrupt_level','pending_state','next_state'],
          'observer_admission':'Private maincpu only, request5500000..6200000 CPUcycles; append logerror only; lambda returns original exact result; no state getter export/import, timer, IRQ, memory, cycle or phase writes.',
          'unchanged_function_restoration_byte_exact':True,'header_generated_microcode_unchanged':True,
          'original_private_CPP':pin(cpp),'original_private_PE':private_pin,
          'manual_manifest':pin(stage/'manual_e_vpa/import_manifest.json'),
          'build_policy':'No build or runtime authorized by preparation. Future isolated private source/build workspace must preserve this original source/PE and official0.289 binary/source. Reuse reviewed UCRT64 minimal alpha68k_n -j2 compile/link recipe only after root sourcepins review; no hardlink edits, giantrepo copy or direct POSIX invocation.',
          'future_run_scope':'At most one cloned qualified61 private MAME run with unchanged qualified ROM/input/capture hooks; no native replay needed. Compare all original arrays/CSV/audio and rawIRQcutoffs before interpreting IRQ_VPA; required logger rows map exactly to ten alreadyjoinedIACKs and return/result unchanged.',
          'not_claimed':'Physical power-onEphase or donor defect; three+8 account of24 ticks; currentcanonical complete-game qualification',
          'actual_builds':0,'actual_guest_runs':0,'guest_timing_patch':False,'root_runtime_release':False}
(out/'proposal.json').write_text(json.dumps(proposal,indent=2)+'\n',encoding='utf-8')
entries=[pin(p) for p in out.iterdir()]+[pin(Path(__file__))]+join['input_pins']+[proposal['manual_manifest'],proposal['original_private_CPP'],private_pin]
manifest={'immutable_source_only_proposal':True,'entries':entries,'original_CPP_PE_unchanged':True,'decisive_preparation_exit':0}
(out/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
assert all(pin(Path(p['path']))==p for p in entries)
assert cpp.read_bytes()==original and pin(pe)==private_pin
print(json.dumps({'actual_preparation_exit':0,'manifest':pin(out/'import_manifest.json'),'candidate':pin(out/'m68000.cpp.candidate'),'observerpatch':pin(out/'observer.patch'),'intervals':intervals,'alltenIACKs_exact':True,'builds':0,'guest_runs':0},separators=(',',':')))
