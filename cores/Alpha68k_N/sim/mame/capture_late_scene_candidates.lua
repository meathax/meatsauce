-- Isolated scene discovery ONLY. Explicit RAM cheats; not gameplay acceptance.
local machine = manager.machine
local screen = assert(machine.screens[":screen"])
local cpu = assert(machine.devices[":maincpu"])
local space = cpu.spaces.program
local root = assert(os.getenv("ALPHA_CAPTURE_DIR"))
local total = tonumber(os.getenv("ALPHA_CAPTURE_FRAMES") or "36000")
local route = os.getenv("ALPHA_FIXTURE_ROUTE") or "raw-up"
assert(route == "raw-up" or route == "raw-left" or route == "centered-up" or route == "centered-right" or route == "stairs-zigzag" or route == "corridor", "unknown fixture route")
local scene = os.getenv("ALPHA_FIXTURE_SCENE") or "natural"
assert(scene == "natural" or scene == "candidate-5" or scene == "candidate-5-last-room", "unknown fixture scene")
local scene_initialized = false
local late_room_initialized = false
local ending_requested = os.getenv("ALPHA_FIXTURE_ENDING") == "1"
local ending_initialized = false
local scene_entry = tonumber(os.getenv("ALPHA_FIXTURE_SCENE_ENTRY") or "6758")
local room_entry = tonumber(os.getenv("ALPHA_FIXTURE_ROOM_ENTRY") or "7056")
local return_pc = tonumber(os.getenv("ALPHA_FIXTURE_RETURN_PC") or "40414")
local wait_lo = tonumber(os.getenv("ALPHA_FIXTURE_WAIT_LO") or "40442")
local wait_hi = tonumber(os.getenv("ALPHA_FIXTURE_WAIT_HI") or "40606")
local scene5_table = tonumber(os.getenv("ALPHA_FIXTURE_ROOM_TABLE") or "7498")
local resume_inputs = os.getenv("ALPHA_FIXTURE_RESUME_INPUTS") == "1"
local frame = 0
local ports = {}
for _, tag in ipairs({"IN0", "IN2"}) do
    ports[tag] = assert(machine.ioport.ports[":" .. tag] or machine.ioport.ports[tag])
end
local function open(name) return assert(io.open(root .. "/" .. name, "wb")) end
local function dump(name, data)
    local f = open(name); f:write(data); f:close()
end
local states = open("frame_states.csv")
states:write("frame,screen_frame,main_pc,background,energy,lives,power,scroll_candidate\n")
local samples = open("states.csv")
samples:write("frame,screen_frame,background,flip\n")
local status = open("status.csv")
status:write("frame,screen_frame\n")
local cheats = open("fixture_writes.csv")
cheats:write("frame,address,before,after\n")
local contexts = open("cpu_context.csv")
contexts:write("frame,pc,sr,a6,sp,selector,loop\n")
local function prepare_scene()
    if scene == "natural" or scene_initialized or frame < 900 then return end
    local pc = cpu.state.PC.value
    local sr = cpu.state.SR.value
    local a6 = cpu.state.A6.value
    local sp = cpu.state.SP.value
    -- Only restart the source-derived scene entry in its existing normal
    -- call context. Never reuse an interrupt frame as an RTS return.
    if pc < wait_lo or pc > wait_hi or a6 ~= 0x20000 or sp ~= 0x20ff4 or
       (sr & 0x2700) ~= 0x2000 or space:read_u32(sp) ~= return_pc then return end
    assert(space:read_u16(scene_entry) == 0x026e, "unexpected scene-entry ROM")
    local before = space:read_u8(0x20101)
    cheats:write(string.format("%d,%d,%d,%d\n", frame, 0x20101, before, 5))
    space:write_u8(0x20101, 5)
    cpu.state.PC.value = scene_entry
    scene_initialized = true
    dump("fixture_setup.json", string.format(
        '{"frame":%d,"pc_before":%d,"sr":%d,"a6":%d,"sp":%d,"return_address":%d,"selector_before":%d,"selector_after":5,"entry_pc":%d,"fixture_only":true}\n',
        frame,pc,sr,a6,sp,space:read_u32(sp),before,scene_entry))
end
local function prepare_late_room()
    if scene ~= "candidate-5-last-room" or not scene_initialized or
       late_room_initialized or frame < 1200 then return end
    local pc, sr = cpu.state.PC.value, cpu.state.SR.value
    local a6, sp = cpu.state.A6.value, cpu.state.SP.value
    if pc < wait_lo or pc > wait_hi or a6 ~= 0x20000 or sp ~= 0x20ff4 or
       (sr & 0x2700) ~= 0x2000 or space:read_u32(sp) ~= return_pc then return end
    assert(space:read_u8(0x20101) == 5, "unexpected scene selector")
    assert(space:read_u16(room_entry) == 0x102e, "unexpected room-entry ROM")
    local index = space:read_u8(0x2090d) == 0 and 8 or 9
    local descriptor = scene5_table + index*8
    assert(space:read_u32(descriptor) == 0x090060b0 and
           space:read_u32(descriptor+4) == 0x68f00000, "unexpected late-room descriptor")
    local before = space:read_u16(0x20110)
    cheats:write(string.format("%d,%d,%d,%d\n", frame, 0x20110, before >> 8, 9))
    cheats:write(string.format("%d,%d,%d,%d\n", frame, 0x20111, before & 255, 0))
    space:write_u16(0x20110, 0x0900)
    cpu.state.PC.value = room_entry
    late_room_initialized = true
    dump("late_room_setup.json", string.format(
        '{"frame":%d,"pc_before":%d,"sr":%d,"a6":%d,"sp":%d,"return_address":%d,"room_before":%d,"room_requested":2304,"entry_pc":%d,"descriptor_index":%d,"descriptor_address":%d,"fixture_only":true}\n',
        frame,pc,sr,a6,sp,space:read_u32(sp),before,room_entry,index,descriptor))
end
local function prepare_ending()
    if not ending_requested or not late_room_initialized or ending_initialized or frame < 1800 then return end
    local pc, sr = cpu.state.PC.value, cpu.state.SR.value
    local a6, sp = cpu.state.A6.value, cpu.state.SP.value
    if pc < wait_lo or pc > wait_hi or a6 ~= 0x20000 or sp ~= 0x20ff4 or
       (sr & 0x2700) ~= 0x2000 or space:read_u32(sp) ~= return_pc then return end
    assert(space:read_u8(0x20101) == 5 and space:read_u16(0x20110) == 0x0900,
           "ending fixture requires source-derived final room")
    assert(space:read_u32(0x1e076) == 0x1e81a and
           space:read_u32(0x1e834) == 0x1eca8 and
           space:read_u32(0x1edae) == 0x49ee0420, "unexpected ending dispatch ROM")
    -- Let the real normal-loop JSR dispatch the ending. Do not redirect PC.
    for _, entry in ipairs({{0x20d10,5},{0x20d11,2},{0x20d12,2}}) do
        cheats:write(string.format("%d,%d,%d,%d\n", frame, entry[1], space:read_u8(entry[1]), entry[2]))
        space:write_u8(entry[1], entry[2])
    end
    ending_initialized = true
    dump("ending_setup.json", string.format(
        '{"frame":%d,"pc_before":%d,"sr":%d,"a6":%d,"sp":%d,"return_address":%d,"pc_redirected":false,"fixture_only":true}\n',
        frame,pc,sr,a6,sp,space:read_u32(sp)))
end
local function set_input(tag, mask, active)
    assert(ports[tag]:field(mask)):set_value(active and 1 or 0)
end
local controls = 0
local function drive()
    if frame == 120 then set_input("IN2", 1, true) end
    if frame == 126 then set_input("IN2", 1, false) end
    local desired = frame >= 160 and frame < 166 and 0x80 or 0
    if frame >= 260 then
        desired = route == "raw-left" and 8 or (route == "centered-right" and 4 or 1)
        if route == "stairs-zigzag" then
            desired = math.floor((frame - 260) / 16) % 2 == 0 and 1 or 2
        elseif route == "corridor" then
            desired = 8
        end
        local phase = (frame - 260) % 1200
        if route == "raw-left" then
            if phase >= 720 and phase < 900 then desired = desired | 1 end
            if phase >= 1020 then desired = desired | 2 end
        elseif route == "raw-up" then
            if phase >= 720 and phase < 900 then desired = desired | 4 end
            if phase >= 1020 then desired = desired | 8 end
        end
        if (frame - 260) % 18 < 14 then desired = desired | 0x10 end
        if route ~= "corridor" and (frame - 260) % 90 < 4 then desired = desired | 0x20 end
        -- Historical Pugsy XML candidates, separately pinned in research.
        -- Record every changed byte; these writes are fixture preparation.
        for _, entry in ipairs({{0x20105, 0x50}, {0x2010f, 0x40},
                                {0x20104, 0x20}, {0x20419, 5}}) do
            local old = space:read_u8(entry[1])
            if old ~= entry[2] then
                cheats:write(string.format("%d,%d,%d,%d\n", frame, entry[1], old, entry[2]))
                space:write_u8(entry[1], entry[2])
            end
        end
    end
    if scene_initialized and not resume_inputs then desired = 0 end
    for _, mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do
        if ((desired ~ controls) & mask) ~= 0 then
            set_input("IN0", mask, (desired & mask) ~= 0)
        end
    end
    controls = desired
end
local function observe()
    local bg = space:read_u16(0x60000) & 255
    states:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d\n", frame,
        screen:frame_number(), cpu.state.PC.value, bg, space:read_u8(0x20105),
        space:read_u8(0x20103), space:read_u8(0x20400), space:read_u16(0x20200)))
    if frame % 300 == 0 or frame == 179 or frame == total-1 then
        local prefix = string.format("frame_%06d", frame)
        dump(prefix .. ".work.bin", space:read_range(0x20000, 0x20fff, 8))
        dump(prefix .. ".sprites.bin", space:read_range(0x40000, 0x41fff, 8))
        screen:snapshot(root .. "/" .. prefix .. ".png")
        samples:write(string.format("%d,%d,%d,0\n", frame, screen:frame_number(), bg))
        contexts:write(string.format("%d,%d,%d,%d,%d,%d,%d\n", frame,
            cpu.state.PC.value,cpu.state.SR.value,cpu.state.A6.value,cpu.state.SP.value,
            space:read_u8(0x20101),space:read_u8(0x20100)))
        contexts:flush()
        samples:flush()
    end
    prepare_scene()
    prepare_late_room()
    prepare_ending()
    drive()
    if frame % 600 == 0 then
        status:write(string.format("%d,%d\n", frame, screen:frame_number()))
        status:flush(); states:flush(); cheats:flush()
    end
    frame = frame + 1
    if frame >= total then
        states:close(); samples:close(); status:close(); cheats:close(); contexts:close()
        dump("complete.txt", string.format("frames=%d\nfixture_cheats=true\n", frame))
        machine:exit()
    end
end
_G.alpha_late_scene_subscription = emu.add_machine_frame_notifier(function()
    if _G.alpha_late_scene_failed then return end
    local ok, err = xpcall(observe, debug.traceback)
    if not ok then
        _G.alpha_late_scene_failed = true
        dump("failure.txt", err); print("ALPHA_LATE_SCENE_FAILED", err); machine:exit()
    end
end)
print("ALPHA_LATE_SCENE_ATTACHED", total, route, scene, "explicit fixture RAM/register writes")
