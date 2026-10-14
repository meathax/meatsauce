-- Actual legal gameplay then soft reset; observations only, no RAM/PC writes.
if _G.alpha_earned_reset_probe then return end
_G.alpha_earned_reset_probe = true
local machine = manager.machine
local main = assert(machine.devices[":maincpu"])
local space = main.spaces["program"]
local root = assert(os.getenv("ALPHA_CAPTURE_DIR"))
local ports = {}
for _,tag in ipairs({"IN0","IN1","IN2"}) do
    ports[tag] = assert(machine.ioport.ports[tag] or machine.ioport.ports[":"..tag])
end
local output = assert(io.open(root.."/reset_probe.csv","w"))
output:write("frame,best,first,last,main_pc,in0,in1,in2\n")
local frame,last_controls = 0,0
local function set_input(tag,mask,active)
    assert(ports[tag]:field(mask)):set_value(active and 1 or 0)
end
local function drive_inputs()
    if frame == 120 then set_input("IN2",1,true) end
    if frame == 126 then set_input("IN2",1,false) end
    local desired = frame >= 160 and frame < 166 and 0x80 or 0
    if frame >= 260 then
        local phase = (frame-260)%600
        desired = phase < 360 and 1 or (phase < 420 and 4 or (phase < 540 and 1 or 8))
        if (frame-260)%18 < 14 then desired = desired | 0x10 end
        if frame >= 480 and (frame-480)%180 < 4 then desired = desired | 0x20 end
    end
    for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do
        if (desired & mask) ~= (last_controls & mask) then
            set_input("IN0",mask,(desired & mask) ~= 0)
        end
    end
    last_controls = desired
end
local function observe()
    output:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d\n",frame,
        space:read_u32(0x20020),space:read_u8(0x20e00),space:read_u8(0x20ead),
        main.state["PC"].value,ports.IN0:read(),ports.IN1:read(),ports.IN2:read()))
    if frame < 900 then drive_inputs() end
    if frame == 900 then
        for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do set_input("IN0",mask,false) end
        set_input("IN2",1,false)
        output:flush()
        machine:soft_reset()
    end
    frame = frame+1
    if frame == 1041 then
        output:close()
        local complete = assert(io.open(root.."/complete.txt","w"))
        complete:write("1041\n");complete:close();machine:exit()
    end
end
_G.alpha_earned_reset_subscription = emu.add_machine_frame_notifier(function()
    if _G.alpha_earned_reset_failed then return end
    local ok,err = xpcall(observe,debug.traceback)
    if not ok then
        _G.alpha_earned_reset_failed = true
        local failure = assert(io.open(root.."/failure.txt","w"))
        failure:write(err);failure:close();machine:exit()
    end
end)
