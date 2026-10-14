-- Read-only observer added to the unchanged canonical gameplay recorder.
dofile(assert(os.getenv("ALPHA_CANONICAL_CAPTURE_SCRIPT")))
local m = manager.machine
local s = assert(m.screens[":screen"])
local space = assert(m.devices[":maincpu"]).spaces["program"]
local root = assert(os.getenv("ALPHA_CAPTURE_DIR"))
local writes = assert(io.open(root .. "/pixel_word_writes.csv", "w"))
local states = assert(io.open(root .. "/pixel_word_states.csv", "w"))
writes:write("frame,x,y,address,data,mask,before\n")
states:write("frame,x,y,word\n")
local frame = 0
local function beam()
    -- 0.289 exposes time_until_pos, rather than hpos/vpos Lua methods.
    local phase = (s.frame_period - s:time_until_pos(0, 0)) % s.frame_period
    local pixel = math.floor(phase / s.pixel_period + 0.5) % (384 * 264)
    return pixel % 384, pixel // 384
end
-- Keep the tap alive for the entire run; callbacks return no replacement data.
alpha_pixel_word_tap = space:install_write_tap(0x40eea, 0x40eeb, "alpha_pixel_word",
    function(offset, data, mask)
        if frame >= 895 and frame <= 900 then
            local x, y = beam()
            writes:write(string.format("%d,%d,%d,%d,%d,%d,%d\n", frame,
                x, y, offset, data, mask, space:read_u16(0x40eea)))
            writes:flush()
        end
    end)
alpha_pixel_frame_subscription = emu.add_machine_frame_notifier(function()
    if frame >= 895 and frame <= 900 then
        local x, y = beam()
        states:write(string.format("%d,%d,%d,%d\n", frame, x, y, space:read_u16(0x40eea)))
        states:flush()
    end
    frame = frame + 1
end)
-- Every row is flushed above; MAME closes the Lua files on machine shutdown.
