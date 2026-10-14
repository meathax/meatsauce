"""Generate a test-only GPU oracle retaining the pinned MAME drawing bodies."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/reference/mame/src/devices/video/vrender0.cpp"
HEADER = SOURCE.with_suffix(".h")

def body(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

def main():
    source = SOURCE.read_text()
    header = HEADER.read_text()
    out = ROOT / "sim/obj_dir/gpu_reference"
    out.mkdir(parents=True, exist_ok=True)
    functions = [body(source, name) for name in [
        "static inline u16 do_shade", "u16 vr0video_device::do_alpha",
        "template <u8 Bpp, bool Tiled, u8 Blend>", "void vr0video_device::draw_quad_fill",
        "int vr0video_device::process_packet", "u32 vr0video_device::screen_update"]]
    helpers = source[source.index("constexpr u32 RGB32"):source.index("static inline u16 do_shade")]
    structs = [body(header, "struct " + name) + ";" for name in ["quad_info", "render_state_info"]]
    prefix = r'''// license:BSD-3-Clause
// copyright-holders:ElSemi, Angelo Salese
// Test-only adapters; MAME drawing function bodies below are unchanged.
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>
#include <utility>
using u8=uint8_t; using u16=uint16_t; using u32=uint32_t;
inline bool BIT(u32 x,unsigned n){return (x>>n)&1;}
inline u8 pal5bit(u32 x){x&=31;return (x<<3)|(x>>2);}
inline u8 pal6bit(u32 x){x&=63;return (x<<2)|(x>>4);}
struct screen_device {};
struct rectangle {int l,r,t,b;rectangle(int L,int R,int T,int B):l(L),r(R),t(T),b(B){} int left()const{return l;}int right()const{return r;}int top()const{return t;}int bottom()const{return b;}};
struct bitmap_ind16 {unsigned width,height;std::vector<u16> data;bitmap_ind16(unsigned w,unsigned h):width(w),height(h),data(w*h){} u16&pix(unsigned y,unsigned x=0){return data.at(y*width+x);}};
struct GpuMemory {
    std::vector<u8> bytes=std::vector<u8>(8*1024*1024);
    bool record_writes=false;
    std::vector<std::pair<u32,u16>> writes;
    u8 read_byte(u32 a)const{return bytes[a&0x7fffff];}
    u16 read_word(u32 a)const{return read_byte(a)|(u16(read_byte(a+1))<<8);}
    u32 read_dword(u32 a)const{return read_word(a)|(u32(read_word(a+2))<<16);}
    void write_word(u32 a,u16 d){if(record_writes)writes.emplace_back(a&0x7fffff,d);bytes[a&0x7fffff]=d;bytes[(a+1)&0x7fffff]=d>>8;}
};
'''
    fields = r'''
    static constexpr u16 NOTRANSCOLOR=0xecda;
    using Draw=void(vr0video_device::*)(quad_info&);
    Draw m_draw_image[2][16];
    GpuMemory &m_texcache,&m_fbcache,&m_fbmem;
    u16 m_internal_palette[256]{};
    u32 m_last_pal_update=0xffffffff;
    render_state_info m_render_state;
    u32 m_draw_dest=0,m_display_dest=0;
    vr0video_device(GpuMemory& t,GpuMemory& f):m_texcache(t),m_fbcache(f),m_fbmem(f){
'''
    for tiled in range(2):
        for blend in range(4):
            for pixel, bpp in enumerate([4, 8, 16, 16]):
                fields += f"        m_draw_image[{tiled}][{blend*4+pixel}]=&vr0video_device::draw_quad<{bpp},{'true' if tiled else 'false'},{blend}>;\n"
    fields += r'''
    }
    u32 get_fb_addr(u16 x,u16 y){return ((x&0x3ff)|(u32(y&0x1ff)<<10))<<1;}
    u16 get_packet(u32 p){return m_texcache.read_word(p<<1);}
    u16 do_alpha(quad_info&,u16,u16);
    template<u8 Bpp,bool Tiled,u8 Blend> void draw_quad(quad_info&);
    void draw_quad_fill(quad_info&);
    int process_packet(u32);
    u32 screen_update(screen_device&,bitmap_ind16&,const rectangle&);
};
'''
    generated = out / "vr0_gpu_reference.hpp"
    generated.write_text(prefix + helpers + "\nclass vr0video_device { public:\n" +
                         "\n".join(structs) + fields + "\n" + "\n\n".join(functions) + "\n")
    report = {"scope": "test-only MAME video oracle; never the board renderer", "not_rtl": True,
              "source": str(SOURCE.relative_to(ROOT)).replace("\\", "/"),
              "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "header_sha256": hashlib.sha256(HEADER.read_bytes()).hexdigest(),
              "generated_sha256": hashlib.sha256(generated.read_bytes()).hexdigest(),
              "unchanged_function_bodies": ["do_shade", "do_alpha", "draw_quad", "draw_quad_fill", "process_packet"]}
    (ROOT / "docs/gpu_reference.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Generated test-only MAME VRender0 oracle ({len(functions)} unchanged renderer/scanout bodies).")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
