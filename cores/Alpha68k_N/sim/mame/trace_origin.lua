-- Four read-only screen callbacks to bind the MAME capture epoch to time.
local machine = manager.machine
local screen = assert(machine.screens[":screen"])
local main = assert(machine.devices[":maincpu"])
local sound = assert(machine.devices[":audiocpu"])
local output = assert(os.getenv("ALPHA_ORIGIN_TRACE"))
local file = assert(io.open(output, "w"))
file:write("callback,time,screen_frame,vpos,hpos,main_pc,sound_pc\n")
local count = 0
_G.alpha_origin_subscription = emu.add_machine_frame_notifier(function()
    local phase = (screen.frame_period - screen:time_until_pos(0,0)) % screen.frame_period
    local pixel = math.floor(phase / screen.pixel_period + 0.5) % (384*264)
    file:write(string.format("%d,%.15f,%d,%d,%d,%d,%d\n", count, emu.time(),
        screen:frame_number(), pixel // 384, pixel % 384,
        main.state["PC"].value, sound.state["PC"].value))
    file:flush()
    count = count + 1
    if count == 4 then file:close(); machine:exit() end
end)
