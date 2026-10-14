import csv, hashlib, json
from pathlib import Path

O=Path(__file__).resolve().parent
F=O/'p2_candidate_qualification_v7'
D=O/'native_observer181'
C=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,d): p.write_text(json.dumps(d,indent=2)+'\n')
def rows(p): return list(csv.DictReader(p.open(newline='')))
def val(s):
    try: return int(s,0)
    except ValueError: return int(s)
q=json.loads((F/'verification.json').read_text())
v=json.loads((D/'verification.json').read_text())
assert all(v[k] for k in ['native_applied_inputs_exact','reference_all181_frame_states_exact'])
assert len(v['native_all_snapshot_overlap'])==75 and len(v['reference_all5_completedPNG_RAM_exact'])==15
assert all(v==0 for v in v['actual_exits'].values())
for variant in ['baseline','candidate']:
    for job in ['build','run']:
        assert json.loads((F/variant/(job+'_exit.json')).read_text())['exit_code']==0
e=rows(F/'candidate/events.csv')
w=[r for r in e if val(r['shared_write'])]
assert [(val(r['shared_addr']),val(r['shared_data'])) for r in w]==[(255,255),(41,35),(41,34),(34,1)]
assert all(val(r['main_halt']) for r in w)
restore=[r for r in e if val(r['control_event']) and val(r['control_before'])==200 and val(r['control_after'])==216]
assert len(restore)>=4 and all(not val(r['main_halt']) for r in restore)
release=[r for r in e if val(r['control_event']) and val(r['control_after'])==200]
assert len(release)>=4 and all(not val(r['main_halt']) for r in release)
assert q['results']['baseline']['ready_restore_lost_events']>0
assert q['results']['candidate']['ready_restore_lost_events']==0
assert q['results']['candidate']['coinage_reply']==1

for n in ['SOURCE.json','LICENSE.upstream']:
    (F/n).write_bytes((C/'rtl/vendor/t48'/n).read_bytes())
source=json.loads((F/'SOURCE.json').read_text())
save(F/'SOURCE.proposed.json',{
    'upstream':source,
    'baseline_staged_core_sha256':sha(F/'baseline/t48_core.v'),
    'candidate_core_sha256':sha(F/'candidate/t48_core.v'),
    'candidate_wrapper_sha256':sha(F/'candidate/alpha68kn_mcu.sv'),
    'adaptation':'2026-10-11 Alpha68k N integration fork: export existing architectural P2 latch as enabled transaction data; consume it at existing delayed wrapper strobe. Preserve physical P2 pipeline, CPU/timer logic, clocks, ROM and original upstream license.',
    'license_notice':{'path':str(F/'LICENSE.upstream'),'sha256':sha(F/'LICENSE.upstream')},
    'scope':'Review proposal only; not a production SOURCE.json update.'})

n=rows(D/'capture/accepted_inputs.csv');m=rows(D/'mame181/accepted_reads.csv')
np=[r for r in n if val(r['frame'])==121 and val(r['main_pc']) in [5264,5272,5274] and val(r['address']) in [0x20044,0x80044]]
mp=[r for r in m if val(r['frame'])==122 and val(r['main_pc']) in [5264,5272,5274] and val(r['address']) in [0x20044,0x80044]]
assert len(np)==3 and len(mp)==3
proof={'native_matched_PC_reads':np,'MAME_matched_PC_reads':mp,'candidate_real_firmware_shared_writes':w,'candidate_real_firmware_ready_restores':restore,'candidate_real_firmware_halt_releases':release,'native_snapshot_overlap_artifact_count':75,'reference_original_overlap_artifact_count':15,'absolute_native_tick_origin':2943620,'input_phase_qualification':'Callback-derived after-snapshot CSV is a hypothesis. Actual official CPU reads first consume start128 at frame162/y240, while frame161/y240 consumes0. Coin accepted reads can retain active IN2=2 at frame127 although callback frame_states127 reports3. No replay adapter change is qualified.'}
save(F/'causal_proof.json',proof)
(F/'PROPOSAL.md').write_text('''# Super Stingray MCU P2 transaction proposal — 2026-10-11

The wrapper pairs an enabled decoder write strobe with delayed physical P2 pins. The genuine 8748 firmware restores its architectural P2 latch C8→D8 with ORL P2,#10, but the wrapper captures C8 one master tick later. It consequently loses the ready signal and discards the next main-CPU MCU command.

At the actual matched CPU PCs5264/5272/5274, MAME reads shared0x20044=0, accepts command0x80044, then reads shared0x20044=1. The unchanged native graph reads0, accepts the same command address, then still reads0. Native never produces shared address34 after that command. The relative and absolute native ticks are retained separately; absolute origin is2943620. The native source observer has no functional effect:75 overlapping native RGB/RAM artifacts and applied_inputs are exact;15 officialMAME PNG/RAM artifacts and all181 frame states match the immutable original reference. All real build/capture/run exits are0.

The proposed patch adds explicit T48 architectural P2 latch output ports and uses that transaction data at the existing wrapper pending strobe. It preserves physical p2_o, the T48 CPU/timer/clock enables, program ROM, main CPU, and shared RAM. The donor remains Arnim Laeuger's T48 via Jotego JTFRAME revision548b87b32a1b528a16cb41f689accb179e85d1a8; original notices are retained in LICENSE.upstream. SOURCE.proposed.json records the fork and source pins for production integration review.

The paired component fixture runs the same authentic1024-byte8748 ROM: ID initialization, real active-low coin pulse, accepted coin-detected status0x29?23, credit-ready status0x29?22, then coinage0x22 command. Both build/run exits are0. Baseline loses ready after the credit-ready status service and emits no following coinage-command reply. Candidate produces ID FF, statuses23 then22 and coinage01 at shared addressesFF/29/29/22, asserts HALT before each reply, releases HALT at real P2 bit4 deassertion, and reasserts ready afterward. This is component qualification, not a whole-game pass. Earlier fixture failures remain immutable: build2 rejected spaces; preparation guards failed before compiler; the ID-plus-coinage fixtures run1 omitted the real status acknowledgement required by firmware0x244..0x270. Long-gap single-status fixtures also show later genuine IRQ P2 writes can accidentally restore the baseline ready signal; the final fixture completes both real status acknowledgements before testing the following coinage command. Its host times qualify the transaction failure mechanism, not exact MAME scheduler timing.

The callback-derived input shift is not a proven replay bug. CPU-consumed start/coin samples contradict using callback values as field timing proof; preserve both CSVs and use the original prepared input phase unless a direct CPU-consumption comparison establishes otherwise. No adapter patch is proposed.

Next: independent review of candidate.patch and pins; one authorized181 gameplay run using CPU-consumed input phase, real MCU/CPU, prefix RGB/RAM checks, credits/start state, and completedPNG179. No1800-frame run until this succeeds. Production timing/resource checks remain required after integration; this scope makes no timing, hardware or release claim.
''')

paths=[F/'PROPOSAL.md',F/'candidate.patch',F/'verification.json',F/'causal_proof.json',F/'SOURCE.proposed.json',F/'SOURCE.json',F/'LICENSE.upstream',D/'verification.json',D/'ELF.json',D/'capture/accepted_inputs.csv',D/'capture/coin_samples.csv',D/'mame181/accepted_reads.csv',D/'mame181/observer_capture.lua',D/'alpha8511.disassembly.txt',D/'disassembly_exit.json',O/'observer181_worker_v2.py',O/'qualify_p2_candidate_v7.py',O/'freeze_p2_proposal_v3.py']
for variant in ['baseline','candidate']:
    paths += list((F/variant).glob('*.json'))+list((F/variant).glob('*.csv'))+list((F/variant).glob('*.log'))+[F/variant/n for n in ['alpha68kn_mcu.sv','t48_core.v','fixture.sv','main.cpp','mcu.hex']]
for name in ['build_exit.json','run_exit.json','mame181_exit.json','preparation.json']:
    p=D/name
    if p.exists():paths.append(p)
resolved=[];missing=[]
for p in paths:
    if p.exists():resolved.append(p);continue
    matches=list(D.rglob(p.name))
    if len(matches)==1:resolved.append(matches[0])
    else:missing.append(str(p))
assert not missing, missing
paths=sorted(set(resolved),key=str)
manifest={'scope':'Readonly accepted-consumption diagnosis plus reviewable minimal P2 transaction-data proposal and paired genuine-firmware component qualification; no production or game pass.','prior_immutable_manifest':{'path':str(O/'import_manifest.json'),'sha256':sha(O/'import_manifest.json')},'files':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in paths]}
save(F/'import_manifest.json',manifest)
print(json.dumps({'manifest':str(F/'import_manifest.json'),'sha256':sha(F/'import_manifest.json'),'files':len(paths),'patch_sha256':sha(F/'candidate.patch'),'candidate_core':sha(F/'candidate/t48_core.v'),'candidate_wrapper':sha(F/'candidate/alpha68kn_mcu.sv'),'shared_writes':[(r['shared_addr'],r['shared_data']) for r in w]}))
