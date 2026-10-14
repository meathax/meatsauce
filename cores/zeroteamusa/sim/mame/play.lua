-- Target physical input playback plus the existing pristine capture helper.
-- No address-space writes, program patches or injected CPU/device state.
local m=manager.machine
local OUT=assert(os.getenv('CORE_OUT'))
local INPUT=assert(os.getenv('CORE_INPUTS'))
local f=assert(io.open(INPUT,'r'))
assert(f:read('*l')=='cycle,p1,p2,p3,p4,coin,dips,system','bad input header')
local events={}
for line in f:lines() do
    local e={}
    for value in line:gmatch('[^,]+') do e[#e+1]=assert(tonumber(value)) end
    assert(#e==8,'bad input row')
    -- Same native raster as the RTL: port events occur at the beginning
    -- of the selected frame, after the reset-only 60 system clocks.
    e.frame=e[1]==0 and 0 or math.floor((e[1]-60)/(512*282*12))
    events[#events+1]=e
end
f:close()
local index=1
local trace=assert(io.open(OUT..'/input-events.csv','w'))
trace:write('frame,p1,p2,p3,p4,coin,dips,system\n')
local function port(tag) return assert(m.ioport.ports[tag],'missing input port '..tag) end
local bindings={}
local cabinet=nil
for _,field in pairs(port(':SYSTEM').fields) do
    if field.mask==0x0700 then cabinet=field end
end
assert(cabinet,'missing cabinet setting')
local initial=assert(events[1],'empty input schedule')
assert(initial.frame==0,'cabinet must be selected before play')
cabinet.user_value=initial[8]&0x0700
for _,field in pairs(port(':DSW').fields) do field.user_value=initial[7]&field.mask end
-- Expose native field masks instead of relying on translated field names.
for _,spec in ipairs({{':P1_P2',2,3},{':P3_P4',4,5},{':COIN',6},{':SYSTEM',8}}) do
    for _,field in pairs(port(spec[1]).fields) do
        local mask=field.mask
        if (spec[1]==':P1_P2' or spec[1]==':P3_P4') and mask<=0x8000 then
            bindings[#bindings+1]={field=field,column=spec[mask>0xff and 3 or 2],mask=mask>0xff and (mask>>8) or mask}
        elseif spec[1]==':COIN' and mask<=8 then
            bindings[#bindings+1]={field=field,column=6,mask=mask}
        elseif spec[1]==':SYSTEM' and (mask==1 or mask==2 or mask==0x10 or mask==0x20 or mask==8) then
            bindings[#bindings+1]={field=field,column=8,mask=mask}
        end
    end
end
-- Keep notifier/taps alive globally, as required by MAME Lua.
play_subs={}
local coptrace=assert(io.open(OUT..'/cop-events.csv','w'))
local soundtrace=assert(io.open(OUT..'/sound-events.csv','w'))
local audio_stimulus,audio_timed=nil,nil
local last_sound_coin=nil
if os.getenv('CORE_AUDIO_STIMULUS')=='1' then
    audio_stimulus=assert(io.open(OUT..'/audio-stimulus.csv','w'))
    audio_timed=assert(io.open(OUT..'/timed-sound-events.csv','w'))
    audio_stimulus:write('cycle,kind,address,data,mask\n')
    audio_timed:write('cycle,address,data,mask,frame\n')
end
local function audio_cycle() return math.floor(emu.time()*96000000+0.5) end
local function stimulus(kind,address,data,mask)
    if audio_stimulus then
        audio_stimulus:write(string.format('%d,%s,%d,%d,%d\n',audio_cycle(),kind,address,data,mask))
    end
end
coptrace:write('frame,address,data,mask\n');soundtrace:write('frame,address,data,mask\n')
local copcount,soundcount=0,0
local distance=assert(io.open(OUT..'/distance-cases.csv','w'))
distance:write('frame,r0,r1,x0,y0,x1,y1,word38,word3a,expected\n')
local reg_hi,reg_lo={},{}
local pending_distance=nil
local distance_count=0
local mainspace=m.devices[':maincpu'].spaces['program']
if audio_stimulus then
    play_subs[#play_subs+1]=mainspace:install_write_tap(0x700,0x71f,'play_main_sound',function(address,data,mask)
        stimulus('write',address,data,mask)
    end)
end
local collision=nil
if os.getenv('CORE_COLLISION_CASES')=='1' then
    collision={pos={},hit={},base=0,pending=nil,count=0,frame=-1,perframe=0}
    collision.file=assert(io.open(OUT..'/collision-cases.csv','w'))
    collision.file:write('frame,r0,flags0,x0,y0,z0,cmd0,r1,flags1,x1,y1,z1,cmd1,r2,ptr0,base0,h0x,h0y,h0z,r3,ptr1,base1,h1x,h1y,h1z,status,dx,dy,dz,stat,box0_r0,box0_flags,box0_x,box0_y,box0_z,box0_cmd\n')
end
local function collision_command(address,data,mask)
    if not collision then return end
    if address==0x436 then collision.base=(collision.base & (~mask)) | (data & mask) end
    if address<0x500 or address>0x505 then return end
    local function reg(i) return ((reg_hi[i] or 0)<<16)|(reg_lo[i] or 0) end
    if data==0xa100 or data==0xa180 or data==0xa900 or data==0xa980 then
        local slot=(data==0xa100 or data==0xa180) and 0 or 1
        local addr=reg(slot)
        collision.pos[slot]={addr,mainspace:read_u16(addr+2),mainspace:read_u16(addr+6),
            mainspace:read_u16(addr+10),mainspace:read_u16(addr+14),data}
    elseif data==0xb100 or data==0xb900 then
        local slot=data==0xb100 and 0 or 1
        local addr=reg(slot+2)
        local ptr=mainspace:read_u16(addr)
        local desc=ptr|(collision.base<<16)
        collision.hit[slot]={addr,ptr,collision.base,mainspace:read_u16(desc),
            mainspace:read_u16(desc+2),mainspace:read_u16(desc+4)}
        if slot==0 then collision.box0=collision.pos[0] end
        if slot==1 and collision.pos[0] and collision.pos[1] and collision.hit[0] and collision.box0 then
            local values={m.screens[':screen']:frame_number()}
            for _,group in ipairs({collision.pos[0],collision.pos[1],collision.hit[0],collision.hit[1]}) do
                for _,v in ipairs(group) do values[#values+1]=v end
            end
            collision.pending={values=values,box0=collision.box0}
        end
    end
end
play_subs[#play_subs+1]=m.devices[':maincpu'].spaces['program']:install_write_tap(0x400,0x5ff,'play_cop',function(address,data,mask)
    if address>=0x4a0 and address<=0x4ac then reg_hi[(address-0x4a0)//2]=data end
    if address>=0x4c0 and address<=0x4cc then reg_lo[(address-0x4c0)//2]=data end
    collision_command(address,data,mask)
    if address>=0x500 and address<=0x505 and data==0x3b30 and distance_count<128 then
        local r0=((reg_hi[0] or 0)<<16)|(reg_lo[0] or 0)
        local r1=((reg_hi[1] or 0)<<16)|(reg_lo[1] or 0)
        pending_distance={m.screens[':screen']:frame_number(),r0,r1,
            mainspace:read_u32(r0+4),mainspace:read_u32(r0+8),
            mainspace:read_u32(r1+4),mainspace:read_u32(r1+8),
            mainspace:read_u16(r0+0x38),mainspace:read_u16(r0+0x3a)}
    end
    if copcount<50000 then
        coptrace:write(string.format('%d,%d,%d,%d\n',m.screens[':screen']:frame_number(),address,data,mask))
        copcount=copcount+1
    end
end)
if collision then
    play_subs[#play_subs+1]=mainspace:install_read_tap(0x580,0x589,'play_collision',function(address,data,mask)
        local pending=collision.pending
        collision.pending=nil -- nested getter reads below cannot create another sample
        local values=pending and pending.values
        if not values or values[1]<1400 or collision.count>=512 then return end
        for addr=0x580,0x588,2 do values[#values+1]=mainspace:read_u16(addr) end
        if collision.frame~=values[1] then collision.frame=values[1];collision.perframe=0 end
        if collision.perframe>=1 and not (values[26]==0 and collision.perframe<3) then return end
        for _,v in ipairs(pending.box0) do values[#values+1]=v end
        for i,v in ipairs(values) do collision.file:write(tostring(v),i==#values and '\n' or ',') end
        collision.file:flush();collision.count=collision.count+1;collision.perframe=collision.perframe+1
    end)
end
play_subs[#play_subs+1]=mainspace:install_read_tap(0x5b2,0x5b3,'play_distance',function(address,data,mask)
    if pending_distance and distance_count<128 then
        for _,value in ipairs(pending_distance) do distance:write(tostring(value),',') end
        distance:write(tostring(data),'\n');distance:flush()
        pending_distance=nil;distance_count=distance_count+1
    end
end)
for _,range in ipairs({{0x4000,0x401f},{0x6000,0x6000}}) do
    play_subs[#play_subs+1]=m.devices[':audiocpu'].spaces['program']:install_write_tap(range[1],range[2],'play_sound_'..range[1],function(address,data,mask)
        if audio_timed then
            audio_timed:write(string.format('%d,%d,%d,%d,%d\n',audio_cycle(),address,data,mask,m.screens[':screen']:frame_number()))
        end
        if soundcount<50000 then
            soundtrace:write(string.format('%d,%d,%d,%d\n',m.screens[':screen']:frame_number(),address,data,mask))
            soundcount=soundcount+1
        end
    end)
end
play_subs[#play_subs+1]=emu.add_machine_frame_notifier(function()
    local ok,err=pcall(function()
        local frame=m.screens[':screen']:frame_number()
        while index<=#events and events[index].frame<=frame do
            local e=events[index]
            assert(e[7]==initial[7],'DSW may not change during this fixture')
            assert((e[8]&0x0700)==(initial[8]&0x0700),'cabinet may not change during this fixture')
            for _,b in ipairs(bindings) do b.field:set_value((e[b.column]&b.mask)==0 and 1 or 0) end
            trace:write(tostring(frame))
            for i=2,8 do trace:write(',',string.format('0x%x',e[i])) end
            trace:write('\n');trace:flush()
            index=index+1
        end
        coptrace:flush();soundtrace:flush()
        if audio_stimulus then
            -- set_value changes the requested field state. The port's cached
            -- digital pins are updated by MAME's input frame refresh instead.
            local pins=port(':COIN'):read()&255
            if pins~=last_sound_coin then
                stimulus('coin',0,pins,255);last_sound_coin=pins
            end
            audio_stimulus:flush();audio_timed:flush()
        end
    end)
    if not ok then
        local errorfile=assert(io.open(OUT..'/ERROR.txt','a'));errorfile:write(tostring(err),'\n');errorfile:close()
        m:exit()
    end
end)
dofile(assert(os.getenv('CORE_CAPTURE_SCRIPT')))
