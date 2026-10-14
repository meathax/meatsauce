"""Freeze the completed single VPA build/replay; never launch a guest or build."""
from pathlib import Path
import hashlib, json

BASE = Path(__file__).resolve().parent
RECIPE = BASE / 'vpa_overlay_recipe1'
OUT = RECIPE / 'terminal_freeze1'
CAPTURE = BASE.parents[1] / 'sim/captures/kyros/mame_vpa_sync61'

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def pin(path):
    return {'path': str(path), 'bytes': path.stat().st_size,
            'sha256': hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()}

def save(name, value):
    (OUT/name).write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8')

assert not OUT.exists(), 'Frozen namespace already exists; do not overwrite or rerun.'
qual = read(RECIPE/'corrected_consumer3/qualification.json')
assert qual['PASS'] and len(qual['checks']) == 13 and all(qual['checks'].values())
assert read(RECIPE/'build_exit.json')['exit_code'] == 0
assert read(RECIPE/'mame_exit.json')['exit_code'] == 0
assert read(RECIPE/'mame_exit.json')['guest_runs'] == 1
assert read(RECIPE/'worker_exit.json')['exit_code'] == 1
assert read(RECIPE/'qualifier_exit.json')['exit_code'] == 1
assert read(RECIPE/'corrected_consumer1/exit.json')['exit_code'] == 1
assert read(RECIPE/'corrected_consumer2/exit.json')['exit_code'] == 1
assert read(RECIPE/'corrected_consumer3/exit.json')['exit_code'] == 0
rows = qual['raw_VPA_records']
assert len(rows) == 10
assert [r['request_cycle_mod10'] for r in rows] == [8,5,3,7,3,5,5,3,5,3]
assert [r['return_cycle']-r['request_cycle'] for r in rows] == [12,5,7,13,7,5,5,7,5,7]
OUT.mkdir()
save('unit_map.json', {
    'raw_VPA_records': rows, 'actual_rowmap': qual['actual_rowmap'],
    'contracts': {
        'request_return': 'MAME CPU total-cycle accounting; returned value is the synthetic E-aligned completion boundary, not an observed native AS/DS edge.',
        'local_machine': 'Actual device-local and scheduler-machine as_ticks(48000000) exported independently; their equality is observed only at these ten callbacks.',
        'native_edges': 'Native57 actual 48MHz AS/DS/E/VPA/wClk events, relative to its retained reset/load epoch.',
        'callback': 'MAME read/write tap callbacks have their own instruction/prefetch schedule; IRD getters are snapshots, not IR-to-IRD transfer edges.',
        'active_irq': 'Source-backed active service level comes from SR_I and m_next_state; raw m_int_level is retained current IPL input and can be zero during service.',
    },
    'first_matched_boundaries': {
        'MAME_PClo_write_callback_ticks': 45732591,
        'MAME_VPA_request_local_and_machine_ticks': 45732623,
        'MAME_IACK_callback_ticks': 45732719,
        'MAME_SR_write_callback_ticks': 45732791,
        'native_PClo_AS_ticks': 45732633,
        'native_IACK_AS_ticks': 45732665,
        'native_SR_AS_ticks': 45732841,
        'PClo_to_request_or_AS_masterticks': {'MAME':32,'native':32},
        'request_or_AS_to_SR_masterticks': {'MAME':168,'native':176,'difference':8},
        'native_AS_minus_MAME_callback_masterticks': {'PClo':42,'SR':50,'PChi':50},
    },
    'native_first_IACK_edges': {
        'AS_fall':45732665, 'missed_old_counter3_to4_gate':45732669,
        'registered_Vpai_low':45732673, 'next_old_counter3_to4_gate':45732749,
        'xVMA_rise':45732781, 'xVMA_fall':45732789, 'wClk_clear':45732793,
        'AS_rise':45732797, 'VMA_release_counter0':45732801,
        'limit':'xVMA is not completion: iStop is registered on Phi2 and waitBusCycle has a separate source contract.',
    },
})
save('report.json', {
    'scope':'ONE isolated incremental private MAME build and ONE unchanged Kyros61 replay, then read-only qualification repairs; no native rerun, guest timing changes, RTL changes or RBF.',
    'actual_exits':{'compile':0,'archive':0,'link':0,'build':0,'MAME':0,'original_qualifier':1,'original_worker':1,'corrected_consumer1':1,'corrected_consumer2':1,'corrected_consumer3':0},
    'actual_PIDs':{'controller_worker':8108,'compile':23704,'archive':37908,'link':54016,'MAME':42332},
    'jobs':{'compile':1,'archive':1,'link':1,'MAME_replay':1},
    'accepted_checks':qual['checks'],
    'accepted_guest_scope':'12 original CSVs; all nine full RGB/work/sprite arrays at fields0/30/60; audio PCM; original Lua; all130 original IRQ cutoff records. Frozen baseline mame_cutoff_observer61 is unchanged.',
    'observer_scope':'17 read-only fields; ten request/return groups inside5500000..6200000 mainCPUcycles; original VPA branch/results preserved exactly.',
    'failure_history':{
        'original':'Raw current m_int_level was incorrectly treated as the active IACK service level. Original pin-dictionary predicate failed, but did not retain per-pin differences; its exact first-time cause is unavailable.',
        'consumer1':'Relocated generated qualifier resolved HERE into the wrong nested recipe directory; genuine consumer exit1 preserved.',
        'consumer2':'Source-correct active SR/next-state mapping passes. Fresh per-pin comparisons retain157 full expected/actual pairs with equal bytes/SHA and only path separator differences. This does not retroactively prove original first-time mismatches.',
        'consumer3':'Only path separators are normalized for target identity; SHA/bytes remain exact. All13 checks pass with an empty mismatch list. Existing guest capture reused.',
        'tool_limits':'Capsule reported EPERM after consumer1/2 executions; durable actual exit receipts control status. No duplicate guest was launched.',
    },
    'isolation':'New CPP/object/dependency/archive/PE/tmp outputs only. Original private CPP/PE, PCH, official MAME source/PE, original archives and baseline captures remain byte-pinned. Unique m68000.o archive replacement; every other non-symbol member body/order unchanged.',
    'responsible_layer_finding':'First extra8 masterticks localizes to IACK E/VPA service, after matching32-tick PClo-to-IACK-request intervals. Native IACK AS-to-SR AS176 versus MAME VPA-request-to-SR-callback168. Ordinary stackwrite AS-to-DS8 and DS-to-acceptedRAMcommit1 do not explain it.',
    'source_hypothesis':'MAME uses synthetic CPU-cycle modulo10 E synchronization; native FX68K uses free-running Ecounter plus registered VPA/iStop/bus completion. This is an E-phase/sample/callback convention candidate, not a proven donor or PCB defect. The primary MC68000 manual leaves initial power-on E/CLK phase unspecified.',
    'minimum_candidate':'Do not retime the CPU or phase-fit to pixels. A board-level VPA decoder correction is justified only if the actual PCB FC/AS/VPA contract or waveform establishes a mismatch with current !ASn&&FC7 generation. A donor change requires a demonstrated violation of the manual sampling/completion contract. Neither is established here.',
    'remaining_evidence':'Additional24 masterticks from initial42 to later66 remains open: native stack evidence is absent for four frame57/58 IACKs. Available later +64 is a separate phase, with different-PC limits on two earlier pairs; it cannot prove three +8 increments. Physical board timing is not qualified.',
    'gate_limits':'B16 strict RAM/CPU timing remains OPEN. Native57 is the retained historical69 temporal graph, not current43b complete-game proof. No claim of MiSTer/PCB fidelity, complete-game closure or graphics-pixel cause follows from this finite observer.',
    'next_action':'Root source-only independent E/VPA physical-contract review; retain original evidence and unresolved gates before selecting any RTL correction.',
})
paths = [p for p in RECIPE.rglob('*') if p.is_file() and OUT not in p.parents]
paths += [p for p in CAPTURE.rglob('*') if p.is_file()]
paths += [BASE/'vpa_sync_proposal2/import_manifest.json', BASE/'vpa_sync_proposal2/m68000.cpp.candidate', BASE/'vpa_sync_proposal2/observer.patch', BASE/'first_irq_native57_proposal/source_contract.json', BASE/'first_irq_native57_released1/compact_cause/import_manifest.json', BASE/'first_irq_native57_released1/compact_cause/report.json', BASE/'manual_e_vpa/import_manifest.json', BASE/'ordinary61/import_manifest.json', Path(__file__).resolve(), OUT/'unit_map.json', OUT/'report.json']
entries = [pin(p) for p in sorted(set(paths), key=str)]
save('import_manifest.json', {'entries':entries,'guest_runs':1,'native_runs':0,'new_builds':1,'new_guest_runs_in_freeze':0,'status':'accepted readonly consumer3; original worker/qualifier failed1 retained','B16':'OPEN'})
# One decisive bounded verification of this new terminal graph. Do not re-run guest jobs.
bad=[]
for item in entries:
    actual=pin(Path(item['path']))
    if actual != item: bad.append({'expected':item,'actual':actual})
assert not bad, bad
result={'exit_code':0,'PASS':True,'manifest':pin(OUT/'import_manifest.json'),'entries_verified':len(entries),'checks':13,'actual_build':0,'actual_MAME':0,'original_worker':1,'corrected_consumer3':0,'guest_runs':1,'B16':'OPEN'}
save('freeze_verification.json', result)
print(json.dumps(result))
