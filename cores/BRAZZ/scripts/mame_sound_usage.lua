-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only MAME instrumentation of the VRender0 sound register window
-- (CPU 0x04800000-0x04800fff, SoC 0x01800000 sound_map).  Logs every global
-- register access, every channel mode-word write, a full channel snapshot at
-- each status-on, and per-frame which channels actually advance.  No ROM or
-- sample data is stored.  Environment:
--   SU_DIR      output directory (required)
--   SU_FRAMES   frames to run (default 6000)
--   SU_SNAP     snapshot PNG every N frames (0 = none)
--   SU_INPUTS   "none" or a path to a text file: "frame port field value" lines
local out = assert(os.getenv("SU_DIR"), "missing SU_DIR")
local max_frames = tonumber(os.getenv("SU_FRAMES")) or 6000
local snap_every = tonumber(os.getenv("SU_SNAP")) or 0
local inputs_path = os.getenv("SU_INPUTS") or "none"
local machine = manager.machine
local cpu = assert(machine.devices[":maincpu"], "main CPU not found")
local program = assert(cpu.spaces["program"])
local screen
for _, s in pairs(machine.screens) do screen = s; break end
local BASE = 0x04800000

local actions = {}
if inputs_path ~= "none" then
    for line in io.lines(inputs_path) do
        local f, tag, name, v = line:match("^(%d+)%s+(%S+)%s+(.-)%s+(%d)%s*$")
        if f then
            f = tonumber(f)
            actions[f] = actions[f] or {}
            table.insert(actions[f], {tag, name, tonumber(v)})
        end
    end
end
local function set_input(tag, name, value)
    local port = assert(machine.ioport.ports[tag], "port " .. tag)
    local field = assert(port.fields[name], "field " .. name)
    field:set_value(value)
end

local events = assert(io.open(out .. "/sound_events.csv", "w"))
events:write("frame,pc,op,offset,value,mask\n")
local notes = assert(io.open(out .. "/note_on.csv", "w"))
notes:write("frame,pc,channel,mode,ds_addr,cur_saddr,loop_begin,loop_end,lvol,rvol,env_vol,env_stage,rate0,rate1,rate2,rate3,tgt0,tgt1,tgt2,tgt3\n")
local active_log = assert(io.open(out .. "/active_channels.csv", "w"))
active_log:write("frame,mask,modes\n")
local frames_log = assert(io.open(out .. "/frames.csv", "w"))
frames_log:write("frame,pc,ctrl,chnnum,revfactor,bufsaddr,bsz0,bsz1,bsz2,bsz3,intmask_lo,intmask_hi,intpend_lo,intpend_hi\n")

local frame, observing, finished = 0, true, false
local counts = {}       -- "op offset" -> count
local mode_writes = {}  -- mode byte -> count of mode-word writes
local mode_on = {}      -- mode byte -> status-on count
local mode_played = {}  -- mode byte -> frames*channels advancing
local first_seen = {}   -- key -> first frame
local channel_first_play = {}
local note_count = 0
local status_off_count = 0
local last_global = {}
local function bump(t, k, n) t[k] = (t[k] or 0) + (n or 1) end
local function first(key) if not first_seen[key] then first_seen[key] = frame end end
local function state(name) local i = cpu.state[name]; return i and i.value or 0 end

local function u16(off) return program:read_u16(BASE + off) end
local function rd(c, w) return u16(c * 32 + w * 2) end

local function snapshot_channel(c, pc)
    observing = false
    local m = (rd(c, 5) >> 8) & 0x7f
    local lb = rd(c, 6) | ((rd(c, 7) & 0x3f) << 16)
    local le = rd(c, 8) | ((rd(c, 9) & 0x3f) << 16)
    local line = string.format("%d,%08x,%d,%02x,%04x,%08x,%06x,%06x,%d,%d,%06x,%x,%04x,%04x,%04x,%04x,%d,%d,%d,%d\n",
        frame, pc, c, m, rd(c, 4), rd(c, 0) | (rd(c, 1) << 16), lb, le,
        (rd(c, 7) >> 8) & 0x7f, (rd(c, 9) >> 8) & 0x7f,
        ((rd(c, 3) & 0xff) << 16) | rd(c, 2), (rd(c, 3) >> 8) & 0xf,
        rd(c, 10), rd(c, 11), rd(c, 12), rd(c, 13),
        rd(c, 14) & 0x7f, (rd(c, 14) >> 8) & 0x7f, rd(c, 15) & 0x7f, (rd(c, 15) >> 8) & 0x7f)
    notes:write(line)
    bump(mode_on, m)
    first("mode_on_" .. string.format("%02x", m))
    observing = true
    return m
end

local function name_of(off)
    if off < 0x400 then return string.format("chan%02d.%02x", off // 32, off % 32) end
    return string.format("%03x", off)
end

local function handle(op, address, data, mask)
    local aligned = address & ~3
    for half = 0, 1 do
        local hm = (mask >> (half * 16)) & 0xffff
        if hm ~= 0 then
            local off = (aligned - BASE) + half * 2
            local value = (data >> (half * 16)) & 0xffff
            local pc = state("PC")
            if off < 0x400 then
                local w = (off % 32)
                bump(counts, op .. " chan." .. string.format("%02x", w))
                if op == "W" and w == 0x0a then
                    local m = (value >> 8) & 0x7f
                    bump(mode_writes, m)
                    first("mode_write_" .. string.format("%02x", m))
                    events:write(string.format("%d,%08x,W,%03x,%04x,%04x\n", frame, pc, off, value, hm))
                end
            else
                local key = op .. " " .. string.format("%03x", off)
                bump(counts, key)
                first(key)
                if (counts[key] or 0) <= 4000 then
                    events:write(string.format("%d,%08x,%s,%03x,%04x,%04x\n", frame, pc, op, off, value, hm))
                end
                if op == "W" and (off == 0x404 or off == 0x406) then
                    local c = value & 0x1f
                    if (value & 0x8000) ~= 0 then
                        note_count = note_count + 1
                        snapshot_channel(c, pc)
                    else
                        status_off_count = status_off_count + 1
                    end
                end
            end
        end
    end
end

local taps = {}
taps[1] = program:install_write_tap(BASE, BASE + 0xfff, "su_w", function(address, data, mask)
    if finished or not observing then return end
    handle("W", address, data & 0xffffffff, mask & 0xffffffff)
end)
taps[2] = program:install_read_tap(BASE, BASE + 0xfff, "su_r", function(address, data, mask)
    if finished or not observing then return end
    if (address - BASE) < 0x400 then return end -- ignore channel readbacks
    handle("R", address, data & 0xffffffff, mask & 0xffffffff)
end)

local prev_addr = {}
local function frame_sample()
    observing = false
    local active, modestr = 0, {}
    for c = 0, 31 do
        local a = rd(c, 0) | (rd(c, 1) << 16)
        if prev_addr[c] ~= nil and prev_addr[c] ~= a then
            active = active | (1 << c)
            local m = (rd(c, 5) >> 8) & 0x7f
            modestr[#modestr + 1] = string.format("%d:%02x", c, m)
            bump(mode_played, m)
            if not channel_first_play[c] then channel_first_play[c] = frame end
        end
        prev_addr[c] = a
    end
    if active ~= 0 then
        active_log:write(string.format("%d,%08x,%s\n", frame, active, table.concat(modestr, " ")))
        bump(counts, "frames_with_active_channels")
    end
    local g = { u16(0x602), u16(0x600), u16(0x410), u16(0x412), u16(0x420), u16(0x422), u16(0x440), u16(0x442),
                u16(0x480), u16(0x482), u16(0x500), u16(0x502) }
    local key = table.concat(g, ",")
    if key ~= last_global.key then
        frames_log:write(string.format("%d,%08x,%s\n", frame, state("PC"), string.format("%04x,%04x,%04x,%04x,%04x,%04x,%04x,%04x,%04x,%04x,%04x,%04x", table.unpack(g))))
        last_global.key = key
    end
    observing = true
end

local function dump_summary()
    local f = assert(io.open(out .. "/summary.txt", "w"))
    f:write("frames=" .. frame .. "\nnote_on_events=" .. note_count .. "\nstatus_off_events=" .. status_off_count .. "\n")
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(string.format("count %-24s %d (first frame %s)\n", k, counts[k], tostring(first_seen[k] or "-"))) end
    local function dump(t, label, seen)
        local ks = {}
        for k in pairs(t) do ks[#ks + 1] = k end
        table.sort(ks)
        for _, k in ipairs(ks) do f:write(string.format("%s mode=%02x count=%d first_frame=%s\n", label, k, t[k], tostring(first_seen[seen .. string.format("%02x", k)] or "-"))) end
    end
    dump(mode_writes, "mode_write", "mode_write_")
    dump(mode_on, "mode_status_on", "mode_on_")
    dump(mode_played, "mode_advancing_channel_frames", "none_")
    for c = 0, 31 do if channel_first_play[c] then f:write(string.format("channel %d first advancing frame %d\n", c, channel_first_play[c])) end end
    f:close()
end

emu.register_frame_done(function()
    assert(#taps == 2, "tap ownership lost")
    if finished then return end
    frame = frame + 1
    local act = actions[frame]
    if act then for _, a in ipairs(act) do set_input(a[1], a[2], a[3]) end end
    frame_sample()
    if snap_every > 0 and frame % snap_every == 0 then
        screen:snapshot(string.format("%s/snap_%06d.png", out, frame))
    end
    if frame >= max_frames then
        finished = true
        events:close(); notes:close(); active_log:close(); frames_log:close()
        dump_summary()
        machine:exit()
    end
end)
print("mame_sound_usage installed")
