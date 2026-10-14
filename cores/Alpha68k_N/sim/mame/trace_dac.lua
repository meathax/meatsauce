-- Read-only DPCM diagnosis layered on the unchanged reference recorder.
local machine = manager.machine
local screen = assert(machine.screens[":screen"])
local sound = assert(machine.devices[":audiocpu"])
local root = assert(os.getenv("ALPHA_DAC_TRACE_ROOT"))
local output = assert(os.getenv("ALPHA_CAPTURE_DIR"))
local file = assert(io.open(output .. "/sound_bus_events.csv", "w"))
file:write("time,frame,screen_frame,kind,address,data,pc,vpos,hpos,mask\n")
local function observe(kind, address, data, mask)
    local time = emu.time()
    -- The original recorder completes callback 0 after one whole raw field.
    local frame = math.floor((time + 1e-12) / screen.frame_period)
    local pc = sound.state["PC"].value
    if kind == "read" and not (frame >= 118 and frame <= 124 and pc >= 0x037d and pc < 0x04cd) then return end
    local phase = (screen.frame_period - screen:time_until_pos(0,0)) % screen.frame_period
    local pixel = math.floor(phase / screen.pixel_period + 0.5) % (384*264)
    file:write(string.format("%.15f,%d,%d,%s,%d,%d,%d,%d,%d,%d\n", time, frame,
        screen:frame_number(), kind, address, data, pc, pixel // 384, pixel % 384, mask))
end
_G.alpha_dac_trace_handles = {
    sound.spaces["program"]:install_write_tap(0xc100,0xc123,"alpha_dac_control",function(a,d,m) observe("write",a,d,m) end),
    sound.spaces["program"]:install_read_tap(0x0500,0xbfff,"alpha_dac_rom",function(a,d,m) observe("read",a,d,m) end),
}
_G.alpha_dac_trace_flush = emu.add_machine_frame_notifier(function() file:flush() end)
dofile(root .. "/sim/mame/capture.lua")
