// SPDX-License-Identifier: BSD-3-Clause
#include "Vvr0_spu.h"
#include "verilated.h"
#include "../obj_dir/spu_reference/spu_reference.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <deque>
static Vvr0_spu d;
static audio_cache texture, frame;
static uint64_t clocks=0,checks=0,requests=0,outputs=0,last_sample=0;
static unsigned delay_limit=11, forced_delay=0;
static unsigned busy_clocks=0, worst_busy=0;
static uint32_t rng=0x754b7321;
static bool pending=false, fail_memory=false, last_irq_event=false;
static unsigned irq_events=0;
static unsigned delay=0;
static uint32_t response=0;
static std::deque<std::pair<int,int>> samples;
double sc_time_stamp(){return double(clocks);}
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void require(bool v,const char*message){++checks;if(!v){std::fprintf(stderr,"FAIL %s clock=%llu\n",message,(unsigned long long)clocks);std::exit(1);}}
static void step(){
    d.clk=0;d.rsp_valid=0;d.rsp_error=0;d.req_ready=(random32()%4)!=0;
    if(pending){if(delay)--delay;else{d.rsp_valid=1;d.rsp_data=response;d.rsp_error=fail_memory;pending=false;}}
    d.eval();
    if(d.req_valid&&d.req_ready){
        require(!pending,"more than one outstanding read");require(!d.req_write,"sample request is read");
        require((d.req_address&3)==0,"aligned sample request");
        unsigned base=d.req_address&0xff800000;
        require(base==0x03800000||base==0x04000000,"sample RAM address window");
        auto&m=base==0x03800000?texture:frame;unsigned a=d.req_address&0x7fffff;
        response=uint32_t(m.bytes[a])|(uint32_t(m.bytes[a+1])<<8)|(uint32_t(m.bytes[a+2])<<16)|(uint32_t(m.bytes[a+3])<<24);
        pending=true;delay=forced_delay?forced_delay:1+random32()%delay_limit;++requests;
    }
    d.clk=1;d.eval();++clocks;
    require(!(last_irq_event&&d.irq_event),"one-clock end IRQ event");
    if(d.irq_event)++irq_events;last_irq_event=d.irq_event;
    if(!d.reg_ready){++busy_clocks;worst_busy=std::max(worst_busy,busy_clocks);}else busy_clocks=0;
    if(d.sample_valid){
        if(last_sample)require(clocks-last_sample==1944,"fixed sample cadence");last_sample=clocks;
        samples.emplace_back(int16_t(d.sample_left),int16_t(d.sample_right));++outputs;
    }
}
static void reset(){
    pending=false;fail_memory=false;last_irq_event=false;irq_events=0;forced_delay=0;last_sample=0;busy_clocks=0;samples.clear();d.reg_valid=0;d.reset=1;step();step();d.reset=0;
}
static void bus(unsigned address,uint32_t value,unsigned strobe,bool write){
    d.reg_address=address&~3u;d.reg_data=value;d.reg_strobe=strobe;d.reg_write=write;d.reg_valid=1;d.eval();
    uint64_t before=clocks;while(!d.reg_ready){require(clocks-before<4000,"MMIO completion timeout");step();d.eval();}
    step();d.reg_valid=0;d.eval();
}
static void write16(unsigned address,unsigned data,unsigned mask=65535){
    unsigned shift=(address&2)*8;unsigned strobes=((mask&255)?1:0)|((mask&65280)?2:0);
    bus(address,uint32_t(data)<<shift,strobes<<(shift/8),true);
}
// Channel registers 4..15 are block RAM: a read holds a valid request until reg_ready, which
// includes the RAM read cycle, then data is sampled at ready (same protocol as the board).
static uint32_t read32(unsigned address){
    const bool block_ram=address<0x400&&(address&0x1f)>=8; // halfword offsets 4..15
    if(!block_ram){d.reg_address=address;d.eval();return d.reg_read_data;} // flip-flop state: snapshot, no clock
    d.reg_address=address&~3u;d.reg_write=0;d.reg_strobe=15;d.reg_valid=1;d.eval();
    uint64_t before=clocks;while(!d.reg_ready){require(clocks-before<4000,"MMIO read timeout");step();d.eval();}
    uint32_t value=d.reg_read_data;step();d.reg_valid=0;d.eval();return value;
}
static unsigned read16(unsigned address){return (read32(address&~3u)>>((address&2)*8))&65535;}
static std::pair<int,int> next_sample(){uint64_t start=clocks;while(samples.empty()){require(clocks-start<4000,"sample timeout");step();}auto x=samples.front();samples.pop_front();return x;}
static int clip(int32_t value){return std::max(-32768,std::min(32767,int(value)));}
static void program(vr0sound_device&ref,unsigned ch,unsigned word,unsigned data,unsigned mask=65535){
    write16(ch*32+word*2,data,mask);ref.m_channel[ch].write(word,uint16_t(data),uint16_t(mask));
}
static void compare_frames(vr0sound_device&ref,unsigned count,const char*label){
    samples.clear();next_sample(); // documented one-sample scheduler latency
    for(unsigned i=0;i<count;++i){
        sound_stream expected;ref.render_audio(expected);auto got=next_sample();
        if(got.first!=clip(expected.left)||got.second!=clip(expected.right)){
            std::fprintf(stderr,"%s sample=%u RTL=%d/%d MAME=%d/%d\n",label,i,got.first,got.second,clip(expected.left),clip(expected.right));require(false,"stereo mix mismatch");
        }
        require(!d.underrun,"sample deadline");require(!d.memory_fault,"RAM response error");
        require(read32(0x404)==ref.m_status,"status bank layout16");
        require(read32(0x500)==ref.m_int_pend,"end pending32");require(bool(d.irq)==bool(ref.m_int_pend),"IRQ level");
        for(unsigned c=0;c<32;++c)for(unsigned w:{0u,1u,2u,3u})require(read16(c*32+w*2)==ref.m_channel[c].read(w),"runtime channel state");
    }
    std::printf("PASS %s: %u mixed sample frames, status=%08x pending=%08x\n",label,count,ref.m_status,ref.m_int_pend);
}
static void register_test(){
    reset();vr0sound_device ref;
    for(unsigned n=0;n<8192;++n){unsigned c=random32()%32,w=random32()%16,mask=(n%3==0)?255:(n%3==1)?65280:65535,data=random32()&65535;
        program(ref,c,w,data,mask);for(unsigned k=0;k<16;++k)require(read16(c*32+k*2)==ref.m_channel[c].read(k),"channel byte-write/read oracle");}
    require(read32(0x700)==0xffffffff,"unmapped reads");
    bus(0x480,0xa59c17e2,15,true);require(read32(0x480)==0xa59c17e2,"atomic high-bank mask32");
    bus(0x480,0x00120034,5,true);require(read32(0x480)==0xa5121734,"global mask byte lanes");
    for(unsigned c=0;c<32;++c)write16(0x404+(c&1)*2,0x8000|c);
    require(read32(0x404)==0xffffffff,"all32 status bits");
    for(unsigned c=0;c<32;c+=2)write16(0x406,c);
    require(read32(0x404)==0xaaaaaaaa,"status OFF commands");
    write16(0x40a,0x801f);require(read32(0x408)==0x80000000,"noteon channel31");
    write16(0x600,0xffff);require(read16(0x600)==0x1fff,"channel count mask");
    write16(0x412,0xffff);require(read16(0x412)==127,"reverb buffer address mask");
    bus(0x420,0xffffffff,15,true);require(read32(0x420)==0x0fff0fff,"buffer size12 masks");
    std::puts("PASS SPU MMIO: all32 channels, byte strobes, runtime field masks and global banks");
}
static void voices(unsigned mode,bool overflow,bool texture_mode=false){
    reset();vr0sound_device ref;ref.m_ctrl=32768;ref.m_max_chan=31;ref.m_chan_clk_num=29;
    write16(0x600,0x1f1d);write16(0x480,0x55aa);write16(0x482,0xaa55);ref.m_int_mask=0xaa5555aa;
    for(unsigned c=0;c<32;++c){
        for(unsigned w=0;w<16;++w)program(ref,c,w,0);
        program(ref,c,0,c*16);program(ref,c,2,0);program(ref,c,3,0x107f);
        program(ref,c,4,0x100);program(ref,c,5,mode<<8);
        program(ref,c,6,c*16);program(ref,c,7,0x7f00);program(ref,c,8,0x1000+c*16);program(ref,c,9,0x7f00);
        ref.m_channel[c].cache=texture_mode?&texture:&frame;write16(0x404,0x8000|c);ref.m_status|=1u<<c;
    }
    if(overflow)std::fill(frame.bytes.begin(),frame.bytes.end(),0x7f);
    else for(auto&x:frame.bytes)x=uint8_t(random32());
    if(texture_mode){for(auto&x:texture.bytes)x=uint8_t(random32());ref.m_ctrl|=32;}
    write16(0x602,ref.m_ctrl);compare_frames(ref,1024,overflow?"32-voice clamp":texture_mode?"32-voice texture sample selection":"32-voice random samples");
}
static void endings(){
    reset();vr0sound_device ref;ref.m_ctrl=32768;ref.m_max_chan=31;ref.m_chan_clk_num=29;
    write16(0x600,0x1f1d);
    write16(0x482,0x10);ref.m_int_mask=1u<<20;
    for(unsigned c:{0u,20u,31u}){
        program(ref,c,4,0x100);program(ref,c,3,0x107f);program(ref,c,5,0x2000);program(ref,c,8,0);program(ref,c,7,0x7f00);program(ref,c,9,0x7f00);
        ref.m_channel[c].cache=&frame;write16(0x406,0x8000|c);ref.m_status|=1u<<c;
    }
    write16(0x602,32768);compare_frames(ref,4,"voice-end break and channels20/31 IRQ");
    require(irq_events==2,"unmasked end event per channel, masked channel20 suppressed");
    write16(0x500,1);require(read32(0x500)==0x80000000&&d.irq,"partial W1C preserves other IRQ");
    write16(0x502,0x8000);require(read32(0x500)==0&&!d.irq,"high-bank W1C clears final IRQ");
}
static void real_coin(){
    reset();std::ifstream paths("sim/obj_dir/spu_reference/memory_paths.txt");std::string a,b;std::getline(paths,a);std::getline(paths,b);
    require(!a.empty()&&!b.empty(),"coherent fixture memory paths");
    for(auto item:{std::make_pair(&texture,a),std::make_pair(&frame,b)}){std::ifstream file(item.second,std::ios::binary);file.read(reinterpret_cast<char*>(item.first->bytes.data()),8388608);require(file.gcount()==8388608,"complete coherent RAM image");}
    vr0sound_device ref;ref.m_ctrl=32768;ref.m_max_chan=31;ref.m_chan_clk_num=29;
    std::ifstream input("sim/obj_dir/spu_reference/initial_voices.csv");std::string row;std::getline(input,row);
    while(std::getline(input,row)){std::stringstream s(row);std::string v;std::getline(s,v,',');unsigned c=std::stoul(v);std::getline(s,v,',');unsigned clock=std::stoul(v);std::getline(s,v,',');bool tex=std::stoul(v)!=0;
        require(clock==29,"fixture divider");for(unsigned w=0;w<16;++w){require(bool(std::getline(s,v,',')),"fixture channel words");program(ref,c,w,std::stoul(v,nullptr,16));}
        ref.m_channel[c].cache=tex?&texture:&frame;ref.m_status|=1u<<c;write16(0x404,0x8000|c);
    }
    auto&c=ref.m_channel[4];uint32_t stride=uint32_t(int32_t(c.ds_addr*(1998848/30))>>16);
    require(stride>0&&c.loop_end*1024u>c.cur_saddr,"finite first coin sample range");
    unsigned duration=(c.loop_end*1024u-c.cur_saddr+stride-1)/stride+2;
    require(duration<100000,"bounded first coin playback");
    write16(0x600,0x1f1d);write16(0x602,32768);compare_frames(ref,duration,"native first-coin complete sample playback");
    require(ref.m_status==0,"first coin voice reached real end");
    require(irq_events==1,"first coin sound-end interrupt event");
}
static void deadline_and_fault(){
    reset();for(unsigned b=0;b<4;++b)frame.bytes[b]=0x40;
    write16(0x600,0);write16(0x10,65535);write16(0x0a,0x2100);write16(0x06,0x007f);write16(0x0e,0x7f00);write16(0x12,0x7f00);write16(0x404,0x8000);write16(0x602,32768);
    forced_delay=2400;for(unsigned i=0;i<20000;++i)step();require(d.underrun,"delayed memory exposes missed deadline");
    {   // A late scan repeats the previous sample instead of stepping to zero (full-scale click).
        unsigned nonzero=0,dropouts=0;
        for(size_t i=1;i<samples.size();++i){
            if(samples[i].first||samples[i].second)++nonzero;
            else if(samples[i-1].first||samples[i-1].second)++dropouts;
        }
        require(nonzero>0,"late-scan fixture produces audible samples");
        require(dropouts==0,"late scan holds the previous sample");
    }
    reset();write16(0x600,0);write16(0x10,65535);write16(0x0a,0x2100);write16(0x404,0x8000);write16(0x602,32768);fail_memory=true;
    for(unsigned i=0;i<4000;++i)step();require(d.memory_fault,"RAM error sticky");
    reset();require(!d.memory_fault&&!d.underrun,"reset clears diagnostics");
    std::puts("PASS deadline violation, RAM error and reset diagnostics");
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);register_test();voices(0x21,false);voices(0x21,true);voices(0x51,false,true);voices(1,false);endings();real_coin();std::printf("PASS normal memory maximum scheduler busy=%u clocks /1944 sample period\n",worst_busy);require(worst_busy<1944,"normal memory scheduling budget");deadline_and_fault();std::printf("PASS SPU checks=%llu samples=%llu reads=%llu clocks=%llu\n",(unsigned long long)checks,(unsigned long long)outputs,(unsigned long long)requests,(unsigned long long)clocks);return 0;}
