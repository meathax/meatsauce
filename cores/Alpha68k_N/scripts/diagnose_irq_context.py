"""Compare recorded IRQ stack frames and vector timing without changing RTL."""
from pathlib import Path
import csv,json,hashlib
ROOT=Path(__file__).resolve().parents[1]
NATIVE=ROOT/'sim/captures/rtl/kyros_instruction60_diagnostic/instruction_events.csv'
MAME=ROOT/'sim/captures/kyros/reset_raster361_v4/events.csv'

def nrows():
    out=[]
    with NATIVE.open() as f:
        for x in csv.DictReader(f):
            out.append({**x, "time":int(x["tick"]), "addr":int(x["address"]), "value":int(x["data_out"]),
                        "write":x["rw"]=="0" and x["iack"]=="0",
                        "vector":x["rw"]=="1" and x["iack"]=="0" and int(x["address"]) in (0x64,0x66,0x68,0x6a)})
    return out

def mrows():
    out=[]
    with MAME.open() as f:
        for x in csv.DictReader(f):
            if not 59<=int(x["frame"])<=60:continue
            out.append({**x, "time":int(x["master_ticks"]), "addr":int(x["address"]), "value":int(x["data"]),
                        "write":x["area"]=="work", "vector":x["area"]=="main_vector_read"})
    return out

def contexts(rows):
    out=[]
    for i,event in enumerate(rows):
        if not event["vector"] or event["addr"] not in (0x64,0x68):continue
        writes=[x for x in rows[:i] if x["write"] and 0x20000<=x["addr"]<0x21000 and event["time"]-400<=x["time"]]
        frame=writes[-3:]
        if len(frame)!=3:raise RuntimeError("missing complete exception frame")
        # Actual68000 frame bus order: PC low at SP+4, SR at SP, PC high at SP+2.
        low,sr,high=frame
        if (low["addr"],high["addr"])!=(sr["addr"]+4,sr["addr"]+2):
            raise RuntimeError("unexpected exception write layout")
        second=next((x for x in rows[i+1:i+12] if x["vector"] and x["addr"]==event["addr"]+2),None)
        if second is None:raise RuntimeError("missing vector low word")
        out.append({"field":int(event["frame"]), "level":1 if event["addr"]==0x64 else 2,
                    "vector_first_tick":event["time"],"vector_second_tick":second["time"],
                    "pc_low_store_tick":low["time"],"sr_store_tick":sr["time"],
                    "pc_high_store_tick":high["time"],"saved_pc":((high["value"]&65535)<<16)|(low["value"]&65535),
                    "saved_sr":sr["value"]&65535,"stack_base":sr["addr"],
                    "pc_low_to_sr_ticks":sr["time"]-low["time"],
                    "pc_low_to_vector_ticks":event["time"]-low["time"],
                    "frame_writes":frame})
    return out

def main():
    n,m=contexts(nrows()),contexts(mrows())
    if len(n)!=4 or len(m)!=4:raise RuntimeError("expected four observed IRQs")
    comparisons=[]
    for actual,reference in zip(n,m):
        if (actual["field"],actual["level"])!=(reference["field"],reference["level"]):raise RuntimeError("IRQ order differs")
        equal=all(actual[k]==reference[k] for k in ["saved_pc","saved_sr","stack_base"])
        comparisons.append({"field":actual["field"],"level":actual["level"],"same_exception_frame":equal,
                            "native":actual,"mame":reference,
                            "pc_low_store_native_minus_mame_ticks":actual["pc_low_store_tick"]-reference["pc_low_store_tick"],
                            "vector_native_minus_mame_ticks":actual["vector_first_tick"]-reference["vector_first_tick"],
                            "additional_pc_low_to_vector_native_ticks":actual["pc_low_to_vector_ticks"]-reference["pc_low_to_vector_ticks"]})
    result={"scope":"Finite actual IRQ stack/vector observations. Absolute clock origins are not declared equal; within-frame store/vector intervals are direct. No physical-board or CPU-cycle correction claim.",
            "inputs_sha256":{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [NATIVE,MAME]},
            "same_exception_frames":all(x["same_exception_frame"] for x in comparisons),"comparisons":comparisons}
    out=ROOT/'research/kyros_irq59_60_context_comparison.json';out.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"same_exception_frames":result["same_exception_frames"],"cases":[{k:x[k] for k in ["field","level","pc_low_store_native_minus_mame_ticks","vector_native_minus_mame_ticks","additional_pc_low_to_vector_native_ticks"]} for x in comparisons]}))
    return 0 if result["same_exception_frames"] else 1

if __name__=="__main__":raise SystemExit(main())
