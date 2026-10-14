"""Diagnose chip interleaving without relaxing the global sound comparison."""
import argparse
import hashlib
import json
from pathlib import Path
from compare_sound_events import read_events

# MAME 0.289 alpha68k_n.cpp, alpha68k_N_state::sound_iomap.
PORTS = {0x10: ("YM2203", "address"), 0x11: ("YM2203", "data"),
         0x81: ("AY1", "address"), 0x80: ("AY1", "data"),
         0x91: ("AY2", "address"), 0x90: ("AY2", "data")}

def project(events):
    chips = {chip: [] for chip, operation in PORTS.values()}
    unknown = []
    for index, event in enumerate(events):
        pair = PORTS.get(event["address"])
        if pair is None:
            unknown.append({"index": index, **event})
            continue
        chip, operation = pair
        chips[chip].append({**event, "operation": operation})
    return chips, unknown

def raw_sequence(events):
    return [(event["address"], event["data"], event["mask"]) for event in events]

def registers(events):
    selected = None
    result = []
    for event in events:
        if event["operation"] == "address":
            selected = event["data"]
        else:
            result.append((selected, event["data"], event["mask"]))
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("capture", type=Path)
    parser.add_argument("fields", type=int)
    parser.add_argument("mame_source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.mame_source.read_text()
    begin = source.index("void alpha68k_N_state::sound_iomap")
    mapping = source[begin:source.index("\n}", begin)+2]
    for port in ("0x10, 0x11", "0x80, 0x80", "0x81, 0x81", "0x90, 0x90", "0x91, 0x91"):
        if port not in mapping:
            raise RuntimeError("MAME port map changed")
    ref = read_events(args.reference / "events.csv", args.fields, "mame")["sound_io"]
    rtl = read_events(args.capture / "audio_events.csv", args.fields, "rtl_io")["sound_io"]
    ref_chips, ref_unknown = project(ref)
    rtl_chips, rtl_unknown = project(rtl)
    differences = [index for index in range(min(len(ref), len(rtl))) if raw_sequence([ref[index]]) != raw_sequence([rtl[index]])]
    comparisons = {}
    for chip in sorted(ref_chips):
        expected, actual = ref_chips[chip], rtl_chips[chip]
        comparisons[chip] = {
            "reference_writes": len(expected), "rtl_writes": len(actual),
            "ordered_port_writes_equal": raw_sequence(expected) == raw_sequence(actual),
            "decoded_register_data_equal": registers(expected) == registers(actual),
            "field_label_differences": sum(a["frame"] != b["frame"] for a, b in zip(expected, actual)),
        }
    first = differences[0] if differences else None
    result = {
        "scope": "Diagnostic projection onto each physically independent sound chip. Preserves the failed global ordered comparison; does not qualify bus timing, PCM or physical audio.",
        "source": str(args.mame_source.resolve()),
        "source_sha256": hashlib.sha256(args.mame_source.read_bytes()).hexdigest(),
        "mapping": mapping, "fields": args.fields,
        "global_order_equal": raw_sequence(ref) == raw_sequence(rtl),
        "global_reference_writes": len(ref), "global_rtl_writes": len(rtl),
        "global_differing_indices": differences,
        "first_difference_context": None if first is None else {
            "start_index": max(0, first-2), "reference": ref[max(0,first-2):first+9], "rtl": rtl[max(0,first-2):first+9]},
        "unknown_reference_ports": ref_unknown, "unknown_rtl_ports": rtl_unknown,
        "chips": comparisons,
        "all_chip_sequences_equal": not ref_unknown and not rtl_unknown and all(x["ordered_port_writes_equal"] and x["decoded_register_data_equal"] for x in comparisons.values()),
    }
    args.output.write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps({key:result[key] for key in ("global_order_equal", "all_chip_sequences_equal", "chips")}))
    return 0 if result["all_chip_sequences_equal"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
