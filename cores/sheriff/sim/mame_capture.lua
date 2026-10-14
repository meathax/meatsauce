-- SPDX-License-Identifier: GPL-2.0-or-later
-- MAME 0.289. API references: docs.mamedev.org/luascript/ref-{mem,devices,input}.html
-- Output directory must already exist; all payloads remain ignored locally.
local output = os.getenv('SHERIFF_CAPTURE') or 'sim/results/mame'
local limit = tonumber(os.getenv('SHERIFF_FRAMES') or '1800')
local pixel_probe = os.getenv('SHERIFF_PIXEL_PROBE') == '1'
local irq_probe = os.getenv('SHERIFF_IRQ_PROBE') == '1'
local sound_probe = os.getenv('SHERIFF_SOUND_PROBE') == '1'
local exact_probe = os.getenv('SHERIFF_EXACT_OBSERVATIONS') == '1'
local irq_frame = tonumber(os.getenv('SHERIFF_IRQ_FRAME') or '57')
local write_probe_frame=tonumber(os.getenv('SHERIFF_WRITE_PROBE_FRAME') or '-1')
local input_probe_frame=tonumber(os.getenv('SHERIFF_INPUT_PROBE_FRAME') or '-1')
local taps, machine, cpu, screen, program, trace, states
local frame = 0
local events, event_index = {}, 1
local pending_pixels, traces_closed
local policy, generated, diagnostics, last_input
local input_observations, observe_input, applied_input
local observation_sequence=0
local exact_observations, exact_sequence
local function apply_input(e)
    for n=0,2 do
        local p=machine.ioport.ports[':IN'..n]
        for bit=0,7 do
            local mask=1<<bit; local field=p:field(mask)
            if field then field:set_value((e[n+2]&mask)~=0 and 1 or 0) end
        end
    end
    local dips=machine.ioport.ports[':IN3']
    dips:field(0x03).user_value=e[5]&0x03
    dips:field(0x80).user_value=e[5]&0x80
    applied_input=e
    if observe_input then observe_input('apply',e) end
    if generated then
        local changed=not last_input
        for i=2,5 do if not last_input or last_input[i]~=e[i] then changed=true end end
        if changed then
            generated:write(string.format('%d,%d,%d,%d,%d\n',e[1],e[2],e[3],e[4],e[5]))
            last_input=e
        end
    end
end
local function binary(name, bytes)
    local f = assert(io.open(output .. '/' .. name, 'wb')); f:write(bytes); f:close()
end
-- Some local 0.289 screen bindings expose getters as methods, despite the
-- published reference listing them as properties. Resolve the actual binding.
local function value(object, key)
    local result = object[key]
    if type(result) == 'function' then return result(object) end
    return result
end
local function time() return string.format('%.12f',value(machine,'time'):as_double()) end
-- Retain both the callback order and its exact context-dependent emulated time.
-- CPU callbacks can precede a frame callback while reporting a later time.
-- A sidecar keeps every existing reference stream and schema unchanged.
local function exact_observe(kind,address,data,device,p1,p2)
    if not exact_observations or traces_closed then return end
    local t=value(machine,'time')
    local seconds,attoseconds=value(t,'seconds'),value(t,'attoseconds')
    assert(math.type(seconds)=='integer' and math.type(attoseconds)=='integer',
        'Exact observation requires integer attotime fields')
    exact_sequence=exact_sequence+1
    exact_observations:write(string.format('%d,%s,%d,%d,%d,%d,%s,%s,%s,%s,%s\n',
        exact_sequence,kind,frame,seconds,attoseconds,(device or cpu).state['PC'].value,
        address or '',data or '',p1 or '',p2 or '',p2 and ((p2>>7)&1) or ''))
end
local function beam()
    -- Upstream 0.289 exposes time_until_pos, but not vpos/hpos in Lua.
    -- Recover the raster position from that exact emulated time interval.
    local remaining=screen:time_until_pos(0,0)*5040000
    local pixel=(81920-math.floor(remaining+0.5))%81920
    return math.floor(pixel/320),pixel%320
end
-- Diagnostic event order is independent of machine.time, which can be a
-- CPU-local scheduler time inside an instruction-atomic I/O callback.
observe_input=function(kind,e,address,data)
    if not input_observations or traces_closed then return end
    observation_sequence=observation_sequence+1
    if frame<input_probe_frame-1 or frame>input_probe_frame+1 then return end
    local y,x=beam(); local pins=e or applied_input or {}
    input_observations:write(string.format('%d,%s,%d,%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d\n',
        observation_sequence,time(),frame,y,x,kind,e and e[1] or '',
        pins[2] or '',pins[3] or '',pins[4] or '',pins[5] or '',
        address or '',data or '',cpu.state['PC'].value))
end
-- Epoch sidecar records observation sites; Lua does not expose the active
-- scheduler context, external CPU pins, or the logical reset edge itself.
local epochs,epoch_sequence
local function epoch(event,site)
    if not epochs then return end
    epoch_sequence=epoch_sequence+1
    local t=value(machine,'time')
    local y,x=beam()
    epochs:write(string.format('%d,%s,%d,%s,%s,%s,%d,%d,%d,%s,%s,%s,%s\n',
        epoch_sequence,event,frame,tostring(value(t,'seconds')),
        tostring(value(t,'attoseconds')),time(),cpu.state['PC'].value,y,x,site,
        'scheduler_time_context_unexposed','false',
        os.getenv('SHERIFF_CAPTURE_LUA_SHA256') or 'unavailable'))
    epochs:flush()
end
local function start_capture()
    machine = manager.machine
    cpu = machine.devices[':maincpu']; screen = machine.screens[':screen']
    program = cpu.spaces['program']
    epochs=assert(io.open(output..'/capture_epochs.csv','w'))
    epoch_sequence=0
    epochs:write('sequence,event,frame,time_seconds,time_attoseconds,time_decimal,pc,y,x,sample_site,timestamp_kind,reset_edge_observed,lua_sha256\n')
    epoch('autoboot_capture_start','existing_autoboot_start_after_machine_initialization')
    local provenance=assert(io.open(output..'/capture_epoch_sources.csv','w'))
    provenance:write('lua_sha256,launcher_sha256\n')
    provenance:write((os.getenv('SHERIFF_CAPTURE_LUA_SHA256') or 'unavailable')..','..
        (os.getenv('SHERIFF_CAPTURE_LAUNCHER_SHA256') or 'unavailable')..'\n')
    provenance:close()
    if exact_probe then
        exact_observations=assert(io.open(output..'/observations_exact.csv','w'))
        exact_observations:write('sequence,kind,frame,time_seconds,time_attoseconds,pc,address,data,p1,p2,dac\n')
        exact_sequence=0
    end
    local ports = cpu.spaces['io']
    trace = assert(io.open(output .. '/io.csv', 'w'))
    trace:write('time,frame,y,x,kind,address,data,pc\n')
    states = assert(io.open(output .. '/states.csv', 'w'))
    states:write('frame,time,pc,sp,a,bc,de,hl,y,x\n')
    if input_probe_frame>=0 then
        input_observations=assert(io.open(output..'/input_observations.csv','w'))
        input_observations:write('sequence,time,frame,y,x,kind,event_frame,p0,p1,p2,dip,address,data,pc\n')
    end
    taps = {}
    local function log(kind, address, data)
        exact_observe('io_'..kind,address,data)
        local y,x=beam()
        trace:write(string.format('%s,%d,%d,%d,%s,%d,%d,%d\n', time(), frame,
            y,x,kind,address,data,cpu.state['PC'].value))
        observe_input(kind,nil,address,data)
    end
    taps[#taps+1] = ports:install_write_tap(0,7,'sheriff_outputs',function(a,d,m) log('out',a,d) end)
    taps[#taps+1] = ports:install_read_tap(0,7,'sheriff_inputs',function(a,d,m) log('in',a,d) end)
    local hist = assert(io.open(output .. '/video_writes.csv','w'))
    hist:write('time,frame,y,x,address,data\n')
    taps[#taps+1] = program:install_write_tap(0x4000,0x7fff,'bitmap_writes',function(a,d,m)
        exact_observe('ram_write',a,d)
        local y,x=beam()
        hist:write(string.format('%s,%d,%d,%d,%d,%d\n', time(),frame,y,x,a,d))
    end)
    -- Keep the file alive with the handlers and flush on stop.
    taps.hist = hist
    if write_probe_frame>=0 then
        local write_pc=assert(io.open(output..'/write_pc.csv','w'))
        write_pc:write('time,frame,address,data,pc\n')
        taps[#taps+1]=program:install_write_tap(0x4000,0x7fff,'write_instruction_pc',function(a,d,m)
            if frame>=write_probe_frame-1 and frame<=write_probe_frame+1 then
                write_pc:write(string.format('%s,%d,%d,%d,%d\n',time(),frame,a,d,cpu.state['PC'].value))
            end
        end)
        taps.write_pc=write_pc
    end
    if sound_probe then
        local soundcpu=assert(machine.devices[':soundboard:cpu'],'Sheriff sound CPU missing')
        local sound_program=assert(soundcpu.spaces['program'])
        local sound_states=soundcpu.state
        local p1_state,p2_state=assert(sound_states['P1']),assert(sound_states['P2'])
        local pins=assert(io.open(output..'/sound_pins.csv','w'))
        pins:write('time,frame,pc,p1,p2,dac\n')
        local old_p1,old_p2=-1,-1
        -- MCS48 port callbacks are not AS_IO writes. Observe its output
        -- latches at the next program read, at the completed instruction's
        -- local time, rather than sampling only at video frame boundaries.
        taps[#taps+1]=sound_program:install_read_tap(0,0x3ff,'sound_output_latches',function(a,d,m)
            local p1,p2=p1_state.value,p2_state.value
            if p1~=old_p1 or p2~=old_p2 then
                exact_observe('sound_latches',nil,nil,soundcpu,p1,p2)
                pins:write(string.format('%s,%d,%d,%d,%d,%d\n',time(),frame,
                    sound_states['PC'].value,p1,p2,(p2>>7)&1))
                old_p1,old_p2=p1,p2
            end
        end)
        taps.sound=pins
    end
    if irq_probe then
        local reads=assert(io.open(output..'/irq_program_reads.csv','w'))
        reads:write('time,frame,address,data,pc\n')
        taps[#taps+1]=program:install_read_tap(0,0x3fff,'irq_boundary_reads',function(a,d,m)
            if frame>=irq_frame and frame<=irq_frame+1 then
                exact_observe('program_read',a,d)
                reads:write(string.format('%s,%d,%d,%d,%d\n',time(),frame,a,d,cpu.state['PC'].value))
            end
        end)
        taps.reads=reads
    end
    local f = assert(io.open(os.getenv('SHERIFF_INPUTS') or 'sim/inputs.csv','r'))
    for line in f:lines() do
        local n,p0,p1,p2,dip = line:match('^(%d+),(%d+),(%d+),(%d+),(%d+)')
        if n then events[#events+1] = {tonumber(n),tonumber(p0),tonumber(p1),tonumber(p2),tonumber(dip)} end
    end
    f:close()
    local policy_path=os.getenv('SHERIFF_INPUT_POLICY')
    if policy_path and policy_path~='' then
        policy=assert(dofile(policy_path))
        generated=assert(io.open(output..'/inputs_generated.csv','w'))
        generated:write('frame,p0,p1,p2,dip\n')
        diagnostics=assert(io.open(output..'/policy_diagnostics.csv','w'))
        diagnostics:write('frame,px,py,tx,ty,enemies,p0\n')
    end
end
-- Autoboot scripts run after the machine's start notification. Initialize
-- immediately rather than registering a callback for a notification we missed.
start_capture()
emu.register_frame_done(function()
    if not machine then return end
    frame = frame + 1
    epoch('frame_callback_begin','existing_register_frame_done_callback')
    exact_observe('frame_begin')
    -- screen_device::pixels reads m_bitmap[m_curbitmap]. update_quads has
    -- already selected the other texture and advanced that drawing-buffer
    -- index when this notifier runs. Read the paired image one callback later.
    -- The phase probe proves this pairing; do not alter the FPGA scanout.
    if pending_pixels then
        local pixels,w,h = screen:pixels()
        binary(pending_pixels.stem..'.idx32',pixels)
        local y,x=beam()
        local meta=assert(io.open(output..'/'..pending_pixels.stem..'.meta','w'))
        meta:write(string.format('width=%d height=%d ram_frame=%d pixel_callback=%d screen_frame=%d y=%d x=%d ram_time=%s pixel_time=%s\n',w,h,pending_pixels.frame,frame,value(screen,'frame_number'),y,x,pending_pixels.time,time()))
        meta:close(); pending_pixels=nil
    end
    while events[event_index] and events[event_index][1] <= frame do
        local e = events[event_index]; event_index = event_index+1
        apply_input(e)
    end
    if policy and frame<=limit then
        local p0,p1,p2,dip,detail=policy.step(frame,program)
        if p0 then apply_input({frame,p0,p1,p2,dip}) end
        if detail then diagnostics:write(string.format('%d,%d,%d,%d,%d,%d,%d\n',frame,table.unpack(detail))) end
    end
    if frame<=limit and (frame <= 4 or frame%60 == 0 or frame == limit or
       (pixel_probe and (frame%60 == 59 or frame%60 == 1))) then
        local y,x=beam()
        local stem = string.format('frame_%05d',frame)
        binary(stem..'.ram',program:read_range(0x4000,0x7fff,8))
        exact_observe('ram_snapshot')
        pending_pixels={stem=stem,frame=frame,time=time()}
        states:write(string.format('%d,%s,%d,%d,%d,%d,%d,%d,%d,%d\n',frame,time(),cpu.state['PC'].value,cpu.state['SP'].value,cpu.state['A'].value,cpu.state['BC'].value,cpu.state['DE'].value,cpu.state['HL'].value,y,x))
    end
    exact_observe('frame_end')
    if frame >= limit then
        if not traces_closed then
            for _,tap in ipairs(taps) do tap:remove() end
            trace:close(); states:close(); taps.hist:close(); if taps.reads then taps.reads:close() end
            if taps.sound then taps.sound:close() end; traces_closed=true
            if epochs then epochs:close(); epochs=nil end
            if taps.write_pc then taps.write_pc:close() end
            if input_observations then input_observations:close() end
            if exact_observations then exact_observations:close() end
            if generated then generated:close(); diagnostics:close() end
        end
        if not pending_pixels then machine:exit() end
    end
end)
