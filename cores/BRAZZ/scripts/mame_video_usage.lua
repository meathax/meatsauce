-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only MAME instrumentation: which VRender0 features does crysking actually use?
-- Run through scripts/mame_video_usage.py (sets CS_USAGE_DIRECTORY / CS_USAGE_FRAMES).
--
-- Method (no MAME patching, no ROM data written):
--  * write taps log every access to the video block (0x0300_0000..0xffff), the CRTC
--    (0x0180_3400..37ff, with frame number) and every render-control (0x8c) write;
--  * the queue-front write tap copies each submitted 64-byte packet (like mame_capture.lua);
--  * every frame_done the packets consumed since the previous frame (rear register
--    delta) are executed through a Lua mirror of vr0video_device::process_packet that
--    only tracks render state and counts (no pixels are drawn);
--  * the draw/display bank model mirrors execute_flipping()/pipeline_cb(): display_bank
--    (0x8e) is sampled every frame, a toggle means one vblank flip happened.
-- Limits (also reported in docs): palette/texture RAM is read at frame end, not at the
-- instant the 1100 Hz-ish MAME timer executed the packet; dest-bank bookkeeping is
-- frame-granular; pixel counts are rectangle areas (upper bound; transparency/clamp
-- rejection is not evaluated per texel).
local out = assert(os.getenv("CS_USAGE_DIRECTORY"), "missing CS_USAGE_DIRECTORY")
local max_frames = tonumber(os.getenv("CS_USAGE_FRAMES")) or 7200
local machine = manager.machine
local cpu = assert(machine.devices[":maincpu"])
local program = assert(cpu.spaces["program"])
local screen
for _, s in pairs(machine.screens) do screen = s; break end

local events = assert(io.open(out .. "/events.csv", "w"))
events:write("frame,kind,detail\n")
local perframe = assert(io.open(out .. "/perframe.csv", "w"))
perframe:write("frame,consumed,draw_quads,fills,textured,pixel_area,sync_flips,async_flips,state_only,front_draw_quads,front_draw_area,display_bank,draw_select,render_control,flip_count_writes,queue_depth\n")
local inputlog = assert(io.open(out .. "/input_events.csv", "w"))
inputlog:write("frame,port,field,value\n")

local frame = 0
local function set_input(tag, name, value)
    local port = assert(machine.ioport.ports[tag], "port " .. tag)
    local field = assert(port.fields[name], "field " .. name)
    field:set_value(value)
    inputlog:write(string.format("%d,%s,%s,%d\n", frame, tag, name, value))
end
-- Deterministic script: attract (0..899), coin+start+select warrior (900..1100),
-- P2 join (1500), then a fixed LCG-driven fight (all directions and buttons).
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
local function inputs(f)
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
    -- periodic extra credits/starts so continues and later screens are reached
    if f >= 2400 and f % 900 == 0 then hold(":SYSTEM","Coin 1",1) elseif f >= 2400 and f % 900 == 8 then hold(":SYSTEM","Coin 1",0) end
    if f >= 2400 and f % 900 == 40 then hold(":SYSTEM","1 Player Start",1) elseif f >= 2400 and f % 900 == 48 then hold(":SYSTEM","1 Player Start",0) end
end

------------------------------------------------------------------ tap logging
local taps = {}
local ring = {}                 -- queue index -> 64-byte packet string
local submitted = 0
local control_writes, flip_writes = 0, 0
local frame_flip_writes = 0
local observing = true
local function s(v) return string.format("%08x", v & 0xffffffff) end
local cur_render_control = 0
local function video_write(address, data, mask)
    if not observing then return end
    data, mask = data & 0xffffffff, mask & 0xffffffff
    local pc = cpu.state["PC"].value
    if address == 0x0300008c and (mask & 0xffff) ~= 0 then
        control_writes = control_writes + 1
        cur_render_control = data & 0xffff
        events:write(string.format("%d,render_control_w,data=%04x mask=%04x dither=%d draw_select=%d reset=%d start=%d pc=%s\n",
            frame, data & 0xffff, mask & 0xffff, data & 3, (data >> 7) & 1, (data >> 3) & 1, (data >> 2) & 1, s(pc)))
    elseif address == 0x03000090 then
        events:write(string.format("%d,bank1_select_w,data=%s mask=%s\n", frame, s(data), s(mask)))
    elseif address == 0x030000a4 and (mask & 0xffff0000) ~= 0 then
        frame_flip_writes = frame_flip_writes + 1; flip_writes = flip_writes + 1
        if flip_writes <= 8 then events:write(string.format("%d,flip_count_w,data=%04x\n", frame, (data >> 16) & 0xffff)) end
    elseif address ~= 0x03000080 and address ~= 0x03000084 then
        events:write(string.format("%d,video_w,addr=%s data=%s mask=%s pc=%s\n", frame, s(address), s(data), s(mask), s(pc)))
    end
    if address == 0x03000080 and (mask & 0xffff) ~= 0 then
        observing = false
        local previous = program:read_u16(0x03000080) & 0x7ff
        local nxt = ((previous & ~(mask & 0xffff)) | (data & mask & 0xffff)) & 0x7ff
        local idx = previous
        while idx ~= nxt do
            ring[idx] = program:read_range(0x03800000 + idx * 64, 0x03800000 + idx * 64 + 63, 8)
            submitted = submitted + 1
            idx = (idx + 1) & 0x7ff
        end
        observing = true
    end
end
taps[#taps + 1] = program:install_write_tap(0x03000000, 0x0300ffff, "vu_video", video_write)
taps[#taps + 1] = program:install_write_tap(0x01803400, 0x018037ff, "vu_crtc", function(address, data, mask)
    if not observing then return end
    events:write(string.format("%d,crtc_w,addr=%s data=%s mask=%s\n", frame, s(address), s(data), s(mask)))
end)

------------------------------------------------------------------ process_packet mirror
local function rgb32to16(c) return (((c >> 19) & 0x1f) << 11) | (((c >> 10) & 0x3f) << 5) | ((c >> 3) & 0x1f) end
local NOTRANS = 0xecda
local rs = {tx=0,ty=0,txdx=512,tydx=0,txdy=0,tydy=512,src_color=0,src_blend=0,dst_color=0,dst_blend=0,
            shade=0,trans=0,tile=0,font=0,pal=0,pbank=0,tmode=0,fmt=0,w=8,h=8}
local last_pal = 0xffffffff
local flip_sync = false
local display_bank = 0
local draw_dest, display_dest = 0, 0       -- 0 = B0, 1 = B1 (logical bank id)
local bank1_4mb = false
local draw_select = false
local combos = {}
local pal_hits_total, pal_loads, pal_hit_events = 0, 0, 0
local pal_dumped = false
local pal_entries_hit = {}                 -- per-load detail
local tot = {packets=0, quads=0, fills=0, tex=0, sync=0, async=0, state_only=0, front_quads=0, pal_collision_loads=0}
local maxf = {quads=0, area=0, packets=0, frame_quads=-1, frame_area=-1}

local function u16(str, w) return string.unpack("<I2", str, w * 2 + 1) end
local function note_combo(key, area)
    local c = combos[key]
    if not c then c = {n=0, area=0, first=frame, max_area=0}; combos[key] = c end
    c.n = c.n + 1; c.area = c.area + area
    if area > c.max_area then c.max_area = area end
end

local fr = {}
local function reset_fr()
    fr = {consumed=0, quads=0, fills=0, tex=0, area=0, sync=0, async=0, state_only=0, front_quads=0, front_area=0}
end
reset_fr()

local function front_bank() -- logical id of the bank that execute_flipping()/pipeline_cb() call "front" for current display_bank
    if display_bank & 1 == 1 then return 1 else return 0 end
end

local function process(pk)
    local p = {}
    local w = function(i) return u16(pk, i) end
    local p0 = w(0)
    local dx, dy, ex, ey = w(1) & 0x3ff, w(2) & 0x1ff, w(3) & 0x3ff, w(4) & 0x1ff
    if (p0 & 0x81) ~= 0 then
        last_pal = 0xffffffff
        if (p0 & 1) ~= 0 then fr.sync = fr.sync + 1; tot.sync = tot.sync + 1; flip_sync = true end
        if (p0 & 0x80) ~= 0 then
            fr.async = fr.async + 1; tot.async = tot.async + 1
            local front = front_bank(); local back = 1 - front
            draw_dest = draw_select and back or front
            events:write(string.format("%d,async_flip_packet,p0=%04x draw_select=%d draw_dest_bank=%d display_dest=%d\n", frame, p0, draw_select and 1 or 0, draw_dest, display_dest))
        end
        return
    end
    if (p0 & 0x200) ~= 0 then rs.tx = w(5) | ((w(6) & 0x1f) << 16); rs.ty = w(7) | ((w(8) & 0x1f) << 16) else rs.tx = 0; rs.ty = 0 end
    local roz = false
    if (p0 & 0x400) ~= 0 then
        rs.txdx = w(9) | ((w(10) & 0x1f) << 16); rs.tydx = w(11) | ((w(12) & 0x1f) << 16)
        rs.txdy = w(13) | ((w(14) & 0x1f) << 16); rs.tydy = w(15) | ((w(16) & 0x1f) << 16)
    else rs.txdx = 512; rs.tydx = 0; rs.txdy = 0; rs.tydy = 512 end
    if rs.txdx ~= 512 or rs.tydx ~= 0 or rs.txdy ~= 0 or rs.tydy ~= 512 then roz = true end
    if (p0 & 0x800) ~= 0 then
        rs.src_color = w(17) | ((w(18) & 0xff) << 16); rs.src_blend = (w(18) >> 8) & 0x3f
        rs.dst_color = w(19) | ((w(20) & 0xff) << 16); rs.dst_blend = (w(20) >> 8) & 0x3f
    end
    if (p0 & 0x1000) ~= 0 then rs.shade = w(21) | ((w(22) & 0xff) << 16) end
    if (p0 & 0x2000) ~= 0 then rs.trans = w(23) | ((w(24) & 0xff) << 16) end
    if (p0 & 0x4000) ~= 0 then
        rs.tile = w(25); rs.font = w(26); rs.pal = w(27) >> 3
        rs.pbank = (w(28) >> 8) & 0xf; rs.tmode = (w(28) >> 12) & 1; rs.fmt = (w(28) >> 6) & 3
        rs.w = 8 << (w(28) & 7); rs.h = 8 << ((w(28) >> 3) & 7)
    end
    if (p0 & 0x40) ~= 0 and rs.pal ~= last_pal then
        pal_loads = pal_loads + 1
        local base = 0x03800000 + 1024 * rs.pal
        local raw = program:read_range(base, base + 1023, 8)
        local trans16 = rgb32to16(rs.trans)
        local hits = 0
        local detail = {}
        for i = 0, 255 do
            local c = string.unpack("<I4", raw, i * 4 + 1)
            local v = rgb32to16(c)
            if (v == trans16 and c ~= rs.trans) or v == NOTRANS then
                hits = hits + 1
                detail[#detail + 1] = string.format("%d:%08x%s", i, c, (v == NOTRANS) and "(notrans)" or "")
            end
        end
        if hits > 0 and not pal_dumped then
            -- private fixture for sim/video/gpu_hw.cpp (real crysking palette with collisions)
            pal_dumped = true
            local f = assert(io.open(out .. "/collision_palette.bin", "wb")); f:write(raw); f:close()
            local m = assert(io.open(out .. "/collision_palette.txt", "w"))
            m:write(string.format("frame=%d pal_offset=%d trans_color=%06x\n", frame, rs.pal, rs.trans)); m:close()
        end
        if hits > 0 then
            pal_hits_total = pal_hits_total + hits; tot.pal_collision_loads = tot.pal_collision_loads + 1
            events:write(string.format("%d,palette_collision,pal_offset=%d trans=%06x hits=%d entries=%s\n", frame, rs.pal, rs.trans, hits, table.concat(detail, " ")))
        end
        last_pal = rs.pal
    end
    if (p0 & 0x100) ~= 0 then
        local area = 0
        if ex >= dx and ey >= dy then area = (ex - dx + 1) * (ey - dy + 1) end
        local alpha = (p0 & 2) ~= 0
        local shade = (p0 & 0x10) ~= 0
        local tex = (p0 & 8) ~= 0
        local front = (draw_dest == display_dest)
        local key
        if tex then
            key = string.format("tex fmt=%d %s blend=%s%s trans=%d clamp=%d roz=%d origin=%d",
                rs.fmt, rs.tmode == 1 and "tiled" or "linear",
                alpha and "A" or "-", shade and "S" or "-", (p0 >> 2) & 1, (p0 >> 5) & 1, roz and 1 or 0, (p0 >> 9) & 1)
            fr.tex = fr.tex + 1; tot.tex = tot.tex + 1
        else
            key = string.format("fill alpha=%s(src_blend=%02x)", alpha and "A" or "-", alpha and rs.src_blend or 0)
            fr.fills = fr.fills + 1; tot.fills = tot.fills + 1
        end
        note_combo(key, area)
        if alpha then note_combo(string.format("alpha src_mode=%02x dst_mode=%02x%s", rs.src_blend, rs.dst_blend, tex and "" or " (fill)"), area) end
        if shade then note_combo(string.format("shade color=%06x%s", rs.shade, tex and "" or " (fill)"), area) end
        if tex then note_combo(string.format("texdim %dx%d %s", rs.w, rs.h, rs.tmode == 1 and "tiled" or "linear"), area) end
        fr.quads = fr.quads + 1; tot.quads = tot.quads + 1; fr.area = fr.area + area
        if front then
            fr.front_quads = fr.front_quads + 1; fr.front_area = fr.front_area + area; tot.front_quads = tot.front_quads + 1
            if tot.front_quads <= 20 then events:write(string.format("%d,quad_into_displayed_buffer,p0=%04x area=%d draw_dest=%d display_dest=%d\n", frame, p0, area, draw_dest, display_dest)) end
        end
    else
        fr.state_only = fr.state_only + 1; tot.state_only = tot.state_only + 1
    end
end

local rear_prev = 0
local last_display_bank = nil
emu.register_frame_done(function()
    assert(#taps == 2, "tap ownership lost")
    frame = frame + 1
    inputs(frame)
    observing = false
    local rear = program:read_u16(0x03000082) & 0x7ff
    local front = program:read_u16(0x03000080) & 0x7ff
    local bank = program:read_u16(0x0300008e) & 0xffff
    local rc = program:read_u16(0x0300008c) & 0xffff
    draw_select = (rc & 0x80) ~= 0
    bank1_4mb = (program:read_u16(0x03000090) & 0x8000) ~= 0
    -- display bank toggled -> one flip executed at vblank (after this frame's packets)
    local idx = rear_prev
    -- rear may also have been reset (control reset writes zero both); handle by detecting rear < prev with front small
    while idx ~= rear do
        local pk = ring[idx]
        if pk then process(pk); fr.consumed = fr.consumed + 1; tot.packets = tot.packets + 1
        else events:write(string.format("%d,missing_packet,index=%d\n", frame, idx)) end
        idx = (idx + 1) & 0x7ff
    end
    rear_prev = rear
    if last_display_bank ~= nil and bank ~= last_display_bank then
        display_bank = bank
        -- execute_flipping(): front computed from the bank value *before* its toggle
        local pre = bank ~ 1
        local fnt = (pre & 1 == 1) and 1 or 0
        local back = 1 - fnt
        draw_dest = draw_select and fnt or back
        display_dest = fnt
        flip_sync = false
    else
        display_bank = bank
    end
    last_display_bank = bank
    if fr.quads > maxf.quads then maxf.quads = fr.quads; maxf.frame_quads = frame end
    if fr.area > maxf.area then maxf.area = fr.area; maxf.frame_area = frame end
    if fr.consumed > maxf.packets then maxf.packets = fr.consumed end
    perframe:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%04x,%d,%d\n", frame, fr.consumed, fr.quads, fr.fills, fr.tex, fr.area,
        fr.sync, fr.async, fr.state_only, fr.front_quads, fr.front_area, bank, draw_select and 1 or 0, rc, frame_flip_writes, (front - rear) & 0x7ff))
    frame_flip_writes = 0
    reset_fr()
    observing = true
    if frame % 600 == 0 then screen:snapshot(out .. string.format("/frame_%06d.png", frame)) end
    if frame >= max_frames then
        events:close(); perframe:close(); inputlog:close()
        local cf = assert(io.open(out .. "/combos.csv", "w"))
        cf:write("combo,count,first_frame,pixel_area_sum,max_quad_area\n")
        local keys = {}
        for k in pairs(combos) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do local c = combos[k]; cf:write(string.format("\"%s\",%d,%d,%d,%d\n", k, c.n, c.first, c.area, c.max_area)) end
        cf:close()
        local sm = assert(io.open(out .. "/summary.json", "w"))
        sm:write(string.format('{"frames":%d,"submitted":%d,"consumed":%d,"quads":%d,"fills":%d,"textured":%d,"sync_flips":%d,"async_flips":%d,"state_only":%d,"front_quads":%d,"palette_loads":%d,"palette_collision_loads":%d,"palette_collision_entries":%d,"render_control_writes":%d,"flip_count_writes":%d,"max_quads_frame":%d,"max_quads":%d,"max_area_frame":%d,"max_area":%d,"max_packets_frame":%d}\n',
            frame, submitted, tot.packets, tot.quads, tot.fills, tot.tex, tot.sync, tot.async, tot.state_only, tot.front_quads, pal_loads, tot.pal_collision_loads, pal_hits_total, control_writes, flip_writes, maxf.frame_quads, maxf.quads, maxf.frame_area, maxf.area, maxf.packets))
        sm:close()
        machine:exit()
    end
end)
print("mame_video_usage installed")
