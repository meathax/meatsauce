-- Read-only observer of the COP sort-DMA ($6FE) on pristine MAME 0.289 zeroteam.
-- Logs the trigger value, the five sort registers and the lookup table / 32-bit
-- keys before the sort and the lookup table at the next frame. No writes.
local m=manager.machine
local OUT=assert(os.getenv('CORE_OUT'))
local sp=m.devices[':maincpu'].spaces['program']
local log=assert(io.open(OUT..'/sort-cases.csv','w'))
log:write('frame,data,ram,lookup,param,phase,entries\n')
local regs={[0x450]=0,[0x452]=0,[0x454]=0,[0x456]=0,[0x458]=0}
sort_subs={}
local pending={}
local function frame() return m.screens[':screen']:frame_number() end
local function dump(c,phase,withkeys)
    local t={}
    for i=0,c.data+1 do
        local v=sp:read_u16(c.lookup+2*i)
        if withkeys then
            t[#t+1]=string.format('%04x:%08x:%04x',v,sp:read_u32(c.ram+v),sp:read_u16(c.ram+v+((c.ram+v)&2)==0 and 0 or 0))
        else t[#t+1]=string.format('%04x',v) end
    end
    log:write(string.format('%d,%d,%x,%x,%d,%s,%s\n',c.frame,c.data,c.ram,c.lookup,c.param,phase,table.concat(t,' ')))
end
sort_subs[#sort_subs+1]=sp:install_write_tap(0x450,0x459,'sortprobe_regs',function(a,d,mask)
    regs[a&~1]=d
end)
sort_subs[#sort_subs+1]=sp:install_write_tap(0x6fe,0x6ff,'sortprobe_trig',function(a,d,mask)
    local c={frame=frame(),data=d&0xffff,ram=((regs[0x450]&0xff)<<16)|regs[0x452],
             lookup=((regs[0x454]&0xff)<<16)|regs[0x456],param=regs[0x458]}
    dump(c,'before',true)
    pending[#pending+1]=c
end)
sort_subs[#sort_subs+1]=emu.add_machine_frame_notifier(function()
    for _,c in ipairs(pending) do dump(c,'after',false) end
    pending={}
    log:flush()
end)
dofile(assert(os.getenv('CORE_PLAY')))
