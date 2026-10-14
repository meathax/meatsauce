"""Prepare one legal conditional official-MAME route; never launches a worker."""
from pathlib import Path
import hashlib,json,shutil
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
REF=ROOT/'research/wrapper_feature_gates_20261011/mame_only1800_reference_v5'
HERE=Path(__file__).resolve().parent/'stingray_route1800/revised_reference_v1'
assert not HERE.exists();HERE.mkdir();(HERE/'capture').mkdir();(HERE/'capture/cfg').mkdir()
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
original=REF/'official_effect1800.lua';assert pin(original)['sha256']=='74f35547f1527e62c7dffa0176daba339edf1ad816e8ce3d24914ef0c935eeb3'
source=original.read_text()
observer=r'''
local route_state={}
local ready_x=false
local ready_y=false
local started_real=false
local seen_death=false
local score_seen=false
local route_phase="boot"
local ready_field=-1
local restart_field=-1
local route_events=open("route_lifecycle_events.csv")
route_events:write("frame,kind,address,data,mask,pc,curpc,sr,phase\n")
local actual_route=open("legal_actions.csv")
actual_route:write("request_completed_field,player,joystick,description\n")
local actual_fields=open("applied_inputs.csv")
actual_fields:write("frame,joystick0,joystick1,phase,ready,turn,spares1,spares2,current_score\n")
local hiscore_events=open("hiscore_write_events.csv")
hiscore_events:write("frame,address,data,mask,pc,curpc,sr\n")
local function current_score()
    local value=0
    for a=0x020020,0x020023 do value=(value<<8)|(route_state[a] or 0) end
    return value
end
local function lifecycle_write(a,d,m)
    local prev1=route_state[0x02000e]
    local prev2=route_state[0x02000f]
    for lane=0,1 do
        local lane_mask=lane==0 and 0xff00 or 0x00ff
        if (m&lane_mask)~=0 then route_state[a+lane]=lane==0 and ((d>>8)&255) or (d&255) end
    end
    local cur=main.state["CURPC"].value
    if frame>=180 and a==0x02000a and (m&0xff00)~=0 and ((d>>8)&255)==3 and cur==0x104a then started_real=true end
    if frame>=186 and a==0x020116 and m==0xffff and d==0x0080 and pc(main)==0x33a8 then ready_x=true end
    if frame>=186 and a==0x020118 and m==0xffff and d==0x0078 and pc(main)==0x33ac then ready_y=true end
    local kind=""
    if ready_x and ready_y and ready_field<0 then ready_field=frame;kind="actual_position_milestone" end
    if frame>ready_field and ready_field>=0 and current_score()>0 then
        if not score_seen then kind="actual_current_score_nonzero" end
        score_seen=true
    end
    if ready_field>=0 then
        local now1=route_state[0x02000e]
        local now2=route_state[0x02000f]
        if (prev1 and now1 and now1<prev1) or (prev2 and now2 and now2<prev2) then seen_death=true;kind="actual_spare_decrement" end
        if a==0x02005a and (m&255)~=0 and (d&255)==255 then kind="actual_P2_turn_byte" end
    end
    if kind~="" then route_events:write(string.format("%d,%s,%d,%d,%d,%d,%d,%d,%s\n",frame,kind,a,d,m,pc(main),cur,main.state["SR"].value,route_phase));route_events:flush() end
end
for _,range in ipairs({{0x020028,0x02002b},{0x020770,0x0207ff}}) do
    handles[#handles+1]=space:install_write_tap(range[1],range[2],"genuine_hiscore_write"..range[1],function(a,d,m)
        hiscore_events:write(string.format("%d,%d,%d,%d,%d,%d,%d\n",frame,a,d,m,pc(main),main.state["CURPC"].value,main.state["SR"].value))
    end)
end
'''
source=source.replace('local guest=open("guest_effect_events.csv")',observer+'\nlocal guest=open("guest_effect_events.csv")',1)
needle='    if diagnostic_snapshot and area=="accepted_read" then return end'
assert source.count(needle)==1
source=source.replace(needle,needle+'\n    if area=="work_write" then lifecycle_write(a,d,m) end')
begin=source.index('local route_file =');end=source.index('\nlocal function dump',begin)
route=r'''local route_joy={0,0}
local boot_actions={
    [120]={0,128},[126]={0,0},[140]={1,128},[146]={1,0},
    [160]={1,128},[166]={1,0},[180]={1,64},[186]={1,0}
}
local function apply_joy(p,j,why)
    local old=route_joy[p+1]
    if old==j then return end
    local bits={4,8,2,1,16,32,128}
    for b=0,6 do
        if ((old~j)&(1<<b))~=0 then set_input("IN0",bits[b+1]<<(p*8),(j&(1<<b))~=0) end
    end
    if ((old~j)&128)~=0 then set_input("IN2",1<<p,(j&128)~=0) end
    route_joy[p+1]=j
    actual_route:write(string.format("%d,%d,%d,%s\n",frame,p,j,why))
    actual_route:flush()
end
local function drive_inputs()
    local a=boot_actions[frame]
    if a then apply_joy(a[1],a[2],"preserved_boot_coin_start") end
    if frame>=187 then
        local desired={0,0}
        route_phase="waiting_actual_position_milestone"
        local flags=route_state[0x02000a] or 0
        local turn=route_state[0x02005b] or 0
        if ready_field>=0 and frame>ready_field then
            if seen_death and (flags&1)==0 and restart_field<0 then restart_field=frame end
            if restart_field>=0 and frame<restart_field+6 then
                route_phase="actual_gameover_legal_Start1_request";desired[1]=64
            elseif (flags&1)~=0 then
                local player=turn==0 and 0 or 1
                route_phase=score_seen and "earned_current_score_move_toward_enemies" or "active_turn_up_and_fire"
                desired[player+1]=score_seen and 8 or 24
            else route_phase="actual_gameover_wait" end
        end
        apply_joy(0,desired[1],route_phase);apply_joy(1,desired[2],route_phase)
    end
    actual_fields:write(string.format("%d,%d,%d,%s,%d,%d,%d,%d,%d\n",frame,route_joy[1],route_joy[2],route_phase,ready_field,route_state[0x02005b] or -1,route_state[0x02000e] or -1,route_state[0x02000f] or -1,current_score()))
end
'''
source=source[:begin]+route+source[end:]
needle='    upper_reads:close();boot_dip:close();upper:close();guest:close();histogram:close();events:close();inputs:close();states:close();status:close();frame_states:close()'
assert source.count(needle)==1
source=source.replace(needle,'    route_events:close();actual_route:close();actual_fields:close();hiscore_events:close()\n'+needle)
source=source.replace('    dump(prefix .. ".work.bin",space:read_range(0x020000,0x020fff,8))','    dump(prefix .. ".work.bin",space:read_range(0x020000,0x020fff,8))\n    dump(prefix .. ".hiscore148.bin",space:read_range(0x020028,0x02002b,8)..space:read_range(0x020770,0x0207ff,8))')
source=source.replace('[900]=true,[1200]=true,[1799]=true','[878]=true,[900]=true,[1200]=true,[1799]=true')
lua=HERE/'official_revised1800.lua';lua.write_text(source)
# Copy the original startup DIP configuration only; runtime state/NVRAM stay fresh.
shutil.copyfile(REF/'capture/cfg/sstingry.cfg',HERE/'capture/cfg/sstingry.cfg')
argv=[str(ROOT/'tools/mame0289/mame.exe'),'sstingry','-rompath',str(ROOT/'roms'),'-noreadconfig','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(lua),'-pluginspath',str(ROOT/'tools/mame0289/plugins'),'-seconds_to_run','45']
for flag,path in [('-snapshot_directory',HERE/'capture'),('-cfg_directory',HERE/'capture/cfg'),('-nvram_directory',HERE/'capture/nvram'),('-state_directory',HERE/'capture/states'),('-wavwrite',HERE/'capture/audio.wav')]:argv += [flag,str(path)]
commands=dict(MAME_argv=argv,MAME_env=dict(ALPHA_CAPTURE_DIR=str(HERE/'capture'),ALPHA_CAPTURE_MODE='gameplay',ALPHA_CAPTURE_FRAMES='1800'),limit=1800,logical_stop='original frame-complete callback',no_automatic_repeat=True)
p=HERE/'commands.json';p.write_text(json.dumps(commands,indent=2)+'\n')
manifest=dict(authority='Root explicitly authorized ONE revised MAME-only Stingray route, max1800, actual position milestone and genuine lifecycle; coordinate audio_pickup before launch',
    upstream=[pin(original),pin(REF/'terminal_manifest.json'),pin(HERE.parent/'proposal_import_manifest_v2.json')],
    files=[pin(lua),pin(p),pin(HERE/'capture/cfg/sstingry.cfg'),pin(ROOT/'roms/sstingry.zip'),pin(ROOT/'roms/sstingry/download.bin'),pin(ROOT/'roms/sstingry/maincpu.bin'),pin(ROOT/'tools/mame0289/mame.exe')],
    generator=pin(Path(__file__)),limits='No RAM/CPU writes, no native launch, no automatic extension or repeat. Current score is a route predicate only; earned148 requires actual table change and legal source producer after run.',
    static_contract=dict(original_guest_and_upper_taps_retained=True,original_snapshot_and_input_phase=True,actual_applied_input_journal=True,boot_inputs_identical_through186=True,guest_fields_max1800=True))
p=HERE/'preparation_manifest.json';p.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(manifest=pin(p),Lua=pin(lua),commands=pin(HERE/'commands.json'),no_launch=True),indent=2))
