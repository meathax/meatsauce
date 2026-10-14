-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only MAME capture of whole real game frames for the GPU-through-fabric bench.
-- Run through scripts/mame_gpu_frames.py (CS_FRAMES_DIRECTORY, CS_FRAMES_WINDOWS="start-end,...").
-- Same deterministic input script as scripts/mame_video_usage.lua, so frame numbers match
-- docs/gpu_packet_usage.json / perframe.csv. For each window: at the frame_done that starts
-- frame <start>, texture RAM (0x03800000..0x03ffffff), frame RAM (0x04000000..0x047fffff)
-- and the GPU queue/bank registers are saved; then every CPU/DMA write to texture/frame
-- RAM, every GPU register write and every frame_done ("V") is logged in order until the
-- frame_done that ends frame <end>. Registers are read without side effects (flip count is
-- tracked from its writes and the display-bank toggles instead of reading 0xa6).
local out = assert(os.getenv("CS_FRAMES_DIRECTORY"), "missing CS_FRAMES_DIRECTORY")
local windows = {}
local last_end = 0
for a, b in string.gmatch(os.getenv("CS_FRAMES_WINDOWS") or "", "(%d+)-(%d+)") do
    windows[#windows + 1] = {tonumber(a), tonumber(b)}
    if tonumber(b) > last_end then last_end = tonumber(b) end
end
assert(#windows > 0, "no capture windows")
local machine = manager.machine
local cpu = assert(machine.devices[":maincpu"])
local program = assert(cpu.spaces["program"])

local frame = 0
local function set_input(tag, name, value)
    local port = assert(machine.ioport.ports[tag], "port " .. tag)
    local field = assert(port.fields[name], "field " .. name)
    field:set_value(value)
end
-- Identical to mame_video_usage.lua (deterministic attract/coin/fight script).
local seed = 0x1234567
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
local held = {}
local function hold(tag, name, down)
    local key = tag .. name
    if (held[key] or 0) ~= down then held[key] = down; set_input(tag, name, down) end
end
local fixed = {
    [900]={":SYSTEM","Coin 1",1}, [908]={":SYSTEM","Coin 1",0},
    [940]={":SYSTEM","1 Player Start",1}, [948]={":SYSTEM","1 Player Start",0},
    [980]={":P1_P2","P1 Button 1",1}, [988]={":P1_P2","P1 Button 1",0},
    [1040]={":P1_P2","P1 Button 1",1}, [1048]={":P1_P2","P1 Button 1",0},
    [1500]={":SYSTEM","Coin 1",1}, [1508]={":SYSTEM","Coin 1",0},
    [1540]={":SYSTEM","2 Players Start",1}, [1548]={":SYSTEM","2 Players Start",0},
    [1600]={":P1_P2","P2 Button 1",1}, [1608]={":P1_P2","P2 Button 1",0},
    [1660]={":P1_P2","P2 Button 1",1}, [1668]={":P1_P2","P2 Button 1",0},
}
local moves = {"Left","Right","Up","Down"}
-- CS_FRAMES_GAME=topbladv: coin 1500, 1P start 1700, P1 button 1 pulsed from 2400 (gameplay from ~3000),
-- the same script as build/mame_scan/topbladv-btn. Fields are looked up by name in any port.
local game = os.getenv("CS_FRAMES_GAME") or "crysking"
local function named(name)
    for _, port in pairs(machine.ioport.ports) do
        for _, field in pairs(port.fields) do if field.name:lower() == name then return field end end
    end
    error("input " .. name)
end
local tbv = game == "topbladv" and {coin = named("coin 1"), start = named("1 player start"), b1 = named("p1 button 1")}
local function inputs(f)
    if tbv then
        tbv.coin:set_value((f >= 1500 and f < 1514) and 1 or 0)
        tbv.start:set_value((f >= 1700 and f < 1714) and 1 or 0)
        tbv.b1:set_value((f >= 2400 and (f // 8) % 2 == 0) and 1 or 0)
        return
    end
    local a = fixed[f]
    if a then hold(a[1], a[2], a[3]) end
    if f >= 1200 and f % 15 == 0 then
        for _, who in ipairs({"P1","P2"}) do
            if who == "P1" or f >= 1800 then
                for _, m in ipairs(moves) do hold(":P1_P2", who .. " " .. m, 0) end
                hold(":P1_P2", who .. " " .. moves[1 + rnd(4)], 1)
                for b = 1, 4 do hold(":P1_P2", who .. " Button " .. b, (rnd(3) == 0) and 1 or 0) end
            end
        end
    end
    if f >= 2400 and f % 900 == 0 then hold(":SYSTEM","Coin 1",1) elseif f >= 2400 and f % 900 == 8 then hold(":SYSTEM","Coin 1",0) end
    if f >= 2400 and f % 900 == 40 then hold(":SYSTEM","1 Player Start",1) elseif f >= 2400 and f % 900 == 48 then hold(":SYSTEM","1 Player Start",0) end
end

local active, events = nil, nil
local flip_count, last_bank = 0, nil
local function save(name, first, last)
    local data = program:read_range(first, last, 8)
    assert(#data == last - first + 1, "memory capture length mismatch")
    local f = assert(io.open(name, "wb")); f:write(data); f:close()
end
local function log_write(kind, address, data, mask)
    if events then events:write(string.format("%s %08x %08x %08x\n", kind, address, data & 0xffffffff, mask & 0xffffffff)) end
end
local taps = {}
taps[#taps + 1] = program:install_write_tap(0x03000000, 0x0300ffff, "gf_video", function(address, data, mask)
    if address == 0x030000a4 and ((mask >> 16) & 0xff) ~= 0 then
        local fc = (data >> 16) & 0xff
        if fc == 1 then flip_count = flip_count + 1 elseif fc == 0 then flip_count = 0 end
    end
    log_write("R", address, data, mask)
end)
taps[#taps + 1] = program:install_write_tap(0x03800000, 0x03ffffff, "gf_texture", function(address, data, mask)
    log_write("W", address, data, mask)
end)
taps[#taps + 1] = program:install_write_tap(0x04000000, 0x047fffff, "gf_frame", function(address, data, mask)
    log_write("W", address, data, mask)
end)

emu.register_frame_done(function()
    frame = frame + 1
    inputs(frame)
    local bank = program:read_u16(0x0300008e) & 0xffff
    if last_bank ~= nil and bank ~= last_bank and flip_count > 0 then flip_count = flip_count - 1 end
    last_bank = bank
    if events then
        events:write("V\n")
        if frame > active[2] then events:close(); events = nil; active = nil end
    end
    if not events then
        for _, w in ipairs(windows) do
            if frame == w[1] then
                local dir = string.format("%s/w%05d", out, w[1])
                os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
                save(dir .. "/texture.bin", 0x03800000, 0x03ffffff)
                save(dir .. "/frame.bin", 0x04000000, 0x047fffff)
                local st = assert(io.open(dir .. "/state.txt", "w"))
                st:write(string.format("%d %d %d %d %d %d %d %d\n", w[1], w[2],
                    program:read_u16(0x03000082) & 0x7ff, program:read_u16(0x03000080) & 0x7ff,
                    program:read_u16(0x0300008c) & 0xffff, bank, program:read_u16(0x03000090) & 0xffff, flip_count))
                st:close()
                events = assert(io.open(dir .. "/events.txt", "w"))
                active = w
            end
        end
    end
    if frame > last_end + 1 and not events then
        for _, t in ipairs(taps) do t:remove() end
        machine:exit()
    end
end)
print("mame_gpu_frames installed")
