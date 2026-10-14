-- Additional read-only write/beam observer around the pinned warm-reset recorder.
-- Keep both tap handles and notifier alive across the real machine soft reset.
if _G.alpha_raster_reference_started then return end
_G.alpha_raster_reference_started = true
local machine = manager.machine
local screen = machine.screens[":screen"]
local space = machine.devices[":maincpu"].spaces["program"]
local file = assert(io.open(assert(os.getenv("ALPHA_CAPTURE_DIR")) .. "/raster_writes.csv", "wb"))
file:write("frame,screen_frame,hpos,vpos,address,data,mask,before\n")
local frame = 0
local function observe(a, d, m)
    file:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d\n", frame,
        screen:frame_number(), screen:hpos(), screen:vpos(), a, d, m,
        space:read_u16(a & ~1)))
end
_G.alpha_raster_reference_handles = {
    space:install_write_tap(0x040000, 0x041fff, "alpha_raster_sprite_writes", observe),
    space:install_write_tap(0x060000, 0x060001, "alpha_raster_background_writes", observe),
    file
}
_G.alpha_raster_reference_frame = emu.add_machine_frame_notifier(function()
    file:flush()
    frame = frame + 1
end)
dofile(assert(os.getenv("ALPHA_RASTER_BASE_SCRIPT")))
