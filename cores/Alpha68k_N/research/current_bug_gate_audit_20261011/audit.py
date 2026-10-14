"""Bounded, read-only source/evidence audit. Writes only this evidence directory."""
import hashlib
import json
from pathlib import Path

OLD = Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
CORE = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
OUT = Path(__file__).resolve().parent

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def pin(path):
    return {'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size}

# Tuple fields: ID, classification, finite decisive evidence, current scope,
# minimal remaining gate, evidence handles. No pending run becomes a pass.
ROWS = [
('B01','Confirmed historical MAME defect; fixed in 0.281 / MT01148',
 'Both Kyros sets: five complete late-room renderer fields each, zero RGB differences; CLUT255 suppression changes 500 pixels in each negative probe.',
 'Required finite renderer regression is qualified on its pinned renderer; it is a fixture, not real CPU progression.',
 'Retain corrected CLUT255 predicate; reuse fixtures after affected-source parity. Real CPU attract/gameplay remains the separate P7 gate. Natural stage-5 playthrough is not an additional required gate.',
 ['research/kyros_late_scene_contract_audit.json','research/kyros_candidate5_lastroom_renderer_verification.json','research/kyrosj_candidate5_lastroom_renderer_verification.json']),
('B02','Original behavior / MT01149 closed BTANB',
 'Five ending renderer fields exactly match MAME and show characters covering staff text, with original strip overwrite priority.',
 'Required finite ending fixture qualified; no speculative priority patch.',
 'Preserve strip priority and source parity. Natural CPU progression to ending is unproven but is not an added plan gate.',
 ['research/kyros_late_scene_contract_audit.json','research/kyros_ending_renderer_verification.json']),
('B03','Confirmed historical MAME regression; fixed 0.138u3 / MT03912',
 'Actual 1081-field punch/release: all 2750 chip writes match; AY2-B noise ends at 733. Finite active-noise reset has 20 strict checks and silence over the measured reset window.',
 'Qualified finite cleanup/reset composition on earlier pins. Japan joined720 has exact 406 chip writes, 29549 DAC writes and nine latch writes, but whole replay strict RAM fails.',
 'Bind applicable cleanup/reset and death-animation behavior to final graph. Complete semantic action/reset audio coverage and measured rates/mix; do not demand phase-identical MAME/JT PCM.',
 ['research/kyros_punch_release1081_native_noise_cleanup.json','research/kyros_active_noise_reset_v3_verification.json','research/remaining_gates_20261011/japan_joined720/canonical_v2_import_manifest.json']),
('B04','Confirmed historical missing-effects regression; fixed 0.164 / MT05959',
 'Separate vblank sound IRQ and 4kHz NMI implemented. Existing combat evidence proves actual jumps and hits; masked latch/DAC/chip order audits exist.',
 'Finite sound semantics are stronger than counters alone; ordinary pickup command53 is still absent from qualified existing combat/reference samples.',
 'After owned final Kyros run terminates, use one bounded legal pickup route and its minimum native replay. Reuse current action/audio traces; qualify Stingray action/explosion semantics in its legal replay.',
 ['research/audio_acceptance_20261011/pickup_target/preparation_manifest.json']),
('B05','Confirmed historical mixed-audio clipping; MT02099 / 2021 route-gain fix',
 'Wide signed mixing, MAME-relative level calibration and finite zero-rail PCM evidence exist.',
 'Digital finite calibration is qualified on its producer pins; exact chip-event order is not complete waveform or physical analog qualification.',
 'Bind corrected mix to final graph; verify active per-profile rates, relative levels and clipping in reused action captures. Physical listening remains final authorized hardware stage.',
 ['docs/AUDIO_NORMALIZATION.md','docs/YM_SSG_CURVE.md']),
('B06','Historical sound-chip/clock driver corrections, 0.242 era',
 'One YM2203 plus two AY chips; Kyros Z80 4MHz and Stingray 3579545Hz, sound chips 2MHz. Private embedded-SSG period-zero fix has 21 focused checks.',
 'Current canonical/shared baseline versus private final-joined P6/SSG graph must be kept distinct. The period-zero issue is a donor defect, not a new MAME bug.',
 'Integrate the reviewed SSG correction with retained donor notices/pins; verify final clock inventory and relevant rates. Reuse exact-event captures where source-cone parity proves applicability.',
 ['board_profiles.json','research/ym2203_ssg_pitch_stage/qualification.json','research/kyros_ssg_active_zero_audit/finite_qualification.json']),
('B07','Confirmed historical Stingray MCU/coinage MAME defects fixed in 2019',
 'Private real8748 firmware P2-latch correction passes paired coin/status/coinage fixture with proper HALT/ready replies. Rebound actual emu/HPS wrapper passes all14 finite checks.',
 'Real181 gameplay native exit0, all five completed PNGs/strip RAM exact and credit/start/38-command stream observed; strict work RAM still differs12 bytes and final consumer manifest is pending.',
 'Freeze current181 consumer result and diagnose strict RAM difference without classifying it as stale stack. Then qualify complete Stingray attract/gameplay, both coin slots/ratios, simultaneous handshake/IRQ and relevant runtime DIP/cabinet behavior on final graph.',
 ['research/stingray_game_divergence_20261011/p2_candidate_qualification_v7/import_manifest.json','research/wrapper_feature_gates_20261011/p2_rebind_v1/import_manifest.json']),
('B08','Historical Stingray PROM defect fixed 0.88u7',
 'All18 Stingray ROM/PROM files audited. Private actual181 matches five completed displayed PNGs exactly.',
 'Finite full-frame actual graphics evidence exceeds ROM-only audit; final production profile2 remains conditionally staged.',
 'Bind PROM/load/CLUT order to final graph and reuse qualified five-frame evidence; complete required gameplay and edge/palette/sentinel fixtures where not exercised.',
 ['research/rom_manifest.json','research/final_metadata_audit_20261011/import_manifest.json']),
('B09','Unresolved original Kyros MCU underdump / MAME HLE fidelity limit',
 'Raw full bootleg and partial original BAD_DUMP are independently staged; explicit MAME-compatible HLE follows observed transactions.',
 'No assertion of cycle-exact original firmware or physical MCU identity. HLE is an intentional documented compatibility strategy.',
 'Retain underdump/HLE limitation in final STATE/HACKS/MAME_KLUDGES/acceptance. A new firmware implementation or speculative repair is not required to complete MAME-compatible scope.',
 ['docs/HACKS.md','research/rom_manifest.json']),
('B10','MAME MACHINE_IMPERFECT_TIMING / unresolved Stingray MCU oscillator',
 'Private actual8748 uses baseline9263750Hz with internal divide-by15 counted once; genuine firmware responses and legal credits/start now observed.',
 'P2-latch interface repair does not measure or correct physical MCU timer speed.',
 'Qualify actual integrated timer/IRQ2 event periods against MAME and document baseline rate. Retain physical oscillator uncertainty absent matched Stingray board measurement.',
 ['board_profiles.json','docs/STINGRAY_MCU_INTERFACE.md','research/stingray_game_divergence_20261011/p2_candidate_qualification_v7/import_manifest.json']),
('B11','Driver source TODO/doubt: Stingray signed wrap/transparency',
 'Current formulas and sentinels retained; Kyros CLUT255 nonvacuous regression passes. Stingray five-frame native display agreement is finite.',
 'No confirmed new physical/MAME defect; full-frame agreement alone may not exercise wrap/sentinel/overlap boundaries.',
 'Reuse small focused edge/sentinel/overlap fixtures or prove coverage in current replay. Preserve baseline signed-X and pen-zero behavior unless board evidence supports an isolated alternative.',
 ['rtl/alpha68kn_renderer.sv','research/kyros_candidate5_lastroom_renderer_verification.json']),
('B12','Research discrepancy: explicit raw raster versus rounded older notes',
 'Native384x264/6MHz raster,256x224 full fields used. Private P2-rebound HPS wrapper produces complete fields while paused.',
 'Standard baseline161 full-design fit passes all7 caps and timed checks at all8 conditions; external IO/CDC hardware gate remains open. This is not final P6-source fit.',
 'Complete final native/scandoubled/rotation/CRT/flip framework qualification and source-bound P6/P8 fit+STA; constrain/review actual IO bounds without blanket false paths. Preserve physical sync/crystal tolerance limitation.',
 ['board_profiles.json','research/sound_write_width/case2_standard_fit_evidence/standard_fit_sta_import_manifest.json','research/timing_crossings_20261011/standard_review_import_manifest.json']),
('B13','Source modeling limits: ignored sound IO / analog DAC identity',
 'Actual3600 MAME writes access all five ignored IO ports. Finite SSG normalization and ordered DAC/chip audits are qualified.',
 'Preserving nopw/digital DAC is compatibility behavior; analog reconstruction and actual Stingray DAC identity remain unmeasured.',
 'Bind applicable per-profile access/event audit to final graph and retain ignored-port/analog limits. Do not infer an analog filter correction from digital-event equality.',
 ['research/kyros_sound_address_usage3600.json','docs/SOUND_ADDRESS_USAGE.md','docs/AUDIO_NORMALIZATION.md']),
('B14','Unconfirmed PCB capacity/mirroring discrepancy',
 'Actual3600 sound writes: lower1KiB2325198 writes/1991777 nonzero; upper1KiB exactly1024 zero writes, one per address.',
 'Virtual alias-value witnesses do not prove reads or original wiring. Current2KiB MAME sound RAM retained.',
 'Retain existing usage audit and explicit missing read/physical wiring evidence. No new alias patch, broad capture or hardware-capacity pass is required for this compatibility disposition.',
 ['research/kyros_sound_address_usage3600.json','docs/SOUND_ADDRESS_USAGE.md']),
('B15','Incomplete documented hardware behavior: watchdog byte modeled as RAM',
 'Separate MSB watchdog RAM and LSB background strobes at060000..060001 retained; finite warm-reset evidence exists.',
 'No actual watchdog circuit/period is proven; generic reset simulation does not qualify original watchdog hardware.',
 'Final byte-lane/reset audit and documented watchdog limit. Do not invent a watchdog period or reset circuit.',
 ['rtl/alpha68kn_board.sv','docs/MAME_CLOCKED_RESET_EVIDENCE.md']),
('B16','Measured source-model/capture temporal fidelity limit; no formal MAME bug',
 'Six combat HUD temporal cases qualified from measured earlier RAM writes; atomic final-frame failures preserved. Completed PNG normalization removes wrong drawing-buffer comparisons.',
 'Field60 timed18-pixel residual remains. Actual IRQ cutoffs and MOVE/DBRA stores differ in subphase/order; additional bounded ordinary-ROM/DTACK observer is being prepared.',
 'Diagnose first accepted/latch/IRQ temporal divergence with unchanged real CPU and source-backed API timestamps. Preserve atomic failures, Japan8-byte and Stingray12-byte strict RAM differences. No clock/IRQ phase fit, masks or fabricated state.',
 ['research/combat_hud_native_causality_through3300.json','research/mame_cutoff_observer_stage/terminal_import_manifest.json','research/mame_cutoff_observer_stage/move_boundary_cause_import_manifest.json','research/mame_cutoff_observer_stage/ordinary_cycle_coverage_import_manifest.json'])
]

MANIFESTS = {
 'research/sound_write_width/case2_standard_fit_evidence/standard_fit_sta_import_manifest.json': 'fb9e62a0013236e248a6f4be11f056171755dabe7bfe52cd66ca43689fecfb90',
 'research/timing_crossings_20261011/standard_review_import_manifest.json': 'f01da1c69814ac60fcefa9638006cb2626dad66d8f589488498e3dcb7fd941a1',
 'research/wrapper_feature_gates_20261011/p2_rebind_v1/import_manifest.json': '7e71037b75f6e424017a4958e2078ce007a534cc131888cb0a38ba9e2a417673',
 'research/stingray_game_divergence_20261011/p2_candidate_qualification_v7/import_manifest.json': 'bc0af87993a78ba9ce95127f50b5324a5749e605b9c0227a9b138f92fa255334',
 'research/remaining_gates_20261011/japan_joined720/canonical_v2_import_manifest.json': 'b4e102521239681a5d41957a27850cb7f8e33d0aabb928444f1b6c511e4e3484',
}

def resolve(handle):
    canonical = CORE / handle
    if canonical.is_file():
        return canonical
    local = OLD / handle
    if local.is_file():
        return local
    raise FileNotFoundError(handle)

def main():
    assert [r[0] for r in ROWS] == [f'B{i:02}' for i in range(1,17)]
    input_paths = [CORE / p for p in ['mamebug.md','plan.md','progress.md','donormap.md','docs/bug_coverage.json']]
    evidence_paths = set()
    missing = []
    rows = []
    for ident, kind, evidence, scope, remaining, handles in ROWS:
        resolved = []
        for handle in handles:
            try:
                path = resolve(handle)
                resolved.append(pin(path))
                evidence_paths.add(path)
            except FileNotFoundError:
                missing.append(handle)
        rows.append({'id':ident,'classification':kind,'decisive_finite_evidence':evidence,'scope_and_status':scope,'minimal_remaining_gate':remaining,'evidence':resolved,'full_all_game_acceptance':False})
    assert not missing, missing
    verified = 0
    for handle, expected in MANIFESTS.items():
        path = OLD / handle
        assert sha(path) == expected, handle
        evidence_paths.add(path)
        obj = json.loads(path.read_text(encoding='utf-8-sig'))
        for key in ['files','reports','entries','small_import_files']:
            for item in obj.get(key, []):
                if not isinstance(item,dict) or 'path' not in item or 'sha256' not in item:
                    continue
                leaf = Path(item['path'])
                if not leaf.is_absolute():
                    leaf = path.parent / leaf
                assert leaf.is_file(), str(leaf)
                assert sha(leaf) == item['sha256'], str(leaf)
                assert 'bytes' not in item or leaf.stat().st_size == item['bytes'], str(leaf)
                verified += 1
    data = {'schema':'bounded_bug_gate_audit_v1','date':'2026-10-11','production_changes':False,'builds_replays_hardware_launched':False,'catalogue_complete':True,'coverage_complete':False,'source_lanes':{'canonical':'Current committed baseline with sound inference guard; profile2 still gated.','joined':'75-source real-CPU graph; Kyros4401 live, Japan720 terminal with strict RAM difference.','p2_candidate':'Reviewed two-file T48 logical-latch export/wrapper consumption; finite component and actual HPS wrapper qualified, Stingray181 strict RAM open.','fit':'Independent161-source standard full-design baseline, all7 resource caps and8 native timed corners pass; external IO/CDC and final P6 fit remain open.'},'rows':rows,'producer_manifest_leaf_pins_verified':verified}
    (OUT/'coverage.json').write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    lines = ['# Current B01-B16 acceptance audit','', 'Evidence-only audit, 2026-10-11. No source changes, builds, new replays, hardware or web search. Every status is finite and source-bound; catalogue completeness does not imply all-game acceptance.','', '| ID | Classification | Current decisive evidence / scope | Minimal remaining gate |','|---|---|---|---|']
    for row in rows:
        lines.append('| '+ ' | '.join([row['id'],row['classification'],row['decisive_finite_evidence']+' '+row['scope_and_status'],row['minimal_remaining_gate']])+' |')
    lines += ['', 'Exact source and evidence handles/hashes are in coverage.json and import_manifest.json. Producer manifests retain large capture/report recovery handles. The audit verifies their listed primary leaf pins without rerunning any simulation.','', 'Japan720: all six displayed frames/strip snapshots and ordered audio match; eight work-RAM bytes remain unexplained. Stingray181: native process succeeds and finite displayed graphics/credits/start match, but twelve work-RAM bytes remain unexplained and consumer terminal manifest was pending at this audit. Neither receives strict whole-replay acceptance.','', 'The standard full-design baseline passes all seven strict resource caps and timed checks across eight conditions. External IO/CDC qualification and a source-bound fit of the final P6 graph remain open. No RBF is authorized by continuing development.']
    (OUT/'coverage.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    changes = '''# Proposed documentation updates after central integration

These are reviewable proposals, not production edits.

- mamebug.md B01 lines47-53 are superseded by the nonvacuous late-room receipts above them. Rewrite them as historical failed entry probes, preserving their zero-visible-pixel negative result. Do not reintroduce natural stage5/ending progression as a required gate: the later contract correction and plan allow fixtures.
- docs/bug_coverage.json B03's precise PCM alignment/direct isolated replay-channel language should follow the plan's measured rates/mix contract. Exact MAME/JT PCM identity is not required. Preserve death-animation, semantic effects and source-bound full audio limitations.
- B03/B04/B05/B06 status should cite current joined audio/source manifests and the semantic jump/hit audit; ordinary pickup remains pending. Do not declare all four sound bugs closed solely from ordered writes or finite clipping counts.
- B07 should replace the old isolated-probe-only description with reviewed logical-P2 transaction data, paired real firmware replies, all14 actual HPS wrapper checks and finite native181 legal credits/start. Preserve its12-byte RAM divergence, pending consumer manifest and missing complete Stingray gameplay/runtime DIP coverage.
- B08 should record five completed displayed-frame matches after source-bound consumer qualification; earlier diagnostic drawing-buffer mismatches remain historical artifact-selection failures, not PCB defects.
- B06 and donormap must preserve the embedded-SSG period-zero donor fork and T48 port-latch export pins/licenses when integrated. They are core/donor implementation fixes, not MAME bug reports. Retain canonical versus private-joined graph distinction until central merge.
- B12/plan/progress must distinguish the eight-corner standard baseline internal timed-check pass and all7 resource caps from open external IO/CDC and future final P6/P8 fit. No blanket timing-closure or release-readiness claim.
- B16 keeps all atomic failures and the18-pixel timed residual. IRQ instruction cutoffs/ordinary-cycle windows are diagnostic evidence, not an approved CPU/clock phase fix. Japan8-byte and Stingray12-byte work-RAM differences must remain explicit strict acceptance failures.
- B09/B10/B13/B14/B15 may have complete compatibility dispositions while retaining physical uncertainties. Missing original firmware/oscillator/analog/alias/watchdog measurements do not authorize speculative changes or an endless new-research requirement.
- P7 acceptance.json must bind actual final source graph, ROM/input hashes and terminal processes/consumers. Historical source-compatible fixtures are reusable only with explicit affected-source parity. No duplicate long replay is warranted solely by an inactive profile2 cone change.
'''
    (OUT/'proposed_doc_updates.md').write_text(changes,encoding='utf-8')
    verification = {'actual_exit_code':0,'ids_present':16,'unique_ids':16,'all_game_acceptance_false':True,'all_evidence_paths_exist':True,'frozen_producer_manifests':len(MANIFESTS),'producer_leaf_pins_verified':verified,'production_or_runtime_mutations':False}
    (OUT/'verification.json').write_text(json.dumps(verification,indent=2)+'\n',encoding='utf-8')
    outputs = [OUT/p for p in ['audit.py','coverage.json','coverage.md','proposed_doc_updates.md','verification.json']]
    manifest = {'schema':'current_bug_gate_audit_import_v1','files':[pin(p) for p in outputs],'source_inputs':[pin(p) for p in input_paths],'evidence_handles':[pin(p) for p in sorted(evidence_paths)],'status':'16_id_bounded_audit_complete_full_core_acceptance_open','verification':verification}
    (OUT/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':manifest['status'],'manifest':str(OUT/'import_manifest.json'),'sha256':sha(OUT/'import_manifest.json'),'verification':verification}))

if __name__ == '__main__':
    main()
