"""Derive a real-MAME legal-input warm-reset scenario without game-state patches."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / "sim/mame/capture.lua"
    text = source.read_text()
    original = text
    start = text.index("local function drive_inputs()")
    end = text.index("local function snapshot()", start)
    body = text[start:end]
    assert body.count('if mode ~= "gameplay" then return end') == 1
    body = re.sub(r"\bframe\b", "sequence_frame", body)
    body = body.replace('if mode ~= "gameplay" then return end',
                        'if mode ~= "warm-reset" then return end\n'
                        '    local sequence_frame = frame > 300 and frame-301 or frame')
    text = text[:start] + body + text[end:]
    anchor = 'local inputs = open("inputs.csv")'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '\nlocal reset_events = open("reset_events.csv")\n'
                        'reset_events:write("frame,phase,main_pc,sound_pc\\n")')
    anchor = 'if frame < 260 or (frame >= 590 and frame < 610) or (frame >= 1190 and frame < 1210) then'
    assert text.count(anchor) == 1
    text = text.replace(anchor, 'if true then -- complete finite sound observations')
    anchor = 'if sample_frames[frame] or frame == total-1 then snapshot() end'
    assert text.count(anchor) == 1
    text = text.replace(anchor, 'if sample_frames[frame] or frame%30 == 0 or frame == total-1 then snapshot() end')
    anchor = '    drive_inputs()\n'
    assert text.count(anchor) == 1
    text = text.replace(anchor, '''    drive_inputs()
    if frame == 300 then
        for _,mask in ipairs({1,2,4,8,0x10,0x20,0x80}) do set_input("IN0",mask,false) end
        set_input("IN2",1,false)
        reset_events:write(string.format("%d,scheduled,%d,%d\\n",frame,pc(main),pc(sound)))
        reset_events:flush()
        machine:soft_reset()
    elseif frame == 301 then
        reset_events:write(string.format("%d,post-reset,%d,%d\\n",frame,pc(main),pc(sound)))
        reset_events:flush()
    end
''')
    anchor = 'local function finish()'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '\n    reset_events:close()')
    text = ('if _G.alpha_warm_reset_capture_started then return end\n'
            '_G.alpha_warm_reset_capture_started = true\n' + text)
    output = ROOT / "sim/mame/capture_warm_reset.lua"
    output.write_text(text)
    metadata = {
        "canonical_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "derived_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "reset_after_field": 300, "fields": 960,
        "scope": "Legal controls and MAME soft reset; no CPU/RAM patches; callback counter retained",
    }
    (ROOT / "research/kyros_warm_reset_source.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
