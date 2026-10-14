-- MAME 0.289 reference recorder. Observes actual game execution without changing RAM.
local machine = manager.machine
local screen = assert(machine.screens[":screen"], "screen missing")
local main = assert(machine.devices[":maincpu"], "main CPU missing")
local sound = assert(machine.devices[":audiocpu"], "sound CPU missing")
local space = main.spaces["program"]
local root = assert(os.getenv("ALPHA_CAPTURE_DIR"), "capture directory required")
local mode = os.getenv("ALPHA_CAPTURE_MODE") or "attract"
local total = tonumber(os.getenv("ALPHA_CAPTURE_FRAMES") or "1800")
local frame = 0
local handles = {}
local counts = {}
local taps = {}
local ports = {}
for _, tag in ipairs({"IN0", "IN1", "IN2"}) do
    ports[tag] = assert(machine.ioport.ports[":" .. tag] or machine.ioport.ports[tag],
                        "missing input port " .. tag)
end
local sample_frames = {[0]=true,[30]=true,[90]=true,[119]=true,[179]=true,
                       [240]=true,[360]=true,[600]=true,[900]=true,[1200]=true,[1799]=true}

local function open(name, mode_arg)
    return assert(io.open(root .. "/" .. name, mode_arg or "w"))
end
local events = open("events.csv")
events:write("frame,screen_frame,area,address,data,mask,vpos\n")
local inputs = open("inputs.csv")
inputs:write("frame,port,mask,active,name\n")
local states = open("states.csv")
states:write("frame,screen_frame,main_pc,sound_pc,in0,in1,in2,width,height\n")
local status = open("status.csv")
status:write("frame,screen_frame\n")
local frame_states = open("frame_states.csv")
frame_states:write("frame,screen_frame,main_pc,sound_pc,main_sr,in0,in1,in2,background\n")

-- 0.289 exposes time_until_pos, not vpos/hpos. Match screen.cpp's half-pixel rounding.
local function beam()
    local phase = (screen.frame_period - screen:time_until_pos(0,0)) % screen.frame_period
    local pixel = math.floor(phase / screen.pixel_period + 0.5) % (384*264)
    return pixel // 384, pixel % 384
end

local function pc(device)
    local entry = device.state["PC"] or device.state["CURPC"]
    assert(entry, "CPU PC state missing")
    return entry.value
end

local function observe(area, address, data, mask)
    local scan = beam()
    local segment = frame < 120 and "early" or (frame < 180 and "pre_start" or "post_start")
    local key = segment .. "," .. area .. "," .. tostring(scan)
    counts[key] = (counts[key] or 0) + 1
    -- Detailed events cover boot and the coin/start handshakes, plus small late windows.
    if true then -- complete finite sound observations
        events:write(string.format("%d,%d,%s,%d,%d,%d,%d\n",
            frame, screen:frame_number(), area, address, data, mask, scan))
    end
end

handles[#handles+1] = space:install_write_tap(0x040000, 0x041fff, "alpha_sprite_sweep", function(a,d,m)
    local word = (a - 0x040000) // 2
    local area = word < 0x400 and "positions" or ("tiles" .. tostring(word // 0x400))
    observe(area,a,d,m)
end)
handles[#handles+1] = space:install_write_tap(0x020000, 0x020fff, "alpha_work_sweep", function(a,d,m)
    observe("work",a,d,m)
end)
handles[#handles+1] = space:install_write_tap(0x060000, 0x060001, "alpha_background", function(a,d,m)
    observe("background_watchdog",a,d,m)
end)
handles[#handles+1] = space:install_write_tap(0x080000, 0x0801ff, "alpha_mcu_write", function(a,d,m)
    observe("mcu_command_write",a,d,m)
end)
handles[#handles+1] = space:install_read_tap(0x080000, 0x0801ff, "alpha_mcu_read", function(a,d,m)
    observe("mcu_command_read",a,d,m)
end)
handles[#handles+1] = space:install_write_tap(0x0e0000,0x0e0001,"alpha_sound_latch",function(a,d,m)
    observe("sound_latch_write",a,d,m)
end)
handles[#handles+1] = space:install_read_tap(0x000060,0x00007f,"alpha_vector_read",function(a,d,m)
    observe("main_vector_read",a,d,m)
end)
handles[#handles+1] = sound.spaces["program"]:install_read_tap(0xe000,0xe000,"alpha_sound_latch_read_k",function(a,d,m)
    observe("sound_latch_read",a,d,m)
end)
handles[#handles+1] = sound.spaces["program"]:install_read_tap(0xc100,0xc100,"alpha_sound_latch_read_s",function(a,d,m)
    observe("sound_latch_read",a,d,m)
end)
handles[#handles+1] = sound.spaces["program"]:install_write_tap(0xc000,0xffff,"alpha_sound_memory",function(a,d,m)
    observe("sound_memory",a,d,m)
end)
handles[#handles+1] = sound.spaces["io"]:install_write_tap(0,0xff,"alpha_sound_io",function(a,d,m)
    observe("sound_io",a,d,m)
end)

local function set_input(tag, mask, active)
    local port = assert(ports[tag], "missing input port " .. tag)
    local field = assert(port:field(mask), "missing field " .. tag .. ":" .. tostring(mask))
    field:set_value(active and 1 or 0)
    inputs:write(string.format("%d,%s,%d,%d,%s\n",frame,tag,mask,active and 1 or 0,field.name))
end

local last_punch_controls = 0
local function drive_inputs()
    if mode ~= "punch_release" then return end
    if frame == 120 then set_input("IN2",1,true) end
    if frame == 126 then set_input("IN2",1,false) end
    local desired = frame >= 160 and frame < 166 and 0x80 or 0
    if frame >= 260 and frame < 274 then desired = 0x10 end
    for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do
        if (desired & mask) ~= (last_punch_controls & mask) then
            set_input("IN0",mask,(desired & mask) ~= 0)
        end
    end
    last_punch_controls = desired
end

local function dump(name, bytes)
    local file = open(name,"wb");file:write(bytes);file:close()
end

local function snapshot()
    local pixels, width, height = screen:pixels()
    assert(width == 256 and height == 224, "unexpected native visible dimensions")
    assert(#pixels == width*height*4, "unexpected pixel packing")
    local prefix = string.format("frame_%06d",frame)
    dump(prefix .. ".pix32",pixels)
    local palette = screen.palette
    local lookup = {}
    if palette then
        local file = open(prefix .. ".palette.csv")
        file:write("pen,rgb\n")
        for i=0,256 do
            local color = palette:pen_color(i)
            lookup[i] = string.char((color>>16)&255,(color>>8)&255,color&255)
            file:write(string.format("%d,%d\n",i,color))
        end
        file:close()
    end
    local rgb = {}
    for offset=1,#pixels,4 do
        local value = string.unpack("<I4",pixels,offset)
        -- screen_device::pixels converts IND16 through entry_list_adjusted in 0.289.
        local color = string.char((value>>16)&255,(value>>8)&255,value&255)
        rgb[#rgb+1] = color
    end
    dump(prefix .. ".rgb",table.concat(rgb))
    dump(prefix .. ".work.bin",space:read_range(0x020000,0x020fff,8))
    dump(prefix .. ".sprites.bin",space:read_range(0x040000,0x041fff,8))
    screen:snapshot(root .. "/" .. prefix .. ".png")
    states:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d\n",frame,screen:frame_number(),
        pc(main),pc(sound),ports.IN0:read(),ports.IN1:read(),ports.IN2:read(),width,height))
end

local function finish()
    local histogram = open("write_histogram.csv")
    histogram:write("segment,area,scanline,count\n")
    local keys={};for key,_ in pairs(counts) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do histogram:write(key .. "," .. counts[key] .. "\n") end
    histogram:close();events:close();inputs:close();states:close();status:close();frame_states:close()
    local complete=open("complete.txt")
    complete:write(string.format("frames=%d\nmode=%s\nlast_screen_frame=%d\n",frame,mode,screen:frame_number()))
    complete:close()
    machine:exit()
end

-- Retain subscriptions and taps until the machine exits. This is a frame-complete observer.
_G.alpha_capture_handles = handles
local function capture_frame()
    frame_states:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d\n",frame,screen:frame_number(),
        pc(main),pc(sound),main.state["SR"].value,ports.IN0:read(),ports.IN1:read(),ports.IN2:read(),
        space:read_u16(0x060000)&255))
    if sample_frames[frame] or frame%60 == 0 or frame == total-1 then snapshot() end
    drive_inputs()
    if frame % 60 == 0 then
        status:write(string.format("%d,%d\n",frame,screen:frame_number()));status:flush()
        events:flush();inputs:flush();states:flush();frame_states:flush()
    end
    frame=frame+1
    if frame >= total then finish() end
end
_G.alpha_capture_frame_subscription = emu.add_machine_frame_notifier(function()
    if _G.alpha_capture_failed then return end
    local ok, error_message = xpcall(capture_frame, debug.traceback)
    if not ok then
        _G.alpha_capture_failed = true
        local failure = open("failure.txt"); failure:write(error_message); failure:close()
        print("ALPHA_CAPTURE_FAILED", error_message)
        machine:exit()
    end
end)
print("ALPHA_CAPTURE_ATTACHED",mode,total)
