from pathlib import Path
import json,hashlib,csv,re
O=Path(__file__).resolve().parent;R=O.parents[1];N=R/'sim/captures/rtl/kyros_combat_hud3301';M=R/'sim/captures/kyros/combat3600_clocked'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((O/'hit_object_inspection.json').read_text());j=json.loads((O/'semantic_windows_result.json').read_text())
rom=(R/'roms/kyros/maincpu.bin').read_bytes();cache=json.loads((R/'research/kyros_rom_disassembly_candidates.json').read_text())
assert hashlib.sha256(rom).hexdigest()==cache['rom_sha256']
receipt_path=R/'research/kyros_combat_hud3301_exit.json';receipt=json.loads(receipt_path.read_text())
build_path=R/'research/kyros_combat_hud3301_build_exit.json';build=json.loads(build_path.read_text())
elf=N/'alpha68kn_system_sim'
targets=[]
for off,cmdfield in [(0x460,896),(0x480,897)]:
    before=(N/'frame_000870.work.bin').read_bytes()[off:off+32]
    after=(N/'frame_000900.work.bin').read_bytes()[off:off+32]
    reference=(M/'frame_000900.work.bin').read_bytes()[off:off+32]
    ev=[x for x in r['target_events'] if int(x['frame'])==895 and 0x20000+off<=int(x['address'])<0x20000+off+32]
    expectations=[(0x11,8),(0x10,1),(0x6,0x10),(0x7,0),(0x8,8),(0xa,255),(0x9,1),(0x2,128)]
    actual=[]
    for x in ev:
        addr,data,mask=map(int,(x['address'],x['data'],x['mask']));rel=addr-0x20000-off
        if mask&0xff00:actual.append((rel,data>>8&255,x))
        if mask&255:actual.append((rel+1,data&255,x))
    pos=0;matched=[]
    for addr,value in expectations:
        while pos<len(actual) and actual[pos][:2]!=(addr,value):pos+=1
        if pos<len(actual):matched.append(actual[pos][2]);pos+=1
    native_command=any(x['frame']==cmdfield and x['command']==0x58 for x in j['candidate_hit_commands58'])
    # Exact counterpart command already qualified by the3301 accepted-latch audit.
    targets.append({'target_base':hex(0x20000+off),'native_before_field':870,'native_after_field':900,
        'before_object_hex':before.hex(),'after_object_hex':after.hex(),'reference_after_object_hex':reference.hex(),
        'enemy_type':before[0],'ROM_hit_threshold_address':hex(0x2dc4+(before[0]<<4)),
        'ROM_hit_threshold':rom[0x2dc4+(before[0]<<4)],'matched_MAME_defeat_writes':matched,
        'accepted_native_hit_command_field':cmdfield,'accepted_native_hit_command58':native_command,
        'checks':{'actual_type1_enemy_before':before[0]==1,'before_hit_counter0':before[0x10]==0,
            'ROM_type1_threshold1':rom[0x2dd4]==1,'after_hit_counter1':after[0x10]==1,
            'after_defeat_state8':after[8]==8,'after_direction8':after[0x11]==8,
            'all32_target_object_bytes_exact_to_MAME900':after==reference,
            'exact_ROM6f_path_accepted_defeat_sequence_nonvacuous':len(matched)==len(expectations),
            'accepted_hit_command58':native_command}})
asm=R/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm';sel=[]
for s in asm.read_text().splitlines():
    m=re.match(r'^([0-9a-f]{5}): ((?:[0-9a-f]{4} ?)+)\s+(.+)$',s)
    if not m:continue
    pc=int(m[1],16)
    if 0x2cc0<=pc<=0x2d12 or 0x6f4e<=pc<=0x6f9c:
        op=bytes.fromhex(m[2]);assert rom[pc:pc+len(op)]==op
        sel.append({'pc':hex(pc),'opcode':op.hex(),'instruction':m[3].strip()})
checks={'actual_retained_CPU_run_and_build_terminal0':receipt['exit_code']==0 and build['exit_code']==0,
    'actual_retained_CPU_ELF_exact':sha(elf)==receipt['executable_sha256'],
    'all_two_target_checks_strict_boolean_true':all(v is True for t in targets for v in t['checks'].values()),
    'pinned_ROM_hit_and_threshold_handler_opcodes':len(sel)>35,
    'old_source_parent_retained':receipt['source_parent']=='8b771c4b9fdc37171fb1d531e73c05e80017f64d'}
result={'scope':'Two nonvacuous successful type1 enemy hit/defeat effects and accepted sound58 commands in historical real CPU gameplay; exact target RAM byte comparison, no old raw RGB or physical audio acceptance.',
    'checks':checks,'all_finite_checks_strict_boolean_true':all(x is True for x in checks.values()),'targets':targets,
    'source_semantic_path':'ROM6f4e..6f66 sets hit-direction8 and queues58 then calls2cc0;2cc0 increments target+10 hit counter and type1 threshold1 qualifies defeat;6f7e..6f96 writes word+6=1000,state+8=8,flags+a=ff,byte+9=1,flags+2=80. The exact accepted write subsequence disambiguates the observed effect; eight58 producers alone would not.',
    'source_parent':receipt['source_parent'],'actual_ELF_sha256':sha(elf),'instruction_pins':sel,
    'pins':{'run_receipt':sha(receipt_path),'build_receipt':sha(build_path),'compiled_inputs_manifest':sha(R/'research/kyros_combat_hud3301_inputs.sha256'),
      'ROM':cache['rom_sha256'],'disassembly':sha(asm),'candidate_stage':sha(O/'hit_object_inspection.json'),'existing_exact_chip_DAC_latch_audit':sha(O/'retained_cpu_audio_result.json')},
    'current_joined_image_replay_qualified':False,'full_P5_pass':False}
(O/'hit_semantic_result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'checks':checks,'target_checks':[t['checks'] for t in targets],'all_pass':result['all_finite_checks_strict_boolean_true'],'result_sha256':sha(O/'hit_semantic_result.json')}))
raise SystemExit(0 if result['all_finite_checks_strict_boolean_true'] else 1)
