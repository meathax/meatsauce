from pathlib import Path
import csv,hashlib,json,subprocess,sys,time
O=Path(__file__).resolve().parent;R=O.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
exits=[]
for n in ('qualify_semantic_windows.py','qualify_hit_semantics.py'):
    start=time.time();r=subprocess.run([sys.executable,'-X','utf8',str(O/n)],capture_output=True,text=True)
    (O/(n+'.stdout.log')).write_text(r.stdout);(O/(n+'.stderr.log')).write_text(r.stderr)
    exits.append({'script':n,'script_sha256':sha(O/n),'actual_exit_code':r.returncode,'started':start,'completed':time.time(),
        'stdout_sha256':sha(O/(n+'.stdout.log')),'stderr_sha256':sha(O/(n+'.stderr.log'))})
    if r.returncode:raise SystemExit(r.returncode)
(O/'semantic_actual_exit.json').write_text(json.dumps({'actual_subprocess_exits':exits},indent=2)+'\n')
# Check the already completed 4401 oracle for an ordinary-pickup command before
# proposing any additional scenario. This is a bounded retained-log read, not a run.
p=R/'sim/captures/kyros/idle_death_restart_actions4401/events.csv';cmd=[]
with p.open(newline='') as f:
    for x in csv.DictReader(f):
        if x['area']=='sound_latch_write':cmd.append({'frame':int(x['frame']),'command':int(x['data'])>>8&255})
coverage={'scope':'Completed retained MAME4401 command coverage only; native joined replay remains pending.',
    'source_events_sha256':sha(p),'accepted_latch_count':len(cmd),'ordinary_pickup53_commands':[x for x in cmd if x['command']==0x53],
    'transformation_item4d_commands':[x for x in cmd if x['command']==0x4d],'accepted_latches':cmd}
(O/'retained_MAME4401_pickup_command_coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
base=json.loads((O/'import_manifest.json').read_text());base_names={x['relative_path'] for x in base['files']}|{'import_manifest.json','semantic_addendum_manifest.json'}
fullpins=[]
for n in ['roms/kyros/maincpu.bin','sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm',
  'research/kyros_combat_hud3301_exit.json','research/kyros_combat_hud3301_build_exit.json','research/kyros_combat_hud3301_inputs.sha256',
  'sim/captures/rtl/kyros_combat_hud3301/alpha68kn_system_sim','sim/captures/rtl/kyros_combat_hud3301/epoch_events.csv','sim/captures/rtl/kyros_combat_hud3301/audio_events.csv',
  'sim/captures/kyros/combat3600_clocked/events.csv','sim/captures/kyros/combat3600_clocked/inputs.csv','sim/captures/kyros/combat3600_clocked/frame_states.csv',
  'sim/captures/kyros/idle_death_restart_actions4401/events.csv']:
    q=R/n;fullpins.append({'path':str(q),'bytes':q.stat().st_size,'sha256':sha(q)})
for capture,fields in [('rtl/kyros_combat_hud3301',[840,870,900,1020,1050,1080]),('kyros/combat3600_clocked',[840,900,1020,1080])]:
    for field in fields:
        q=R/'sim/captures'/capture/f'frame_{field:06d}.work.bin';fullpins.append({'path':str(q),'bytes':q.stat().st_size,'sha256':sha(q)})
files=[{'relative_path':str(q.relative_to(O)).replace('\\','/'),'bytes':q.stat().st_size,'sha256':sha(q)} for q in sorted(O.rglob('*')) if q.is_file() and str(q.relative_to(O)).replace('\\','/') not in base_names]
manifest={'scope':'Append-only source-qualified finite historical jump/hit state and effect proof. No current joined-image/full-P5/physical pass.',
  'base_manifest_sha256':sha(O/'import_manifest.json'),'files':files,'retained_source_and_capture_full_pins':fullpins,
  'actual_qualifiers_exit0':all(x['actual_exit_code']==0 for x in exits),'full_P5_pass':False}
(O/'semantic_addendum_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'files':len(files),'full_pins':len(fullpins),'qualifier_exits':[x['actual_exit_code'] for x in exits],
  'MAME4401_pickup53_count':len(coverage['ordinary_pickup53_commands']),'MAME4401_item4d_count':len(coverage['transformation_item4d_commands']),
  'semantic_manifest_sha256':sha(O/'semantic_addendum_manifest.json')}))
