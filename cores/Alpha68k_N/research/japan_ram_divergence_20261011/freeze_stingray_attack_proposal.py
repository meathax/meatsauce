"""Freeze finite source-backed aiming and score/rank requirements, no runtime."""
from pathlib import Path
import json,hashlib
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'stingray_route1800/attack_diagnosis'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
geometry=json.loads((HERE/'geometry.json').read_text());shots=json.loads((HERE/'shot_lifetimes.json').read_text())['shots']
rank=json.loads((HERE/'score_rank_source_details.json').read_text());rom=(ROOT/'roms/sstingry/maincpu.bin').read_bytes()
assert len(shots)==9 and geometry['actual_update_count']==44 and geometry['both_rectangle_candidate_count']==0
assert len(rank['candidate14byte_layout'])==10 and rank['candidate14byte_layout'][-1]['scoreBCD']=='00009893'
assert 'moveq   #$9, D7' in (HERE/'ROM_00255a.asm.txt').read_text()
assert 'lea     ($e,A0), A0' in (HERE/'ROM_00255a.asm.txt').read_text()
assert 'bcc     $258c' in (HERE/'ROM_00255a.asm.txt').read_text()
assert 'bcc     $175e' in (HERE/'ROM_001744.asm.txt').read_text()
assert 'move.b  #$3, (A4,D7.w)' in (HERE/'ROM_0043cc.asm.txt').read_text()
assert rom[0x315a+4]==2 and rom[0x315a+1]==0 and rom[0x315a+5]==1
nearest=next(x for x in geometry['updates'] if any(t['normal_positive_radius'] for t in x['targets']))
target=min((t for t in nearest['targets'] if t['normal_positive_radius']),key=lambda t:t['world_delta_X']**2+t['world_delta_Y']**2)
proposal=dict(scope='Source-only revised1800 diagnosis and next bounded legal aiming proposal; no game runtime admitted',
    immutable_current_result=dict(MAME_actual_exit=0,fields=1800,qualifier_actual_exit=1,checks='14/17',open=['score_increment','earned148','gameover_restart']),
    proven_firing='Nine genuine P1 shots born881..1266 with actual3f56 position writes. All orientation0/mode0;44 actual projectile-coordinate updates. First shot exits at screen-pair700f/age21, crossing normal low-byte16 boundary. Eight later shots have actual4426 projectile-state writes: loadedROM4420 stores3 after terrain bitmap paths43ee/4418; subsequent explosion/retirement is observed. No current-score producer write occurs.',
    proven_enemy_geometry='For all44 retained projectile-coordinate commits, reconstruction of normal positive-radius rectangles from list600..607, object620+id*16, word2/word4, and radiusROM72c8 finds zero simultaneous axis matches.13 have first-axis matches. This explains no normal enemy hit under those inputs; special negative radius cases and exact executed read epochs are separately limited.',
    camera_correction='Screen bytes020127127/128 oscillation does not establish a traversal stall: source3388..33a8 combines screen positions with scroll0012/001c; worldword0116 progresses128→236. Preserve the284 raw screen writes without relabeling them as substantial screen movement or no world motion.',
    first_live_target=dict(observed_iterator=nearest['frame'],shot_world=nearest['world_pair'],target=target),
    minimum_legal_aiming_candidate=[
        {'phase':'preserve qualified startup','inputs':'Same original DIP93/coinA+2/coinB+1/Start2 prefix and actual first position milestone; no early inactive player controls.'},
        {'phase':'lateral flank and alignment','inputs':'Selected player RIGHT only, j1/rawIN0bit4, maps source direction2. Track actual worldword0118 against nearest eligible target word4, initially80 rather than player120. Stop lateral phase within actual target positive radius10, preferably center alignment. Reject a fixed-duration claim; release on stall/bound/unexpected turn.', 'source':'direction nibble table315a+4=2; world coordinates3388..33a8; targets446a..44dc.'},
        {'phase':'approach clear shooting lane','inputs':'Selected player UP only j8/rawIN0bit1, source direction0, until target worldword2 is inside the actual orientation0 ray before visible boundary. Initial targetX288 requires approaching roughlyworldX192 under the retained centered muzzle geometry; recompute from actual screen coordinates/scroll rather than assuming a fixed96-distance gate.'},
        {'phase':'aimed fire','inputs':'Selected player UP+fire j24/raw0x11, heading0, refresh nearest target and track every projectile/terrain/hit source event. Alternatively up+right+fire j25/raw0x15 maps heading1 when target geometry calls for a diagonal; this is not a proven shortest kill route.'},
        {'phase':'first score stop','inputs':'End the bounded aiming diagnostic at the first genuine nonzero selected-player BCD score write plus completed frame, or preserve the unmet condition at its explicit bound. Do not automatically extend or use it as earned148 proof.'}],
    score_and_saved_table_requirements=dict(
        current_P1_producer='168e checks real-game bit0;169c selects turn;16aa stores BCD score at020020 (P2 branch uses020024). Projectile hit4518 obtains point award fromROM7288[type*2], then calls168e;020028 update175a occurs only when maxP1/P2 exceeds oldbest.',
        table_layout='Exactly10 entries,14bytes each: BCDscore4/name8/stage2 at020770..7fb, then4byte sentinel. Source2578D7=9,2582stride0e,257e/2580 accepts score>=entry.',
        minimum_default_rank_BCD='00009893',minimum_default_rank_display=98930,
        minimum_default_best_BCD='00016374',minimum_default_best_display=163740,
        rank_vs_best='An equal lowest score can enter rank because2580 usesBCC; changing best175a requires strictly exceeding00016373. A single small kill does not prove either saved-table effect.',
        gameover_table_path='2568 selects actual current turn score,257e scans rank,258c qualifies entry,2616 calls26da name entry,2638 invokes2658 table update loop. Observe actual legal writers and entered/default accepted name; no table clearing or state injection.',
        earning_condition='Actual score at/above qualified rank threshold, genuine rank/name-entry path and post-play mainCPU table writer must produce changed148 versusboot. Alternatively actual175a best producer after score exceeds oldbest changes the4byte best region. Bind original ROM/source and ordered actual inputs.',
        continuation_limit='No proven shortest route or runtime bound to98,930/163,740 points exists in retained1800 evidence. Any long legal earning scenario needs separate source-bound route/admission after the first aimed hit. Do not promise closure by an arbitrary extension.'),
    minimal_next_observation='Keep actual continuous guest/input/upper taps and ordered multirow journals. Add no state writes. Record actor world0116/0118+screen126/127+orientation104, target list600..607/struct620..76f, five projectile words81a..823/direction10e..112/age120..124, bitmap/tile writes at source43e8/4420, actual4518→16aa scoring and both score020020/24. Bind per-shot event epochs; at rank eligibility record2568/258c/26da/2658 legal writers and full148 before/after. Original command0x2d remains address-derived with payloadFF.',
    genuine_lifecycle_stop_conditions=['Source-bound earned148 before accepting persistence gate.','Actual spare exhaustion and game-over acceptance path, rather than fixed-field Start.','Legal Start pulse only after actual game-over/credits; actual consumed credit and game-state producer prove restart.','P2 controls only after true turnFF. Ordered simultaneous release/apply rows mustboth survive native input parsing.'],
    limitations=['Terrain-hit classification uses actual4426 age write plus loadedROM4420; exact destructive tile subtype is not determined.','Geometry is sampled at actual projectile writes before collision reads; intervening CPU state/negative radius handlers lack full register/branch evidence.','Shortest legal rank/best route and name-entry control sequence remain unqualified.','No native1800, new capture, RTL change, RAM waiver or RBF requested/performed.'])
p=HERE/'aiming_and_earned148_proposal.json';assert not p.exists();p.write_text(json.dumps(proposal,indent=2)+'\n')
files=[Path(__file__),Path(__file__).resolve().parent/'diagnose_stingray_attack1800.py',Path(__file__).resolve().parent/'stage_stingray_attack_details.py',Path(__file__).resolve().parent/'diagnose_stingray_shot_lifetimes.py',Path(__file__).resolve().parent/'solve_stingray_attack_geometry.py']
files += [p for p in HERE.iterdir() if p.is_file()]
files += [ROOT/'roms/sstingry/maincpu.bin',HERE.parent/'revised_reference_v1/terminal_import_manifest_v4.json']
out=HERE/'import_manifest.json';assert not out.exists();out.write_text(json.dumps(dict(scope=proposal['scope'],analysis_actual_exits=[0,0,0,0,0],preserved_qualifier='14/17 actual1',no_new_runtime=True,pins=[pin(p) for p in sorted(files)]),indent=2)+'\n')
print(json.dumps(dict(manifest=pin(out),proposal=pin(HERE/'aiming_and_earned148_proposal.json'),current_result_unchanged='14/17 exit1',nine_shots=len(shots),geometry_both_axes=geometry['both_rectangle_candidate_count'],first_target=target,rank_display=98930,best_display=163740,no_game_runtime=True),indent=2))
