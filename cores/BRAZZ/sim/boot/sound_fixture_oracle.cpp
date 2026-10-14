// SPDX-License-Identifier: BSD-3-Clause
// Independent audio calculation in a separate TU to retain unchanged MAME bodies.
#include "../obj_dir/spu_reference/spu_reference.hpp"
static vr0sound_device sound;
static audio_cache frame;
void sound_fixture_reference_reset(){
    sound=vr0sound_device();sound.m_ctrl=32768;sound.m_max_chan=31;sound.m_chan_clk_num=29;
    for(unsigned a=0;a<8;++a)frame.bytes[a]=0x7f;
    for(unsigned c:{0u,31u}){
        auto&v=sound.m_channel[c];
        const u16 words[16]={0,0,0,0x107f,0x100,0x2000,0,u16(c==0?0x7f00:0x2000),1,u16(c==0?0x4000:0x6000),0,0,0,0,0,0};
        for(unsigned w=0;w<16;++w)v.write(w,words[w],65535);
        v.cache=&frame;sound.m_status|=1u<<c;
    }
}
void sound_fixture_reference_render(int32_t*left,int32_t*right){
    sound_stream output;sound.render_audio(output);
    *left=std::max(-32768,std::min(32767,output.left));
    *right=std::max(-32768,std::min(32767,output.right));
}
