from pathlib import Path
import csv,hashlib,json,re,collections
O=Path(__file__).resolve().parent;R=O.parents[1];N=R/'sim/captures/rtl/kyros_combat_hud3301'
r=json.loads((O/'jump_semantic_binding_stage.json').read_text());asm=R/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
producers={n:[] for n in (0x2d,0x53,0x58)}
for line in asm.read_text().splitlines():
    for n in producers:
        if re.search(r'move.b\s+#\$'+format(n,'x')+r', \(\$35f,A6\)',line):producers[n].append(line)
commands=[]
with (N/'epoch_events.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        if not int(x['iack']) and not int(x['rw']) and int(x['address'])==0xe0000:
            commands.append({'frame':int(x['frame']),'command':int(x['data_out'])>>8&255})
state_events=[]
for x in r['reference_RAM_events']:
    if int(x['address'])==0x20408 and int(x['mask'])&0xff00:
        state_events.append({'frame':int(x['frame']),'state':int(x['data'])>>8&255,'master_ticks':x.get('master_ticks')})
snap={x['frame']:x for x in r['native_snapshots']}
ports=[]
with (N/'audio_events.csv').open(newline='') as f:
    for x in csv.DictReader(f):
        if x['kind']=='write':ports.append(x)
windows=[]
for button,command,air,land in [(840,844,870,900),(1020,1024,1050,1080)]:
    n=[x for x in r['actual_native_latch_events'] if x['frame']==command and x['command']==0x2d]
    m=[x for x in r['retained_reference_latch_events'] if x['frame']==command and x['command']==0x2d]
    rs=[x for x in state_events if button<x['frame']<=air and x['state']==4]
    burst=[x for x in ports if command<=int(x['frame'])<=air]
    windows.append({'button_field':button,'accepted_jump_command_field':command,'accepted_native_command':n,
      'accepted_MAME_command':m,'reference_state4_writes':rs,'airborne_native_snapshot':snap[air],
      'post_airborne_native_snapshot':snap[land],'actual_chip_port_write_count_through_airborne_snapshot':len(burst),
      'chip_ports_observed':sorted(set(int(x['address']) for x in burst)),
      'finite_source_qualified_jump_entry_and_exit':bool(n and m and rs and burst) and snap[air]['player_state_20408']==4 and bool(snap[air]['player_flags_20403']&0x40) and snap[air]['player_motion_flags_2040a']&3==3 and snap[land]['player_state_20408']!=4 and not(snap[land]['player_flags_20403']&0x40)})
checks={'ROM_and_disassembly_pins_exact':sha(R/'roms/kyros/maincpu.bin')==r['rom_sha256'] and sha(asm)==r['disassembly_sha256'],
    'unique_pinned_ROM_jump_command_producer':len(producers[0x2d])==1 and producers[0x2d][0].startswith('05c1c:'),
    'two_nonvacuous_ROM_state_command_jumps':all(x['finite_source_qualified_jump_entry_and_exit'] is True for x in windows),
    'exact_reference_and_native_accepted_command_fields':all(x['accepted_MAME_command'][0]['frame']==x['accepted_native_command'][0]['frame'] for x in windows),
    'no_wholeP5_pass':r['full_P5_pass'] is False}
result={'scope':'Finite source-qualified jump entry/exit and software-driven sound-command activity in retained real CPU traces; no physical sound, isolated effect PCM or old raw-RGB semantic claim.',
   'checks':checks,'all_finite_checks_strict_boolean_true':all(x is True for x in checks.values()),'windows':windows,
   'source_semantic_path':'ROM5b22..5b48 normalizes input0x20 to20907 bit1;49ac/49b2 branches to5bec;5c0a sets20408=4;5bf8 sets20403 bit6;5c10 sets motion2040a lowbits3;5c1c queues jump command2d through trap4.',
   'existing_global_chip_event_evidence':'retained_cpu_audio_result.json preserves every combat3301 per-chip ordered byte plus known seven YM field-label/global-order differences; DAC writes exactly match.',
   'candidate_hit_commands58':[x for x in commands if x['command']==0x58],
   'candidate_pickup_commands53':[x for x in commands if x['command']==0x53],
   'ROM_command_producers':{hex(k):v for k,v in producers.items()},
   'hit_or_pickup_pass':False,
   'minimum_remaining_hit_target':'Existing command58 candidates at896/897 have eight direct ROM producer sites. Need producer-PC plus target-object identity/state/health/removal and corresponding effect-command receipt for one successful enemy hit; command58 or HUD score increase alone is ambiguous.',
   'minimum_remaining_pickup_target':'ROM5482..54ba grants item score data, clears object via68c0 and queues53. Require one observed type20/21/22/24/25 item collision/removal, accepted53 command and matching native/reference state. Do not infer pickup from a rising HUD or punch command35.',
   'pins':{'binding_stage':sha(O/'jump_semantic_binding_stage.json'),'native_audio_events':sha(N/'audio_events.csv'),'native_epoch_events':sha(N/'epoch_events.csv'),'script':sha(Path(__file__))},'full_P5_pass':False}
(O/'semantic_windows_result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'checks':checks,'all_pass':result['all_finite_checks_strict_boolean_true'],'hit58_count':len(result['candidate_hit_commands58']),'pickup53_count':len(result['candidate_pickup_commands53']),
    'windows':[{k:x[k] for k in ('button_field','accepted_jump_command_field','finite_source_qualified_jump_entry_and_exit','reference_state4_writes','actual_chip_port_write_count_through_airborne_snapshot')} for x in windows],
    'result_sha256':sha(O/'semantic_windows_result.json')}))
raise SystemExit(0 if result['all_finite_checks_strict_boolean_true'] else 1)
