// SPDX-License-Identifier: BSD-3-Clause
#include "Vvr0_voice.h"
#include "verilated.h"
#include "../obj_dir/spu_reference/spu_reference.hpp"
#include <cstdio>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <string>

static Vvr0_voice d;static audio_cache texture,frame;
static uint64_t clocks=0,jobs=0,requests=0,checks=0;static unsigned worst=0;
double sc_time_stamp(){return double(clocks);}
static uint32_t rng=0x5839247;static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void require(bool v,const char*s){++checks;if(!v)throw std::runtime_error(s);}
static void tick(){d.clk=0;d.eval();d.clk=1;d.eval();++clocks;d.clk=0;d.eval();}
static uint32_t word(uint32_t a){
    audio_cache*c=nullptr;if(a>=0x03800000 && a<=0x03ffffff){c=&texture;a-=0x03800000;}
    else if(a>=0x04000000 && a<=0x047fffff){c=&frame;a-=0x04000000;}
    else throw std::runtime_error("invalid coherent memory region");
    require(!(a&3),"unaligned board request");return uint32_t(c->bytes[a])|(uint32_t(c->bytes[a+1])<<8)|(uint32_t(c->bytes[a+2])<<16)|(uint32_t(c->bytes[a+3])<<24);
}
static void reset(){d.reset=1;d.job_valid=0;d.result_ready=0;d.req_ready=0;d.rsp_valid=0;d.rsp_error=0;tick();d.reset=0;tick();require(d.job_ready && !d.result_valid && !d.req_valid,"reset interface");}
using Channel=vr0sound_device::channel_t;
static void job(Channel c,unsigned chclock,bool tex,bool fail=false){
    vr0sound_device ref;ref.m_status=1;ref.m_int_mask=0;ref.m_chan_clk_num=chclock;
    c.cache=tex?&texture:&frame;ref.m_channel[0]=c;sound_stream audio;
    if(!fail)ref.render_audio(audio);
    require(d.job_ready,"voice not ready");d.current_address=c.cur_saddr;d.envelope_volume=uint32_t(c.env_vol);d.envelope_stage=c.env_stage;
    d.frequency=c.ds_addr;d.modes=c.modes;d.texture_selected=tex;d.loop_begin=c.loop_begin;d.loop_end=c.loop_end;
    d.left_volume=c.l_chn_vol;d.right_volume=c.r_chn_vol;d.envelope_targets=0;
    for(unsigned i=0;i<4;++i){d.envelope_rates[i]=uint32_t(c.env_rate[i]);d.envelope_targets|=uint32_t(c.env_target[i]&127)<<(i*7);}
    d.clock_divisor=chclock?((30u<<16)|0x8000)/(chclock+1):65536;
    d.job_valid=1;d.req_ready=0;d.rsp_valid=0;tick();d.job_valid=0;
    uint64_t before=clocks,req_before=requests;bool pending=false;unsigned delay=0;uint32_t data=0;bool held=false;uint32_t held_address=0;
    while(!d.result_valid){
        require(clocks-before<100,"voice completion timeout");d.req_ready=(random32()%4)!=0;d.rsp_valid=0;d.rsp_error=0;
        if(pending){if(delay)--delay;else{d.rsp_valid=1;d.rsp_data=data;d.rsp_error=fail;pending=false;}}
        d.eval();
        if(held)require(d.req_valid && d.req_address==held_address,"request changed under backpressure");
        held=d.req_valid && !d.req_ready;held_address=d.req_address;
        if(d.req_valid && d.req_ready){require(!pending,"multiple outstanding reads");require(!d.req_write && d.req_strobe==15,"voice issued invalid memory operation");
            uint32_t expected=(tex?0x03800000:0x04000000)+((c.cur_saddr>>9)&~3u);require(d.req_address==expected,"sample address mismatch");
            data=word(d.req_address);pending=true;delay=1+random32()%11;++requests;
        }
        tick();
    }
    worst=std::max(worst,unsigned(clocks-before));require(requests-req_before==1,"voice read count");require(bool(d.memory_fault)==fail,"memory fault indication");
    if(!fail){auto&r=ref.m_channel[0];
        if(d.next_address!=r.cur_saddr || int32_t(d.next_envelope_volume)!=r.env_vol || d.next_envelope_stage!=r.env_stage || int32_t(d.left_contribution)!=audio.left || int32_t(d.right_contribution)!=audio.right){
            std::printf("case %llu fmt=%02x clock=%u pos=%08x step=%04x env=%08x stage=%02x div=%u\n",(unsigned long long)jobs,c.modes,chclock,c.cur_saddr,c.ds_addr,uint32_t(c.env_vol),c.env_stage,d.clock_divisor);
            std::printf("RTL pos=%08x env=%08x stage=%02x LR=%d,%d oracle pos=%08x env=%08x stage=%02x LR=%d,%d\n",d.next_address,d.next_envelope_volume,d.next_envelope_stage,int32_t(d.left_contribution),int32_t(d.right_contribution),r.cur_saddr,uint32_t(r.env_vol),r.env_stage,audio.left,audio.right);
            throw std::runtime_error("MAME voice/state comparison");
        }
        checks+=5;require(bool(d.ended)==!(ref.m_status&1),"end/status mismatch");require(d.unsupported_modes==(c.modes&10),"unknown mode diagnostic");
    }else{
        require(d.next_address==c.cur_saddr && int32_t(d.next_envelope_volume)==c.env_vol && d.next_envelope_stage==c.env_stage,"fault changed voice state");
        require(d.left_contribution==0 && d.right_contribution==0,"fault produced audio");
    }
    uint32_t addr=d.next_address,env=d.next_envelope_volume,st=d.next_envelope_stage,l=d.left_contribution,r=d.right_contribution;
    for(unsigned i=0;i<3;++i){tick();require(d.result_valid && d.next_address==addr && d.next_envelope_volume==env && d.next_envelope_stage==st && d.left_contribution==l && d.right_contribution==r,"result changed under backpressure");}
    d.result_ready=1;tick();d.result_ready=0;require(d.job_ready && !d.result_valid,"result handshake");++jobs;
}
static Channel base(){Channel c;c.env_vol=127<<16;c.env_stage=1;c.loop_end=0x3fffff;c.l_chn_vol=127;c.r_chn_vol=91;return c;}
static void real_fixture(){
    std::ifstream f("sim/obj_dir/spu_reference/initial_voices.csv");require(bool(f),"missing real voice fixture");
    // The capture path is written by the generator from the immutable report.
    std::ifstream paths("sim/obj_dir/spu_reference/memory_paths.txt");require(bool(paths),"missing real memory paths");
    std::string tex,fb;std::getline(paths,tex);std::getline(paths,fb);
    for(auto pair: {std::make_pair(tex,&texture),std::make_pair(fb,&frame)}){
        std::ifstream in(pair.first,std::ios::binary);require(bool(in),"missing captured sample memory");
        in.read(reinterpret_cast<char*>(pair.second->bytes.data()),8388608);require(in.gcount()==8388608,"wrong fixture memory length");
    }
    std::string line;std::getline(f,line);unsigned count=0;
    while(std::getline(f,line)){std::stringstream ss(line);std::string value;unsigned index,clock,selected;
        std::getline(ss,value,',');index=std::stoul(value);std::getline(ss,value,',');clock=std::stoul(value);std::getline(ss,value,',');selected=std::stoul(value);
        Channel c;for(unsigned offset=0;offset<16;++offset){require(bool(std::getline(ss,value,',')),"bad voice capture row");c.write(offset,uint16_t(std::stoul(value,nullptr,16)),65535);}
        job(c,clock,selected);++count;std::printf("PASS real initial voice %u: format=%02x, memory=%s, position=%08x\n",index,c.modes,selected?"texture":"frame",c.cur_saddr);
    }require(count>0,"empty active voice capture");
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
    for(unsigned i=0;i<8388608;++i){texture.bytes[i]=uint8_t(i*73+(i>>8)*23+17);frame.bytes[i]=uint8_t(i*19+(i>>7)*71+129);}
    reset();
    // Every conversion-table/linear-byte value, all four lanes and both spaces.
    for(unsigned fmt: {16u,32u})for(unsigned value=0;value<256;++value)for(unsigned lane=0;lane<4;++lane){
        auto c=base();c.cur_saddr=((128+lane)<<9)|511;c.modes=fmt;bool tex=(value&1);(tex?texture:frame).bytes[128+lane]=value;job(c,0,tex);
    }
    const uint16_t edge[]={0,1,0x7f,0x80,0x7fff,0x8000,0xffff,0xff00,0x1234,0x8123};
    for(unsigned pos=0;pos<8;++pos)for(auto value:edge){auto c=base();c.cur_saddr=((1024+pos)<<9)|233;
        auto&m=(pos&1)?texture:frame;unsigned a=(c.cur_saddr>>9)&~1u;m.bytes[a]=value&255;m.bytes[a+1]=value>>8;job(c,0,pos&1);}
    // Envelope cascades, address wrap, positive/negative rate and all dividers.
    for(unsigned clk=0;clk<256;++clk)for(unsigned stage=0;stage<16;++stage){auto c=base();c.cur_saddr=0xfffff100+(stage*97);c.modes=5|(stage&1?16:32);c.env_stage=stage;
        c.ds_addr=uint16_t(0xf000+clk*11);c.loop_begin=0x300;c.loop_end=0x3ffffe;c.env_vol=int32_t(0x007e0100+clk*111);
        c.env_rate[0]=65535;c.env_rate[1]=-65536;c.env_rate[2]=65536;c.env_rate[3]=-1;
        c.env_target[0]=127;c.env_target[1]=0;c.env_target[2]=1;c.env_target[3]=126;job(c,clk,stage&1);}
    for(unsigned i=0;i<8192;++i){auto c=base();c.cur_saddr=random32();c.env_vol=int32_t(random32());c.env_stage=random32()&255;c.ds_addr=random32();c.modes=random32()&127;
        c.loop_begin=random32()&0x3fffff;c.loop_end=random32()&0x3fffff;c.l_chn_vol=random32()&127;c.r_chn_vol=random32()&127;
        for(unsigned k=0;k<4;++k){c.env_rate[k]=int32_t((random32()&0x1ffff)^0x10000)-65536;c.env_target[k]=random32()&127;}
        job(c,random32()&255,i&1);
    }
    real_fixture();job(base(),0,true,true);job(base(),31,false,true);
    // Reset cancels an unaccepted request and a registered result.
    d.current_address=0;d.job_valid=1;tick();d.job_valid=0;d.req_ready=0;tick();require(d.req_valid,"missing held read");reset();job(base(),0,false);
    require(worst<50,"isolated voice latency unexpectedly high");
    std::printf("PASS VRender0 voice: %llu differential jobs / %llu checks / %llu coherent reads / %llu clocks; exact ulaw256, linear8/16, pitch/wrap/loop/end, envelope cascades, pan, stalls/fault/reset; worst isolated voice %u clocks\n",(unsigned long long)jobs,(unsigned long long)checks,(unsigned long long)requests,(unsigned long long)clocks,worst);return 0;
}catch(const std::exception&e){std::fprintf(stderr,"FAIL %s after %llu jobs / %llu clocks\n",e.what(),(unsigned long long)jobs,(unsigned long long)clocks);return 1;}}
