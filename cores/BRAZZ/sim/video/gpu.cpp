// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvr0_gpu.h"
#include "verilated.h"
#include "../../sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp"
#include <iostream>
#include <stdexcept>
#include <string>
double sc_time_stamp(){return 0;}
static uint32_t rng=0xa52be917;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;return rng^=rng<<5;}
static unsigned checks=0;
static void check(bool b,const std::string& s){++checks;if(!b)throw std::runtime_error(s);}
struct Bench {
    Vvr0_gpu d;
    GpuMemory texture,frame;
    uint64_t clocks=0,requests=0,writes=0;
    std::vector<std::pair<u32,u16>> recorded_writes;
    bool record_writes=false;
    bool pending=false,error_next=false;
    unsigned delay=0;
    uint32_t reply=0;
    bool reply_error=false;
    // 32-byte line burst port (vr0_gpu <-> SDRAM backend model).
    bool bpending=false,bdone_now=false,berror=false;unsigned bdelay=0;uint32_t bdata[8]{};
    void burst_service(){
        // Called with clk low, before eval: present done/ready for this edge.
        d.burst_done=bdone_now;d.burst_error=berror&&bdone_now;
        for(unsigned i=0;i<8;i++)d.burst_rdata[i]=bdata[i];
        d.burst_ready=!bpending&&!bdone_now&&(random32()%3!=0);
    }
    bool b_accept=false,b_write=false,b_region=false;unsigned b_line=0,b_strobe=0;uint32_t b_wdata[8]{};
    void burst_capture(){
        // Clock low, after eval: the request the GPU presents to this rising edge.
        b_accept=d.burst_valid&&d.burst_ready;b_write=d.burst_write;b_region=d.burst_region;
        b_line=d.burst_line;b_strobe=d.burst_wstrobe;for(unsigned w=0;w<8;w++)b_wdata[w]=d.burst_wdata[w];
    }
    void burst_edge(){
        // After the rising edge: complete / accept.
        if(bdone_now){bdone_now=false;berror=false;}
        if(bpending){if(bdelay)--bdelay;else{bpending=false;bdone_now=true;}}
        if(b_accept){
            ++requests;
            GpuMemory* memory=b_region?&frame:&texture;
            unsigned base=(b_line<<5)&0x7fffff;
            berror=error_next;error_next=false;
            for(unsigned w=0;w<8;w++){
                unsigned off=(base+w*4)&0x7fffff;
                if(b_write){
                    unsigned strobe=(b_strobe>>(4*w))&15;uint32_t data=b_wdata[w];
                    if(strobe&&!berror){
                        check(strobe==3||strobe==12||strobe==15,"halfword pixel store");
                        for(unsigned lane=0;lane<4;lane+=2)if(strobe&(3u<<lane)){
                            ++writes;if(record_writes)recorded_writes.emplace_back((off+lane)&0x7fffff,uint16_t(data>>(8*lane)));
                        }
                        for(unsigned i=0;i<4;i++)if(strobe&(1<<i))memory->bytes[(off+i)&0x7fffff]=data>>(8*i);
                    }
                }else bdata[w]=memory->read_dword(off);
            }
            bpending=true;bdelay=random32()%24;
        }
    }
    void tick(){
        d.clk=0;burst_service();d.req_ready=!pending&&(random32()%4!=0);
        d.rsp_valid=pending&&delay==0;d.rsp_data=reply;d.rsp_error=reply_error;d.eval();burst_capture();
        bool accepted=d.req_valid&&d.req_ready;
        uint32_t a=d.req_address,data=d.req_data,strobe=d.req_strobe;
        bool w=d.req_write;
        if(pending){if(delay)--delay;else pending=false;}
        if(accepted){
            ++requests; check((a&3)==0,"unaligned GPU board request");
            GpuMemory* memory=nullptr;
            if(a>=0x03800000&&a<0x04000000)memory=&texture;
            else if(a>=0x04000000&&a<0x04800000)memory=&frame;
            else throw std::runtime_error("GPU request outside texture/frame map");
            unsigned off=a&0x7fffff;
            reply=memory->read_dword(off);reply_error=error_next;error_next=false;
            if(w&&!reply_error){++writes;if(record_writes){check(strobe==3||strobe==12,"halfword pixel store");unsigned lane=strobe==3?0:2;recorded_writes.emplace_back((off+lane)&0x7fffff,uint16_t(data>>(8*lane)));}for(unsigned i=0;i<4;i++)if(strobe&(1<<i))memory->bytes[(off+i)&0x7fffff]=data>>(8*i);}
            pending=true;delay=random32()%7;
        }
        d.clk=1;d.eval();burst_edge();++clocks;
    }
    void reset(){d.reg_valid=0;d.vblank=0;d.reset=1;tick();d.reset=0;pending=false;error_next=false;bpending=false;bdone_now=false;berror=false;}
    uint32_t reg(unsigned a,bool w=false,uint32_t data=0,unsigned strobe=15){
        d.reg_address=a;d.reg_write=w;d.reg_data=data;d.reg_strobe=strobe;d.reg_valid=1;
        for(unsigned n=0;;n++){
            tick();if(d.reg_rsp_valid)break;
            if(n>100000)throw std::runtime_error("GPU MMIO timeout");
        }
        check(!d.reg_rsp_error,"GPU MMIO error");d.reg_valid=0;
        return d.reg_rsp_data;
    }
    void submit(const std::array<u16,32>& p){
        unsigned rear=d.queue_rear;
        for(unsigned i=0;i<32;i++)texture.write_word(rear*64+i*2,p[i]);
        reg(0x80,true,(rear+1)&0x7ff,3);
        for(unsigned n=0;n<3000000;n++){
            tick();if(d.fault)throw std::runtime_error("GPU memory fault");
            if(!d.busy&&d.queue_rear==d.queue_front)return;
        }
        throw std::runtime_error("GPU packet timeout");
    }
    void blank(){d.vblank=1;tick();d.vblank=0;}
};
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    try {
        Bench b; b.reset();
        check(b.reg(0x100)==0xffffffff,"unmapped GPU read");
        b.reg(0x100,true,0x12345678);check(!b.d.busy,"unmapped write started rendering");
        b.reg(0x80,true,0x5ab,3);check(b.d.queue_front==0x5ab,"queue masked front");
        b.reg(0x80,true,0x00000100,2);check(b.d.queue_front==0x1ab,"queue high byte");
        b.reg(0x8c,true,8,1);check(b.reg(0x80)==0,"queue reset");
        b.reg(0x8c,true,4,1);
        b.reg(0x90,true,0x8000,3);check(b.reg(0x90)==0xffff8000,"bank1 mode");
        b.reg(0x90,true,0,1);check(b.reg(0x90)==0xffff0000,"bank1 low byte MAME handler");
        b.reg(0xa4,true,0x00010000,4);b.reg(0xa4,true,0x00010000,4);
        check(b.d.flip_count==2,"flip enqueue");b.blank();
        // No sync-flip packet has been rendered since reset, so this is software that flips without one
        // (evosocc/topbladv/officeye/urachamu): with the renderer idle and the queue drained, each vblank
        // takes one pending flip, as MAME execute_flipping does.
        check(b.d.flip_count==1&&b.d.display_bank==1&&!b.d.flip_sync,"drained queue without sync packets flips at vblank");
        b.blank();check(b.d.flip_count==0&&b.d.display_bank==0,"second pending flip at the next vblank");
        b.reset();b.reg(0x8c,true,4,1);
        b.reg(0x80,true,1,3);b.reg(0x8c,true,8,1);
        for(unsigned i=0;i<30;i++)b.tick();
        check(!b.d.busy&&!b.d.queue_front&&!b.d.queue_rear&&!b.d.packets_completed,"reset wins over a queued job starting on the same clock");
        b.reg(0x8c,true,4,1);
        for(unsigned i=0;i<b.texture.bytes.size();i++) b.texture.bytes[i]=random32();
        GpuMemory expected; vr0video_device oracle(b.texture,expected);
        const unsigned modes[]={0,1,2,4,8,16,0x21,0x22,0x24,0x28,0x30,3,0x23};
        unsigned packets=0;
        for(unsigned n=0;n<640;n++){
            // crysking writes render_control=0x06 (start + dither field 2) once at boot and
            // never again (scripts/mame_video_usage.lua). MAME ignores the dither field
            // (header: 1x = disabled), so every field value must render identically.
            if(n%64==0){
                const unsigned dither=(n/64)%4;
                b.reg(0x8c,true,4|dither,1);
                check((b.reg(0x8c)&0xffff)==(4u|dither),"render_control dither field readback");
            }
            std::array<u16,32> p{};
            p[0]=0x100|0x4000|0x0800|0x1000|0x2000|0x40;
            if(n<128 || n%11)p[0]|=8;
            if(n&8)p[0]|=2;if(n&32)p[0]|=4;if(n&16)p[0]|=16;if(n&64)p[0]|=32;
            p[1]=n%19;p[2]=(n/19)%13;p[3]=p[1]+1+n%7;p[4]=p[2]+1+n%4;
            if(n>=128 && n%3){p[0]|=0x200;p[5]=random32();p[6]=random32()&31;p[7]=random32();p[8]=random32()&31;}
            if(n>=128 && n%4){p[0]|=0x400;for(unsigned j=9;j<=16;j++)p[j]=(j&1)?random32():(random32()&31);}
            p[17]=random32();p[18]=(random32()&255)|(modes[n%13]<<8);
            p[19]=random32();p[20]=(random32()&255)|(modes[(n/13)%13]<<8);
            p[21]=random32();p[22]=random32();p[23]=random32();p[24]=random32();
            p[25]=0x100;p[26]=0x200;p[27]=0x400;
            p[28]=(n&3)<<6|((n/4)&15)<<8|((n&4)?0x1000:0)|(n%4)|((n/4)%4)<<3;
            if(n%9==8)p[0]&=~(0x0800|0x1000|0x2000|0x4000);
            if(n%17==0){p[5]=0xffff;p[6]=31;p[7]=0xffff;p[8]=31;}
            if(n%31==0)p[3]=p[1]?p[1]-1:0;
            for(unsigned j=0;j<32;j++)b.texture.write_word(b.d.queue_rear*64+j*2,p[j]);
            oracle.m_draw_dest=b.d.draw_address;
            int flip=oracle.process_packet(b.d.queue_rear*32);check(!flip,"unexpected test flip");
            b.submit(p);++packets;
            if(b.frame.bytes!=expected.bytes){
                unsigned off=0;while(b.frame.bytes[off]==expected.bytes[off])++off;
                throw std::runtime_error("packet "+std::to_string(n)+" control="+std::to_string(p[0])+" framebuffer byte="+std::to_string(off)+" RTL="+std::to_string(b.frame.bytes[off])+" MAME="+std::to_string(expected.bytes[off]));
            }
        }
        // MAME fixes quad.dest at packet dispatch. A vblank may change the
        // global draw bank while a long quad is still using the shared bus.
        {
            Bench flip; flip.reset(); flip.reg(0x8c,true,4,1);
            flip.reg(0x90,true,0x8000,3);
            // Sync-flip mode first (the crysking rule): render and release one sync-flip packet, so later
            // vblanks flip only once the render reaches a sync-flip packet; a pending flip request alone
            // then leaves the draw/display banks unchanged.
            {std::array<u16,32> sync{};sync[0]=1;flip.submit(sync);flip.reg(0xa4,true,0x00010000,4);flip.blank();}
            flip.reg(0x8c,true,8,1);flip.reg(0x8c,true,4,1); // queue reset (keeps the sync-flip mode)
            const unsigned bank0=flip.d.display_bank,draw0=flip.d.draw_address;
            flip.reg(0xa4,true,0x00010000,4); flip.blank();
            check(flip.d.draw_address==draw0&&flip.d.display_bank==bank0,"mid-quad fixture initial bank");
            flip.reg(0xa4,true,0x00010000,4);
            std::array<u16,32> fill{};
            fill[0]=0x1110; fill[1]=3; fill[2]=5; fill[3]=199; fill[4]=70;
            fill[21]=0x70e9; fill[22]=0xb2;
            for(unsigned j=0;j<32;j++)flip.texture.write_word(j*2,fill[j]);
            GpuMemory reference_frame; vr0video_device reference(flip.texture,reference_frame);
            reference.m_draw_dest=flip.d.draw_address;
            check(reference.process_packet(0)==0,"mid-quad fixture unexpected fence");
            flip.reg(0x80,true,1,3);
            bool changed_while_busy=false,completed=false;
            for(unsigned t=0;t<1000000;t++){
                flip.d.vblank=t==5000||t==10000;
                if(flip.d.vblank)check(flip.d.busy,"mid-quad vblank was outside rendering");
                flip.tick(); flip.d.vblank=0;
                if(t==5000){check(flip.d.draw_address==draw0&&flip.d.display_bank==bank0,"vblank during an unfinished frame must not flip");changed_while_busy=true;}
                if(t==10000)check(flip.d.draw_address==draw0&&flip.d.display_bank==bank0,"pending flips wait for the sync packet");
                if(flip.d.fault)throw std::runtime_error("mid-quad GPU memory fault");
                if(!flip.d.busy&&flip.d.queue_rear==flip.d.queue_front){completed=true;break;}
            }
            check(changed_while_busy&&completed,"mid-quad fixture did not finish after flips");
            check(flip.frame.bytes==reference_frame.bytes,"mid-quad bank flip split the MAME quad destination");
            std::cout<<"PASS GPU mid-frame vblank holds banks until sync flip: full 8 MiB matches MAME; "<<flip.writes<<" writes\n";
        }
        std::array<u16,32> p{};p[0]=1;
        b.submit(p);check(b.d.flip_sync,"sync fence");
        b.blank();check(b.d.flip_sync,"zero flip count holds the sync fence (MAME master)");
        b.reg(0xa4,true,0x00010000,4);b.blank();check(!b.d.flip_sync,"vblank with a flip count releases fence");
        // A sync-flip packet has now been rendered: from here a drained queue alone must not flip (crysking
        // raises its flip count before submitting the frame; a mid-frame drain would show a partial buffer).
        {const unsigned bank=b.d.display_bank;b.reg(0xa4,true,0x00010000,4);b.blank();check(b.d.display_bank==bank&&b.d.flip_count==1,"after sync-flip use a drained queue waits for the next sync packet");
         b.reg(0xa4,true,0x00000000,4);check(b.d.flip_count==0,"flip count clear");}
        p[0]=0x80;b.submit(p);check(b.d.draw_address==(b.d.display_bank?0x100000u:0u),"async front draw selection");
        for(unsigned n=b.d.queue_rear;n<2050;n++){p[0]=0;b.submit(p);}
        check(b.d.queue_rear==2,"queue wraps at 2048");
        b.error_next=true;b.reg(0x80,true,3,3);
        for(unsigned n=0;n<1000&&!b.d.fault;n++)b.tick();
        check(b.d.fault&&b.d.fault_address==0x03800080,"visible packet bus fault");
        std::cout<<"PASS GPU: "<<packets<<" MAME framebuffer comparisons; queue/MMIO/flips/fault; "<<checks<<" checks; "<<b.requests<<" bus requests; "<<b.writes<<" writes; "<<b.clocks<<" clocks\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL GPU: "<<e.what()<<"\n";return 1;}
}
