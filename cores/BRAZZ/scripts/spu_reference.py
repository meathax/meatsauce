"""Independent pinned MAME sample/voice oracle; no production software audio."""
from pathlib import Path
import hashlib
import csv
import json
import re
from gpu_reference import body

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"docs/reference/mame/src/devices/sound/vrender0.cpp"

def main():
    text=SOURCE.read_text();out=ROOT/"sim/obj_dir/spu_reference";out.mkdir(parents=True,exist_ok=True)
    begin=text.index("static const u16 ulaw_to_16[]");end=text.index(";",begin)+1;table=text[begin:end]
    values=re.findall(r"0x[0-9a-fA-F]+",table);assert len(values)==256
    # Constant ROM data comes directly from the pinned vendor-game-derived table.
    literals=",".join("16'h"+v[2:].zfill(4) for v in values)
    pkg='''// SPDX-License-Identifier: BSD-3-Clause
// Conversion table from MAME vrender0.cpp; copyright ElSemi.
package vr0_audio_pkg;
    localparam logic [15:0] ULAW [0:255] = '{'''+literals+'''};
    function automatic logic [15:0] ulaw_decode(input logic [7:0] value);
        return ULAW[value];
    endfunction
endpackage
'''
    pkg_path=ROOT/"rtl/audio/vr0_audio_pkg.sv"
    if not pkg_path.exists() or pkg_path.read_text()!=pkg:pkg_path.write_text(pkg)
    prefix=r'''// license:BSD-3-Clause
// copyright-holders:ElSemi
// Test-only memory/stream adapters. Original render_audio body and table unchanged.
#pragma once
#include <cstdint>
#include <vector>
#include <algorithm>
using u8=uint8_t;using u16=uint16_t;using u32=uint32_t;using s16=int16_t;using s32=int32_t;using offs_t=uint32_t;
namespace util { inline s32 sext(u32 value,unsigned bits){return s32(value<<(32-bits))>>(32-bits);} }
#define COMBINE_DATA(p) (*(p)=(*(p)&~mem_mask)|(data&mem_mask))
#define BIT(x,n) (((x)>>(n))&1)
struct audio_cache {
    std::vector<u8> bytes=std::vector<u8>(8388608);uint64_t reads=0;
    u8 read_byte(u32 a){++reads;return bytes[a&0x7fffff];}
    u16 read_word(u32 a){++reads;return u16(bytes[a&0x7fffff])|(u16(bytes[(a+1)&0x7fffff])<<8);}
};
struct sound_stream {
    s32 left=0,right=0;int samples(){return 1;}
    void put_int_clamp(int ch,int,s32 value,int){if(ch==0)left=value;else right=value;}
};
struct vr0sound_device {
    enum {MODE_LOOP=1,MODE_SUSTAIN=2,MODE_ENVELOPE=4,MODE_PINGPONG=8,
          MODE_ULAW=16,MODE_8BIT=32,MODE_TEXTURE=64,CTRL_RS=32768,CTRL_TM=32};
    struct channel_t {
        audio_cache*cache=nullptr;u32 cur_saddr=0;s32 env_vol=0;u8 env_stage=1;
        u16 ds_addr=0;u8 modes=0;bool ld=true;u32 loop_begin=0,loop_end=0;
        u8 l_chn_vol=0,r_chn_vol=0;s32 env_rate[4]{};u8 env_target[4]{};
        u16 read(offs_t);void write(offs_t,u16,u16);
    };
    channel_t m_channel[32];u32 m_status=0,m_int_mask=0,m_int_pend=0;
    u8 m_max_chan=0,m_chan_clk_num=0;u16 m_ctrl=CTRL_RS;
    struct irq_adapter {bool level=false;void operator()(bool v){level=v;}} m_irq_cb;
    void render_audio(sound_stream&);
};
'''
    names=["u16 vr0sound_device::channel_t::read", "void vr0sound_device::channel_t::write", "void vr0sound_device::render_audio"]
    generated=out/"spu_reference.hpp";generated.write_text(prefix+table+"\n"+"\n\n".join(body(text,n) for n in names)+"\n#undef BIT\n#undef COMBINE_DATA\n")
    fixture_report=ROOT/"docs/mame_audio_fixture.json"
    fixture_count=0
    with (out/"initial_voices.csv").open("w",newline="") as dst:
        writer=csv.writer(dst);writer.writerow(["index","clock","texture"]+["word"+str(i) for i in range(16)])
        if fixture_report.exists():
            fixture=json.loads(fixture_report.read_text());private=Path(fixture["output_directory"])
            (out/"memory_paths.txt").write_text((private/"first_audio_texture.bin").as_posix()+"\n"+(private/"first_audio_frame.bin").as_posix()+"\n")
            state=json.loads((private/"first_audio_state.json").read_text());maximum=(state["chnnum_after"]>>8)&31
            for index,words in enumerate(state["channel_registers"]):
                if index<=maximum and state["status_after"]&(1<<index):
                    texture=bool(words[5]&0x4000 and state["control_after"]&32)
                    writer.writerow([index,state["chnnum_after"]&255,int(texture)]+[format(w,"04x") for w in words]);fixture_count+=1
    report={"scope":"test-only unchanged MAME voice render body and table; 32-channel scheduling/MMIO and integrated game audio remain pending",
            "source_sha256":hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "generated_sha256":hashlib.sha256(generated.read_bytes()).hexdigest(),
            "ulaw_rom_sha256":hashlib.sha256(pkg_path.read_bytes()).hexdigest(),
            "unchanged_function_bodies":names,"initial_real_voice_jobs":fixture_count,
            "voice_fixture_sha256":hashlib.sha256((out/"initial_voices.csv").read_bytes()).hexdigest(),"integer_contract":"32-bit wrap products, tested with -fwrapv; compare unclamped signed mixer contributions",
            "physical_limits":["MAME envelopes/IRQs/divider unverified", "reverb, sustain and pingpong absent from reference", "global high-bank shifts in source contradict its own register comments"]}
    (ROOT/"docs/spu_reference.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"Generated three unchanged MAME voice/register bodies, ulaw ROM and {fixture_count} real initial voice jobs.")

if __name__=="__main__":main()
