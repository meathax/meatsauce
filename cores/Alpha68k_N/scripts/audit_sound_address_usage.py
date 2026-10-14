"""B13/B14 finite usage audit of an existing complete real MAME capture."""
from pathlib import Path
from collections import Counter
import csv
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]


def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""):
            h.update(block)
    return h.hexdigest()


def main():
    capture = ROOT / "sim/captures/kyros/combat3600_v2"
    output = ROOT / "research/kyros_sound_address_usage3600.json"
    if output.exists():
        raise SystemExit("Preserve existing address-usage evidence")
    assert "frames=3600" in (capture / "complete.txt").read_text()
    states = list(csv.DictReader((capture / "frame_states.csv").open()))
    assert [int(r["frame"]) for r in states] == list(range(3600))
    prior = json.loads((ROOT / "research/kyros_combat_hud3301_job.json").read_text())
    assert sha(capture / "frame_states.csv") == prior["input_sha256"]
    driver = Path("D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp")
    source = driver.read_text()
    assert "map(0xc000, 0xc7ff).ram();" in source
    assert "map(0xe006, 0xe00e).nopw();" in source
    identity = json.loads((ROOT / "research/oracle_identity.json").read_text())
    writes = Counter()
    after_field0 = Counter()
    nonzero = Counter()
    ignored = {a:{"writes":0,"values":Counter(),"first_frame":None,"last_frame":None}
               for a in range(0xe006,0xe00f)}
    known = [None]*2048
    witnesses = []
    total = 0
    for row in csv.DictReader((capture / "events.csv").open()):
        total += 1
        if row["area"] != "sound_memory":
            continue
        frame,address,data,mask = (int(row[k]) for k in ("frame","address","data","mask"))
        assert 0 <= frame < 3600
        if 0xc000 <= address <= 0xc7ff:
            assert mask == 255 and 0 <= data <= 255, "Unexpected sound RAM byte event"
            writes[address] += 1
            if frame > 0:
                after_field0[address] += 1
            if data:
                nonzero[address] += 1
            index = address-0xc000
            known[index] = data
            partner = index ^ 0x400
            if known[partner] is not None and known[partner] != data and len(witnesses)<8:
                witnesses.append({"frame":frame,"address":address,"data":data,
                                  "one_kib_alias_partner":0xc000+partner,"partner_value":known[partner]})
        elif address in ignored:
            x = ignored[address]
            x["writes"] += 1
            x["values"][data & mask & 255] += 1
            if x["first_frame"] is None:
                x["first_frame"] = frame
            x["last_frame"] = frame
    def half(lo,hi):
        addresses = sorted(a for a in writes if lo <= a < hi)
        return {"writes":sum(writes[a] for a in addresses),"unique_addresses":len(addresses),
                "minimum":min(addresses) if addresses else None,"maximum":max(addresses) if addresses else None,
                "writes_after_field0":sum(after_field0[a] for a in addresses),
                "nonzero_writes":sum(nonzero[a] for a in addresses)}
    result = {
        "scope":"Existing complete3600-field actual MAME CPU combat capture. Write-address usage only: no sound-RAM read coverage, physical capacity/alias, analog behavior or native RAM equivalence is claimed.",
        "capture":str(capture.relative_to(ROOT)),"frames":3600,"event_rows":total,
        "events_sha256":sha(capture / "events.csv"),"ports_sha256":sha(capture / "frame_states.csv"),
        "driver":str(driver),"driver_sha256":sha(driver),
        "oracle_executable_sha256":identity["executable_sha256"],
        "lower_kib":half(0xc000,0xc400),"upper_kib":half(0xc400,0xc800),
        "distinct_virtual_alias_values":witnesses,
        "ignored_io":{str(a):dict(x,values={str(v):c for v,c in sorted(x["values"].items())}) for a,x in ignored.items()},
        "disposition":"Retain MAME2KiB RAM and nopw digital baseline. Different known values in virtual alias pairs do not prove both bytes are later read or prove original PCB wiring. A1KiB correction requires read/wiring evidence. Ignored-port activity does not identify analog circuitry.",
    }
    output.write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"lower":result["lower_kib"],"upper":result["upper_kib"],
                      "ignored_ports_written":[hex(a) for a,x in ignored.items() if x["writes"]],
                      "alias_value_witnesses":len(witnesses)}))


if __name__ == "__main__":
    main()
