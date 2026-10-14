"""Extract unchanged MAME CRTC bodies and the captured game setup for RTL tests."""
from pathlib import Path
import csv
import hashlib
import json
from gpu_reference import body

ROOT = Path(__file__).resolve().parents[1]
# CRTC register/timing bodies come from the staged MAME master copy (crtc_r status bits,
# light-pen split); the capture-based game rows remain from the pinned 0.289 run.
SOURCE = ROOT / "docs/reference/mame_master/src/devices/machine/vrender0.cpp"

def main():
    out = ROOT / "sim/obj_dir/crtc_reference"
    out.mkdir(parents=True, exist_ok=True)
    names = ["u32 vrender0soc_device::crtc_r", "void vrender0soc_device::crtc_w",
             "inline bool vrender0soc_device::crt_is_interlaced", "bool vrender0soc_device::crt_active_vblank_irq",
             "void vrender0soc_device::crtc_update"]
    prefix = r'''// Five unchanged MAME master CRTC bodies; test-only screen adapter.
#pragma once
#include <cstdint>
#include <stdexcept>
using u32=uint32_t; using offs_t=uint32_t;
#define BIT(x,n) (((x)>>(n))&1)
#define COMBINE_DATA(p) (*(p)=(*(p)&~mem_mask)|(data&mem_mask))
#define HZ_TO_ATTOSECONDS(hz) (uint64_t(1000000000000000000ULL)/(hz))
#define LOG_CRTC 0
#define LOGMASKED(...) ((void)0)
struct attotime { uint64_t v; static attotime from_ticks(uint64_t n,uint32_t c){return {n*(1000000000000000000ULL/c)};} operator uint64_t()const{return v;} };
struct rectangle { int min_x,max_x,min_y,max_y;
    rectangle(int a,int b,int c,int d):min_x(a),max_x(b),min_y(c),max_y(d){} };
struct screen_adapter {
    u32 h=455,v=262,hd=320,vd=240,x=0,y=0,frame=0; uint64_t period=0;
    u32 hpos()const{return x;} u32 vpos()const{return y;} u32 frame_number()const{return frame;}
    void configure(u32 a,u32 b,const rectangle&r,uint64_t p){h=a;v=b;hd=r.max_x+1;vd=r.max_y+1;period=p;}
};
struct machine_adapter {const char*describe_context(){return "test";}};
inline void fatalerror(const char*,const char*){throw std::runtime_error("oracle external vclk unspecified");}
struct vrender0soc_device {
    u32 m_crtcregs[256]{},m_ext_vclk=14318180;
    screen_adapter screen; screen_adapter*m_screen=&screen;
    vrender0soc_device(){m_crtcregs[1]=0x2a;}
    machine_adapter machine(){return {};}
    u32 crtc_r(offs_t);void crtc_w(offs_t,u32,u32);
    bool crt_is_interlaced();bool crt_active_vblank_irq();void crtc_update();
};
'''
    generated = out / "crtc_reference.hpp"
    generated.write_text("\n".join(SOURCE.read_text().splitlines()[:2])+"\n"+prefix + "\n\n".join(body(SOURCE.read_text(), n) for n in names)
                         + "\n#undef BIT\n#undef COMBINE_DATA\n#undef HZ_TO_ATTOSECONDS\n")
    capture = json.loads((ROOT / "docs/mame_gpu_fixture.json").read_text())
    trace = Path(capture["output_directory"]) / "mmio.csv"
    count = 0
    with trace.open() as src, (out / "crtc.csv").open("w", newline="") as dst:
        reader = csv.DictReader(src)
        writer = csv.DictWriter(dst, fieldnames=reader.fieldnames)
        writer.writeheader()
        for row in reader:
            if 0x01803400 <= int(row["address"],16) <= 0x018037ff:
                writer.writerow(row); count += 1
    report = {"scope":"test-only unchanged MAME register/timing oracle and real game CRTC setup; physical sync/interlace fidelity pending",
              "source_sha256":hashlib.sha256(SOURCE.read_bytes()).hexdigest(),"source":"MAME master vrender0.cpp (staged docs/reference/mame_master)",
              "generated_sha256":hashlib.sha256(generated.read_bytes()).hexdigest(),
              "unchanged_function_bodies":names, "trace":trace.as_posix(), "rows":count,
              "trace_sha256":hashlib.sha256((out/"crtc.csv").read_bytes()).hexdigest(),
              "limitations":["MAME total/porch rules include documented guesses", "sync pin phase/polarity and half-line interlace are not MAME evidence"]}
    (ROOT / "docs/crtc_reference.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"Generated five unchanged MAME CRTC bodies and {count} captured rows.")

if __name__ == "__main__": main()
