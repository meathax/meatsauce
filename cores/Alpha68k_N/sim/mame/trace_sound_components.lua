-- Read-only MAME0.289 sound buffers, alongside the unchanged game recorder.
local machine = manager.machine
local root = assert(os.getenv("ALPHA_CAPTURE_DIR"))
local samples = assert(io.open(root .. "/sound_components.csv", "w"))
local schema = assert(io.open(root .. "/sound_schema.csv", "w"))
samples:write("update,time_end,component,samples,sum,sum_squared,minimum,maximum\n")
schema:write("tag,inputs,outputs\n")
for _, tag in ipairs({":ym", ":aysnd1", ":aysnd2", ":dac", ":speaker"}) do
    local device = assert(machine.sounds[tag], "missing sound interface " .. tag)
    device.hook = true
    schema:write(string.format("%s,%d,%d\n", tag, device.inputs, device.outputs))
end
schema:flush()
local update = 0
local function collect(buffers, indices, gain, label, time)
    local n = #assert(buffers[indices[1]], "missing sound channel")
    for _, index in ipairs(indices) do assert(#buffers[index] == n, "channel length mismatch") end
    if n == 0 then return end
    local sum, squared, minimum, maximum = 0, 0, math.huge, -math.huge
    for i = 1, n do
        local value = 0
        for _, index in ipairs(indices) do value = value + buffers[index][i] end
        value = value * gain * 32768
        sum = sum + value
        squared = squared + value * value
        minimum = math.min(minimum, value)
        maximum = math.max(maximum, value)
    end
    samples:write(string.format("%d,%.15f,%s,%d,%.15g,%.15g,%.15g,%.15g\n",
        update, time, label, n, sum, squared, minimum, maximum))
end
emu.register_sound_update(function(sound)
    local time = emu.time()
    -- ymfm_mame.h rotates YM2203 output order: SSG1/2/3, then FM.
    local ym = assert(sound[":ym"], "YM sound hook missing")
    collect(ym, {4}, 0.30, "fm", time)
    collect(ym, {1, 2, 3}, 0.30, "ym_ssg", time)
    collect(assert(sound[":aysnd1"]), {1, 2, 3}, 0.30, "ay1", time)
    collect(assert(sound[":aysnd2"]), {1, 2, 3}, 0.60, "ay2", time)
    collect(assert(sound[":dac"]), {1}, 0.50, "dac", time)
    collect(assert(sound[":speaker"]), {1}, 1.0, "speaker", time)
    samples:flush()
    update = update + 1
end)
dofile(assert(os.getenv("ALPHA_CANONICAL_CAPTURE_SCRIPT")))
-- Rows are flushed on every update; process shutdown closes the Lua files.
