-- Per-line sprite load scan for the graphics deadline budget (MAME 0.289).
-- Reads the sprite list the game builds at 0xF000-0xFFFF every frame and
-- computes, for each of the 256 lines, the number of 16-pixel sprite rows the
-- renderer must fetch (same visibility filter as Raiden2_sprite_renderer:
-- code != 0 and code < 0x8000). Plays attract, then a 2-player autoplay with
-- continues. Output: CORE_OUT/load.csv (per-frame max), worst_sprite.bin.
-- Inputs only; no memory writes.
local m = manager.machine
local OUT = assert(os.getenv("CORE_OUT"))
local sp = m.devices[":maincpu"].spaces["program"]
local csv = assert(io.open(OUT .. "/load.csv", "w"))
csv:write("frame,max_rows,line,entries\n")
local function field(port, name)
    return assert(m.ioport.ports[port].fields[name], name)
end
local P = {
    coin1 = field(":COIN", "Coin 1"), coin2 = field(":COIN", "Coin 2"),
    s1 = field(":SYSTEM", "1 Player Start"), s2 = field(":SYSTEM", "2 Players Start"),
    p1r = field(":P1_P2", "P1 Right"), p1l = field(":P1_P2", "P1 Left"),
    p1u = field(":P1_P2", "P1 Up"), p1d = field(":P1_P2", "P1 Down"),
    p1a = field(":P1_P2", "P1 Button 1"), p1b = field(":P1_P2", "P1 Button 2"),
    p2r = field(":P1_P2", "P2 Right"), p2l = field(":P1_P2", "P2 Left"),
    p2u = field(":P1_P2", "P2 Up"), p2d = field(":P1_P2", "P2 Down"),
    p2a = field(":P1_P2", "P2 Button 1"), p2b = field(":P1_P2", "P2 Button 2"),
}
local function set(f, v) f:set_value(v and 1 or 0) end
local worst, frame = -1, 0
local START = tonumber(os.getenv("CORE_PLAY_AT") or "3000")
scan_sub = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    -- inputs
    local t = frame - START
    local credit_phase = t >= 0 and (t % 1800) < 40
    set(P.coin1, credit_phase and (t % 1800) < 8)
    set(P.coin2, credit_phase and (t % 1800) >= 10 and (t % 1800) < 18)
    set(P.s1, credit_phase and (t % 1800) >= 24 and (t % 1800) < 30)
    set(P.s2, credit_phase and (t % 1800) >= 32 and (t % 1800) < 38)
    if t > 60 then
        local seg = (t // 90) % 8
        set(P.p1r, seg ~= 3 and seg ~= 7); set(P.p1l, seg == 3)
        set(P.p1u, seg == 1 or seg == 5);  set(P.p1d, seg == 2)
        set(P.p2r, seg ~= 2 and seg ~= 6); set(P.p2l, seg == 6)
        set(P.p2u, seg == 4);              set(P.p2d, seg == 0 or seg == 5)
        set(P.p1a, (t % 8) < 4); set(P.p2a, ((t + 3) % 8) < 4)
        set(P.p1b, (t % 97) < 4); set(P.p2b, ((t + 40) % 113) < 4)
    end
    -- load
    local rows, ents = {}, {}
    for l = 0, 255 do rows[l] = 0; ents[l] = 0 end
    for e = 0, 511 do
        local a = 0xF000 + e * 8
        local w1 = sp:read_u16(a + 2)
        if w1 ~= 0 and (w1 & 0x8000) == 0 then
            local w0 = sp:read_u16(a)
            local y = sp:read_u16(a + 6) & 0x1ff
            if y >= 0x180 then y = y - 0x200 end
            local h = (((w0 >> 12) & 7) + 1) * 16
            local wcols = ((w0 >> 8) & 7) + 1
            local lo, hi = math.max(0, y), math.min(255, y + h - 1)
            for l = lo, hi do rows[l] = rows[l] + wcols; ents[l] = ents[l] + 1 end
        end
    end
    local mx, ml = 0, 0
    for l = 0, 255 do if rows[l] > mx then mx, ml = rows[l], l end end
    csv:write(frame, ",", mx, ",", ml, ",", ents[ml], "\n")
    if mx > worst then
        worst = mx
        local f = assert(io.open(OUT .. "/worst_sprite.bin", "wb"))
        local t2 = {}
        for i = 0, 4095 do t2[#t2 + 1] = string.char(sp:read_u8(0xF000 + i)) end
        f:write(table.concat(t2)); f:close()
        local g = assert(io.open(OUT .. "/worst.txt", "w"))
        g:write("frame ", frame, " rows ", mx, " line ", ml, "\n"); g:close()
    end
end)
-- Optional: chain the standard scene capture (CORE_FRAME etc.) in the same run.
local capture_script = os.getenv("CORE_CAPTURE_SCRIPT")
if capture_script then dofile(capture_script) end
