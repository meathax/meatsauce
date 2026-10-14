"""Derive a legal-input two-player cocktail oracle; no game state writes."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / "sim/mame/capture.lua"
    text = source.read_text()
    before = 'local total = tonumber(os.getenv("ALPHA_CAPTURE_FRAMES") or "1800")'
    assert text.count(before) == 1
    text = text.replace(before, '''local dip_port = assert(machine.ioport.ports["IN1"] or machine.ioport.ports[":IN1"])
assert(dip_port.fields["Cabinet"]).user_value = 0
assert(dip_port.fields["Coinage"]).user_value = 6 -- A1C/2C, B2C/1C
assert(dip_port.fields["Difficulty"]).user_value = 0x40
local native_flip = 0
local total = tonumber(os.getenv("ALPHA_CAPTURE_FRAMES") or "3601")''', 1)
    before = '    observe("mcu_command_write",a,d,m)'
    assert text.count(before) == 1
    text = text.replace(before, '''    observe("mcu_command_write",a,d,m)
    if a == 0x08005a and (m & 255) ~= 0 then native_flip = d & 1 end''', 1)
    start = text.index("local function drive_inputs()")
    end = text.index("local function dump(", start)
    text = text[:start] + '''local p2_controls = 0
local function drive_inputs()
    if frame == 120 then set_input("IN2",1,true) end
    if frame == 126 then set_input("IN2",1,false) end
    -- One A coin legally buys the two credits needed for a two-player start.
    if frame == 160 then set_input("IN0",0x8000,true) end
    if frame == 166 then set_input("IN0",0x8000,false) end
    -- Player1 stays idle and dies naturally. Player2 actions are ignored
    -- before its turn and exercised afterward; never patch RAM or CPU state.
    local desired = 0
    if frame >= 600 then
        local phase = (frame-600) % 240
        desired = phase < 60 and 4 or (phase < 120 and 1 or (phase < 180 and 8 or 2))
        if phase % 30 < 20 then desired = desired | 0x10 end
        if phase % 120 >= 100 and phase % 120 < 108 then desired = desired | 0x20 end
    end
    for _, mask in ipairs({1,2,4,8,0x10,0x20}) do
        if ((desired ~ p2_controls) & mask) ~= 0 then
            set_input("IN0", mask << 8, (desired & mask) ~= 0)
        end
    end
    p2_controls = desired
end

''' + text[end:]
    before = 'if sample_frames[frame] or frame == total-1 then snapshot() end'
    assert text.count(before) == 1
    text = text.replace(before, 'if sample_frames[frame] or frame % 30 == 0 or frame == total-1 then snapshot() end', 1)
    before = 'if frame < 260 or (frame >= 590 and frame < 610) or (frame >= 1190 and frame < 1210) then'
    assert text.count(before) == 1
    text = text.replace(before, 'if true then -- complete finite sound/MCU/input observations', 1)
    # Declare before finish so its closure resolves the local file handle.
    before = 'local function finish()'
    assert text.count(before) == 1
    text = text.replace(before, '''local flip_trace = open("native_flip.csv")
flip_trace:write("frame,flip\\n")
local function finish()''', 1)
    # Independent frame-level flip trace, derived only from actual MCU writes.
    before = 'local function capture_frame()'
    assert text.count(before) == 1
    text = text.replace(before, '''local function capture_frame()
    flip_trace:write(string.format("%d,%d\\n",frame,native_flip))
    if frame % 60 == 0 then flip_trace:flush() end''', 1)
    before = 'histogram:close();events:close();inputs:close();states:close();status:close();frame_states:close()'
    assert text.count(before) == 1
    text = text.replace(before, before+';flip_trace:close()', 1)
    target = ROOT / "sim/mame/capture_cocktail_v2.lua"
    assert not target.exists(), "Preserve existing scenario evidence"
    target.write_text("-- Generated legal-port scenario; no RAM/register writes.\n"+text, encoding="utf-8", newline="\n")
    evidence = {
        "canonical_source": str(source.relative_to(ROOT)),
        "canonical_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "derived_source": str(target.relative_to(ROOT)),
        "derived_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "dips": 0x46, "coinage": "A1C/2C B2C/1C", "cabinet": "Cocktail", "difficulty": "Hard",
        "inputs": "Acoin120..125, start2 160..165, P1idle/natural death; legal P2 directional/buttons from600",
        "scope": "Real MAME CPU execution and legal DIPs/ports only; no RAM/register/PC writes or forced transitions",
    }
    (ROOT / "research/kyros_cocktail_source_v2.json").write_text(json.dumps(evidence, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
