"""One bounded terminal/source consumer; retain open score/hiscore/restart gates."""
from pathlib import Path
import json,csv,hashlib,collections,subprocess,sys
from PIL import Image
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
REF=ROOT/'research/wrapper_feature_gates_20261011/mame_only1800_reference_v5'
HERE=Path(__file__).resolve().parent/'stingray_route1800/revised_reference_v1';CAP=HERE/'capture'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
def rows(p):return list(csv.DictReader(p.open()))
runtime=json.loads((HERE/'runtime_exit.json').read_text());admission=json.loads((HERE/'runtime_admission.json').read_text())
manifest=json.loads((HERE/'preparation_manifest.json').read_text())
checks=[]
def check(name,predicate,detail=None):checks.append(dict(name=name,pass_=bool(predicate),detail=detail))
check('authentic_actual_exit_and_complete',runtime['actual_exit']==0 and runtime['callback_failure'] is None and runtime['complete']=='frames=1800\nmode=gameplay\nlast_screen_frame=1799\n')
check('fresh_source_ROM_CAS',all(pin(Path(p['path']))['sha256']==p['sha256'] for p in admission['source_and_ROM_CAS']))
states=rows(CAP/'frame_states.csv');applied=rows(CAP/'applied_inputs.csv');actions=rows(CAP/'legal_actions.csv')
check('actual1800_state_and_applied_journal',len(states)==1800 and len(applied)==1800 and [int(x['frame']) for x in states]==list(range(1800)) and [int(x['frame']) for x in applied]==list(range(1800)))
original_states=rows(REF/'capture/frame_states.csv')
check('original_boot_state_prefix0_through186',all(states[i]==original_states[i] for i in range(187)))
boot_assets=[]
for f in [0,30,90,119,179]:
    for suffix in ['work.bin','sprites.bin','png']:
        p=CAP/f'frame_{f:06d}.{suffix}';q=REF/f'capture/frame_{f:06d}.{suffix}'
        boot_assets.append(dict(field=f,domain=suffix,equal=p.read_bytes()==q.read_bytes(),new=pin(p),original=pin(q)))
check('all15_original_boot_snapshots_exact',all(x['equal'] for x in boot_assets),boot_assets)
boot_actions=rows(REF/'legal_actions.csv')[:8]
check('same8_original_legal_boot_actions',all(all(a[k]==b[k] for k in ['request_completed_field','player','joystick']) for a,b in zip(actions[:8],boot_actions)))
events=rows(CAP/'route_lifecycle_events.csv')
milestone=[x for x in events if x['kind']=='actual_position_milestone']
deaths=[x for x in events if x['kind']=='actual_spare_decrement']
turns=[x for x in events if x['kind']=='actual_P2_turn_byte']
check('actual_milestone_before_first_game_controls',len(milestone)==1 and milestone[0]['frame']=='878' and actions[8]['request_completed_field']=='879' and actions[8]['player']=='0' and actions[8]['joystick']=='24',milestone)
check('actual_ROM246c_death_and_ROM1d6e_P2turn',len(deaths)>0 and any(int(x['curpc'])==0x246c for x in deaths) and any(int(x['curpc'])==0x1d6e and int(x['data'])&255==255 for x in turns),dict(deaths=deaths,turns=turns))
check('P2_actions_only_after_genuine_turn',all(int(x['request_completed_field'])>=int(turns[0]['frame']) for x in actions[8:] if x['player']=='1' and int(x['joystick'])&63),actions[8:])
check('actual_input_changes_apply_next_field',int(states[880]['in0'])==0x11 and int(states[1644]['in0'])==0x1100,dict(field880=states[880],field1644=states[1644]))
rawbytes={};selected=[];positions=[];score_writes=[];turn_commands=[];accepted=[];counts=collections.Counter()
for x in csv.DictReader((CAP/'guest_effect_events.csv').open()):
    counts[x['area']]+=1;f=int(x['frame']);a=int(x['address']);d=int(x['data']);m=int(x['mask'])
    if x['area']=='turn_command' and f>=878:turn_commands.append(x)
    if x['area']=='accepted_read' and a==0xc0000 and f>=879 and d&m:accepted.append(x)
    if x['area']!='work_write':continue
    for t in [a,a+1]:
        lane=0xff00 if t==a else 255
        if not m&lane:continue
        value=(d>>8)&255 if t==a else d&255
        prior=rawbytes.get(t);rawbytes[t]=value
        if f>=879 and t in [0x20126,0x20127] and value!=prior:positions.append(dict(frame=f,address=hex(t),old=prior,new=value,PC=hex(int(x['main_pc']))))
        if f>=879 and t==0x2000d and value!=prior:selected.append(dict(frame=f,value=value,PC=hex(int(x['main_pc']))))
        if f>=879 and 0x20020<=t<=0x20027 and value!=prior:score_writes.append(dict(frame=f,address=hex(t),old=prior,new=value,PC=hex(int(x['main_pc']))))
check('actual_player_position_changed',len(positions)>0,positions[:8]+positions[-8:])
check('actual_P2_bank_selected_control_reads',any(x['frame']=='1644' and x['value']==0x11 and x['PC']=='0x10f4' for x in selected),selected)
check('actual_P2_turn_MCU_command',any(int(x['address'])==0x8005a and int(x['mask'])&255 and int(x['data'])&255==0x2d for x in turn_commands),turn_commands)
table_writes=rows(CAP/'hiscore_write_events.csv');post_table=[x for x in table_writes if int(x['frame'])>=879]
boot_payload=(CAP/'frame_000119.hiscore148.bin').read_bytes();final_payload=(CAP/'frame_001799.hiscore148.bin').read_bytes()
assert len(boot_payload)==len(final_payload)==148
payload_diff=[dict(offset=i,boot=a,final=b) for i,(a,b) in enumerate(zip(boot_payload,final_payload)) if a!=b]
changed_score=any(x['new']!=0 and 0x20020<=int(x['address'],16)<=0x20023 for x in score_writes)
earned148=bool(payload_diff and post_table and changed_score)
restart=any(x['description']=='actual_gameover_legal_Start1_request' for x in actions)
graphics=[]
for p in sorted(CAP.glob('frame_*.png')):
    with Image.open(p) as image:
        assert image.size==(224,256)
        rgb=image.convert('RGB').transpose(Image.Transpose.ROTATE_90).tobytes()
    q=p.with_suffix('.display.rgb');assert not q.exists();q.write_bytes(rgb);assert len(rgb)==256*224*3
    graphics.append(dict(completedPNG=pin(p),completed_display_RGB=pin(q)))
check('complete_native_dimensions_for_all_selected_PNGs',len(graphics)==12,graphics)
checks_required=checks.copy()
check('genuine_current_score_after_play',changed_score,score_writes)
check('genuine_earned148_vs_boot_with_legal_table_producer',earned148,dict(changed_bytes=payload_diff,post_play_table_writes=post_table))
check('genuine_gameover_and_restart',restart,actions)
tool=ROOT/'tools/mame0289/unidasm.exe';rom=ROOT/'roms/sstingry/maincpu.bin';disassembly=[]
for base,count in [(0x2460,40),(0x1d60,34),(0x33a0,16)]:
    command=[str(tool),str(rom),'-arch','m68000','-skip',str(base),'-count',str(count),'-basepc',f'{base:x}']
    child=subprocess.run(command,capture_output=True,text=True);assert child.returncode==0
    p=HERE/f'actual_producer_ROM_{base:06x}.asm.txt';assert not p.exists();p.write_text(child.stdout+child.stderr)
    disassembly.append(dict(command=command,actual_exit=child.returncode,output=pin(p)))
report=dict(scope='ONE revised official reference1800, genuine first death/P2 turn proven; required score/earned148/restart remain separately open',
    actual_MAME_exit=runtime['actual_exit'],completed_fields=1800,checks=checks,passed=sum(c['pass_'] for c in checks),total=len(checks),
    actual_lifecycle=events,actual_actions=actions,actual_guest_counts=dict(counts),
    changed_position_count=len(positions),position_samples=positions[:8]+positions[-8:],
    nonzero_accepted_input_read_count=len(accepted),accepted_input_samples=accepted[:4]+accepted[-4:],
    score_changes=score_writes,boot148=pin(CAP/'frame_000119.hiscore148.bin'),final148=pin(CAP/'frame_001799.hiscore148.bin'),
    payload_changed_bytes=payload_diff,table_writer_total=len(table_writes),table_writer_post_play=post_table,
    useful_lifecycle_proven=all(c['pass_'] for c in checks_required),all_requested_lifecycle_closed=earned148 and changed_score and restart,
    no_native_runtime=True,no_automatic_repeat=True,no_RAM_gate_waiver=True,
    native_input_contract='Use complete actual frame_states.csv raw ports or applied_inputs.csv. legal_actions.csv has two ordered actions at1643; a parser retaining only the last action per field is insufficient.',
    primary_source_producers=disassembly)
p=HERE/'qualification.json';assert not p.exists();p.write_text(json.dumps(report,indent=2)+'\n')
actual_exit=0 if all(c['pass_'] for c in checks) else 1
p=HERE/'qualification_exit.json';p.write_text(json.dumps(dict(actual_exit=actual_exit,source=pin(Path(__file__)),qualification=pin(HERE/'qualification.json')),indent=2)+'\n')
files=[Path(__file__),Path(__file__).resolve().parent/'prepare_revised_stingray1800.py',Path(__file__).resolve().parent/'run_revised_stingray1800.py']
files += [p for p in HERE.rglob('*') if p.is_file()]
pins=[pin(p) for p in sorted(files)]
out=HERE/'terminal_import_manifest.json';assert not out.exists();out.write_text(json.dumps(dict(scope=report['scope'],MAME_actual_exit=0,qualification_actual_exit=actual_exit,checks=f"{report['passed']}/{report['total']}",useful_lifecycle_proven=report['useful_lifecycle_proven'],all_requested_lifecycle_closed=False,no_native_runtime=True,pins=pins),indent=2)+'\n')
print(json.dumps(dict(manifest=pin(out),qualification=pin(HERE/'qualification.json'),actual_MAME_exit=0,qualification_actual_exit=actual_exit,passed=report['passed'],total=report['total'],useful_lifecycle_proven=report['useful_lifecycle_proven'],positions=len(positions),earned148=earned148,restart=restart,score_changes=len(score_writes)),indent=2))
sys.exit(actual_exit)
