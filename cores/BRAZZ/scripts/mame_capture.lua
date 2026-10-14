-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only reference instrumentation. Capture paths are configured by the
-- Python runner in CS_CAPTURE_DIRECTORY. No ROM/state data enters Git.
local output = assert(os.getenv("CS_CAPTURE_DIRECTORY"), "missing capture directory")
local gameplay = os.getenv("CS_CAPTURE_GAMEPLAY") == "1"
local max_frames = tonumber(os.getenv("CS_CAPTURE_FRAMES")) or 3600
local pixel_frames = {}
for value in string.gmatch(os.getenv("CS_CAPTURE_PIXEL_FRAMES") or "", "%d+") do
    pixel_frames[tonumber(value)] = true
end
local input_event_count = 0
local machine = manager.machine
local cpu = assert(machine.devices[":maincpu"], "main CPU not found")
local program = assert(cpu.spaces["program"], "main CPU program space not found")
local screen
for _, candidate in pairs(machine.screens) do screen = candidate; break end
assert(screen, "screen not found")
local mmio = assert(io.open(output .. "/mmio.csv", "w"))
local frames = assert(io.open(output .. "/frames.csv", "w"))
local inputs = assert(io.open(output .. "/inputs.txt", "w"))
mmio:write("frame,pc,operation,address,data,mask,count\n")
frames:write("frame,pc,sr,sp,er,queue_front,queue_rear,queue_control\n")
for tag, port in pairs(machine.ioport.ports) do
    for name, _ in pairs(port.fields) do inputs:write(tag .. "\t" .. name .. "\n") end
end
inputs:close()
local input_log = assert(io.open(output .. "/input_events.csv", "w"))
input_log:write("frame,port,field,value\n")
local function set_input(tag, name, value, at_frame)
    local port = assert(machine.ioport.ports[tag], "input port missing: " .. tag)
    local field = assert(port.fields[name], "input field missing: " .. name)
    field:set_value(value)
    input_event_count = input_event_count + 1
    input_log:write(string.format("%d,%s,%s,%d\n",at_frame,tag,name,value))
end
local function gameplay_inputs(at_frame)
    local actions = {
        [900]={":SYSTEM","Coin 1",1}, [908]={":SYSTEM","Coin 1",0},
        [940]={":SYSTEM","1 Player Start",1}, [948]={":SYSTEM","1 Player Start",0},
        [980]={":P1_P2","P1 Button 1",1}, [988]={":P1_P2","P1 Button 1",0},
        [1040]={":P1_P2","P1 Button 1",1}, [1048]={":P1_P2","P1 Button 1",0},
        [1500]={":SYSTEM","Coin 1",1}, [1508]={":SYSTEM","Coin 1",0},
        [1540]={":SYSTEM","2 Players Start",1}, [1548]={":SYSTEM","2 Players Start",0},
        [1600]={":P1_P2","P2 Button 1",1}, [1608]={":P1_P2","P2 Button 1",0},
        [1660]={":P1_P2","P2 Button 1",1}, [1668]={":P1_P2","P2 Button 1",0}
    }
    local action = actions[at_frame]
    if action then set_input(action[1],action[2],action[3],at_frame) end
    if at_frame >= 1200 and at_frame % 60 == 0 then
        set_input(":P1_P2","P1 Right",1,at_frame)
        set_input(":P1_P2","P1 Button 1",1,at_frame)
    elseif at_frame >= 1200 and at_frame % 60 == 20 then
        set_input(":P1_P2","P1 Right",0,at_frame)
        set_input(":P1_P2","P1 Button 1",0,at_frame)
    end
    if at_frame >= 1800 and at_frame % 60 == 30 then
        set_input(":P1_P2","P2 Right",1,at_frame)
        set_input(":P1_P2","P2 Button 1",1,at_frame)
    elseif at_frame >= 1800 and at_frame % 60 == 50 then
        set_input(":P1_P2","P2 Right",0,at_frame)
        set_input(":P1_P2","P2 Button 1",0,at_frame)
    end
end
local frame = 0
local reads, writes = 0, 0
local finished, observing = false, true
local pending_read
local taps = {}
local function state(name)
    local item = cpu.state[name]
    return item and item.value or 0
end
local function flush_read()
    if pending_read then
        mmio:write(string.format("%d,%08x,R,%08x,%08x,%08x,%d\n",
            pending_read.frame,pending_read.pc,pending_read.address,
            pending_read.data,pending_read.mask,pending_read.count))
        pending_read = nil
    end
end
local packets = assert(io.open(output .. "/gpu_packets.csv", "w"))
packets:write("frame,pc,index,active")
for i=0,31 do packets:write(",word" .. i) end
packets:write("\n")
local submitted_packets, first_gpu_snapshot = 0, false
local function save_memory(name, first, last)
    local data = program:read_range(first, last, 8)
    assert(#data == last-first+1, "memory capture length mismatch")
    local file = assert(io.open(output .. "/" .. name, "wb"))
    file:write(data); file:close()
end
local audio_status, first_audio_snapshot = 0, false
local function capture_audio(address, data, mask)
    if first_audio_snapshot or (address ~= 0x04800404 and address ~= 0x04800600) then return end
    observing = false
    local control_before = program:read_u16(0x04800602)
    local control_after = control_before
    local chnnum = program:read_u16(0x04800600)
    local next_status = audio_status
    if address == 0x04800404 then
        for half=0,1 do
            if ((mask >> (half*16)) & 0xffff) ~= 0 then
                local value = (data >> (half*16)) & 0xffff
                local bit = 1 << (value & 31)
                if (value & 0x8000) ~= 0 then next_status = next_status | bit
                else next_status = next_status & ~bit end
            end
        end
    else
        local cmask = (mask >> 16) & 0xffff
        control_after = (control_before & ~cmask) | ((data >> 16) & cmask)
        local nmask = mask & 0xffff
        chnnum = (chnnum & ~nmask) | (data & nmask)
    end
    audio_status = next_status
    if next_status ~= 0 and (control_after & 0x8000) ~= 0 then
        first_audio_snapshot = true
        save_memory("first_audio_texture.bin",0x03800000,0x03ffffff)
        save_memory("first_audio_frame.bin",0x04000000,0x047fffff)
        local meta = assert(io.open(output .. "/first_audio_state.json","w"))
        meta:write(string.format('{"frame":%d,"pc":"%08x","pending_address":"%08x","pending_data":"%08x","pending_mask":"%08x","control_before":%d,"control_after":%d,"chnnum_after":%d,"status_after":%d,"scope":"coherent register/memory snapshot before first active sound assignment; pending global write reflected in metadata, channel registers precede that write","channel_registers":[',frame,state("PC"),address,data,mask,control_before,control_after,chnnum,next_status & 0xffffffff))
        for channel=0,31 do
            if channel ~= 0 then meta:write(",") end
            meta:write("[")
            for word=0,15 do
                if word ~= 0 then meta:write(",") end
                meta:write(string.format("%d",program:read_u16(0x04800000+channel*32+word*2)))
            end
            meta:write("]")
        end
        meta:write("]}\n");meta:close()
    end
    observing = true
end
local function capture_submission(address, data, mask)
    if address ~= 0x03000080 or (mask & 0xffff) == 0 then return end
    observing = false
    local previous = program:read_u16(0x03000080) & 0x7ff
    local next_front = ((previous & ~(mask & 0xffff)) | (data & mask & 0xffff)) & 0x7ff
    local active = (program:read_u16(0x0300008c) & 4) ~= 0
    local has_draw,scan = false,previous
    while scan ~= next_front do
        local control_word = program:read_u16(0x03800000+scan*64)
        if (control_word & 0x100) ~= 0 and (control_word & 0x81) == 0 then has_draw = true end
        scan = (scan+1) & 0x7ff
    end
    if active and has_draw and not first_gpu_snapshot then
        save_memory("first_gpu_texture.bin",0x03800000,0x03ffffff)
        save_memory("first_gpu_frame_before.bin",0x04000000,0x047fffff)
        local meta = assert(io.open(output .. "/first_gpu_batch.json","w"))
        meta:write(string.format('{"frame":%d,"first":%d,"end":%d,"control":%d,"display_bank":%d,"bank1":%d,"scope":"memory before first active drawing submission; prior state packets and draw destination require integrated replay"}\n',frame,previous,next_front,program:read_u16(0x0300008c),program:read_u16(0x0300008e),program:read_u16(0x03000090)))
        meta:close(); first_gpu_snapshot = true
    end
    local index = previous
    while index ~= next_front do
        packets:write(string.format("%d,%08x,%d,%d",frame,state("PC"),index,active and 1 or 0))
        for word=0,31 do packets:write(string.format(",%04x",program:read_u16(0x03800000+index*64+word*2))) end
        packets:write("\n"); submitted_packets = submitted_packets+1
        index = (index+1) & 0x7ff
    end
    observing = true
end
local regions = {
    {0x01200000, 0x013fffff, "board"},
    {0x01800000, 0x018fffff, "soc"},
    {0x03000000, 0x0300ffff, "video"},
    {0x04800000, 0x04800fff, "sound"},
    {0x05000000, 0x05000003, "flash"}
}
for _, region in ipairs(regions) do
    taps[#taps + 1] = program:install_read_tap(region[1], region[2], "cs_read_" .. region[3], function(address, data, mask)
        if finished or not observing then return end
        reads = reads + 1
        local pc = state("PC")
        data, mask = data & 0xffffffff, mask & 0xffffffff
        if pending_read and pending_read.frame == frame and pending_read.pc == pc and
            pending_read.address == address and pending_read.data == data and pending_read.mask == mask then
            pending_read.count = pending_read.count + 1
        else
            flush_read()
            pending_read = {frame=frame,pc=pc,address=address,data=data,mask=mask,count=1}
        end
    end)
    taps[#taps + 1] = program:install_write_tap(region[1], region[2], "cs_write_" .. region[3], function(address, data, mask)
        if finished or not observing then return end
        writes = writes + 1
        capture_audio(address,data & 0xffffffff,mask & 0xffffffff)
        capture_submission(address,data,mask)
        flush_read()
        mmio:write(string.format("%d,%08x,W,%08x,%08x,%08x,1\n", frame, state("PC"), address, data & 0xffffffff, mask & 0xffffffff))
    end)
end
local control_log = assert(io.open(output .. "/cpu_control.csv","w"))
control_log:write("frame,pc,opcode,r0,r1,r2,r3,r4,r5,r6,r7,sr,sp,er\n")
local control_fetches = 0
for r=0,7 do assert(cpu.state["R" .. r], "missing CPU register state") end
local control_tap = program:install_read_tap(0x020820b0,0x020820ef,"cs_cpu_control",function(address,data,mask)
    if finished or not observing or control_fetches>=2048 then return end
    local pc = state("PC")
    for half=0,1 do
        if pc==address+half*2 and ((mask>>(half*16))&0xffff)~=0 then
            control_log:write(string.format("%d,%08x,%04x",frame,pc,(data>>(half*16))&0xffff))
            for r=0,7 do control_log:write(string.format(",%08x",state("R" .. r))) end
            control_log:write(string.format(",%08x,%08x,%08x\n",state("SR"),state("SP"),state("ER")))
            control_fetches=control_fetches+1
        end
    end
end)
-- At frame_done screen:pixels reads the newly swapped draw bitmap. Use the
-- native snapshot texture for presented pixels (screen.cpp update_quads).
-- Bank registers may describe the next bank; retain candidate bytes and let
-- the postprocessor match the presented pixels rather than guessing.
local function capture_native_pixels()
    local width, height = screen.width, screen.height
    local stem = output .. string.format("/native_%06d", frame)
    assert(not screen:snapshot(stem .. ".png"), "native presented snapshot failed")
    local metadata = assert(io.open(stem .. ".json", "w"))
    metadata:write(string.format('{"schema":1,"scope":"native MAME presented screen; not RTL acceptance","frame":%d,"width":%d,"height":%d,"complete_screen":true,"pc":"%08x","queue_front":%d,"queue_rear":%d,"control":%d,"display_bank_register":%d,"bank1_register":%d,"input_event_count":%d}\n',
        frame,width,height,state("PC"),program:read_u16(0x03000080),program:read_u16(0x03000082),
        program:read_u16(0x0300008c),program:read_u16(0x0300008e),program:read_u16(0x03000090),input_event_count))
    metadata:close()
    if width == 320 and height == 240 then
        for _, base in ipairs({0,0x100000,0x400000}) do
            local candidate = assert(io.open(stem .. string.format("_bank_%06x.rgb565",base),"wb"))
            for y=0,height-1 do
                local address = 0x04000000 + base + y * 2048
                local row = program:read_range(address,address+width*2-1,8)
                assert(#row == width*2,"bank row capture byte count")
                candidate:write(row)
            end
            candidate:close()
        end
    end
end

local snapshots = {[1]=true, [300]=true, [900]=true, [1800]=true, [3600]=true}
emu.register_frame_done(function()
    -- Keep the tap userdata reachable after the autoboot chunk returns. Their
    -- garbage collectors otherwise remove instrumentation during the run.
    assert(#taps == #regions * 2 and control_tap, "capture tap ownership lost")
    if finished then return end
    frame = frame + 1
    if gameplay then gameplay_inputs(frame) end
    flush_read()
    -- Inspection reads must not add taps or side effects to the game trace.
    observing = false
    frames:write(string.format("%d,%08x,%08x,%08x,%08x,%04x,%04x,%04x\n", frame,
        state("PC"), state("SR"), state("SP"), state("ER"),
        program:read_u16(0x03000080), program:read_u16(0x03000082), program:read_u16(0x0300008c)))
    observing = true
    if pixel_frames[frame] then
        observing=false;capture_native_pixels();observing=true
    end
    if snapshots[frame] then screen:snapshot(output .. string.format("/frame_%06d.png", frame)) end
    if frame >= max_frames then
        finished = true
        mmio:close(); frames:close(); input_log:close(); packets:close(); control_log:close()
        local summary = assert(io.open(output .. "/complete.json", "w"))
        summary:write(string.format('{"frames":%d,"reads":%d,"writes":%d,"max_frames":%d,"submitted_gpu_packets":%d,"read_encoding":"lossless consecutive RLE; each write retained"}\n',frame,reads,writes,max_frames,submitted_packets))
        summary:close()
        machine:exit()
    end
end)
print("Crystal System reference capture installed before frame " .. frame)
