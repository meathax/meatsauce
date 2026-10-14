// SPDX-License-Identifier: BSD-3-Clause
#include "Vvr0_crtc.h"
#include "verilated.h"
#include "../obj_dir/crtc_reference/crtc_reference.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <stdexcept>

static uint64_t clocks=0,checks=0; double sc_time_stamp(){return double(clocks);}
static Vvr0_crtc d; static vrender0soc_device ref;
static uint32_t lightc=0; // MAME master maps LIGHTC (0x48) separately: 2 bits, low-byte writes
static void require(bool x,const char*s){++checks;if(!x)throw std::runtime_error(s);}
static void tick(){d.clk=0;d.eval();d.clk=1;d.eval();++clocks;d.clk=0;d.eval();}
static void reset(){lightc=0;d.reg_valid=0;d.external_pixel_tick=0;d.reset=1;tick();d.reset=0;tick();ref=vrender0soc_device();ref.m_screen=&ref.screen;}
static uint32_t read(unsigned a){
    d.reg_valid=1;d.reg_write=0;d.reg_address=a;d.reg_strobe=15;
    ref.screen.x=d.pixel_x;ref.screen.y=d.pixel_y;ref.screen.frame=d.frame_number;
    // Light pen X/Y (0x38..0x44) read 0 without a light gun; LIGHTC is its own 2-bit register.
    uint32_t want=(a>=0x38&&a<0x48)?0:(a==0x48?lightc:ref.crtc_r(a/4));tick();require(d.reg_response,"missing MMIO response");
    uint32_t got=d.reg_result;d.reg_valid=0;tick();
    if(got!=want){std::printf("read %03x got %08x want %08x\n",a,got,want);throw std::runtime_error("register oracle mismatch");}
    ++checks;return got;
}
static void write(unsigned a,uint32_t v,unsigned strobe=15){
    uint32_t mask=0;for(unsigned i=0;i<4;++i)if(strobe&(1u<<i))mask|=255u<<(8*i);
    if(a==0x48){if(strobe&1)lightc=v&3;}else if(!(a>=0x38&&a<0x48))ref.crtc_w(a/4,v,mask);
    d.reg_valid=1;d.reg_write=1;d.reg_address=a;d.reg_data=v;d.reg_strobe=strobe;tick();d.reg_valid=0;tick();
    require(d.horizontal_total==ref.screen.h && d.vertical_total==ref.screen.v,"configured total oracle mismatch");
    require(d.horizontal_visible==ref.screen.hd && d.vertical_visible==ref.screen.vd,"configured display oracle mismatch");
}
static void all_registers(){for(unsigned a=0;a<1024;a+=4)read(a);}
static void mode(unsigned w,unsigned h,unsigned ht,unsigned vt,bool interlace,unsigned tim=0x8b){
    write(0,0);write(8,0x213b);write(12,w-1);write(16,0);write(20,0x3809);
    write(24,14);write(28,h);write(32,0x400|(ht-1));write(36,0x800|vt);
    write(48,interlace?0:1);write(4,tim);
}
struct Counts {uint64_t pixels=0,active=0,vblank=0,flips=0,frames=0;};
static Counts run_frames(unsigned n){
    Counts c;unsigned start=d.frame_number;
    while(unsigned(d.frame_number-start)<n){
        d.eval();bool pixel=d.pixel_tick;bool active=d.display_enable;
        tick();if(pixel){++c.pixels;if(active)++c.active;}
        c.vblank+=d.vblank_start;c.flips+=d.flip_tick;c.frames+=d.frame_start;
        require(d.irq_vblank==d.flip_tick,"IRQ/flip cadence differs");
    }return c;
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
    reset();require(d.horizontal_total==455 && d.vertical_total==262,"reset raster");all_registers();
    // Replay actual two-mode BIOS/game writes against unchanged MAME bodies.
    std::ifstream f("sim/obj_dir/crtc_reference/crtc.csv");require(bool(f),"missing capture");std::string line;std::getline(f,line);unsigned rows=0;
    while(std::getline(f,line)){std::vector<std::string> a;std::stringstream s(line);std::string v;while(std::getline(s,v,','))a.push_back(v);
        require(a.size()==7,"bad capture row");if(a[2]=="W"){
            uint32_t m=std::stoul(a[5],nullptr,16);unsigned st=0;for(unsigned i=0;i<4;++i)if(m&(255u<<(8*i)))st|=1u<<i;
            write(std::stoul(a[3],nullptr,16)-0x01803400,std::stoul(a[4],nullptr,16),st);all_registers();++rows;
        }
    }
    require(rows==36,"game write inventory changed");
    require(d.horizontal_total==455 && d.vertical_total==262 && d.horizontal_visible==320 && d.vertical_visible==240 && d.pixel_period==12 && !d.interlaced,"actual game raster");
    // Begin exactly at a frame boundary; check three complete real-rate frames.
    while(!d.frame_start)tick();uint64_t before=clocks;auto game=run_frames(3);
    require(clocks-before==uint64_t(3)*455*262*12,"real game frame clock deadline");
    require(game.pixels==uint64_t(3)*455*262 && game.active==uint64_t(3)*320*240,"visible pixel count");
    require(game.vblank==3 && game.flips==3,"progressive vblank/flip count");
    // Sync pulses must lie inside blanking with stable widths (direct video / CRT).
    {while(!d.frame_start)tick();unsigned vs_low_pixels=0,hs_low_pixels=0,hs_runs=0,lines=0;bool prev_hs=true;
     for(unsigned i=0;i<455u*262u*12u;++i){d.eval();bool pixel=d.pixel_tick;
        if(pixel){if(!d.hsync){++hs_low_pixels;require(d.hblank,"HSYNC outside horizontal blanking");}
                  if(!d.vsync){++vs_low_pixels;require(d.vblank,"VSYNC outside vertical blanking");}
                  if(prev_hs&&!d.hsync)++hs_runs;prev_hs=d.hsync;if(d.pixel_x==0)++lines;}
        tick();}
     require(lines==262,"line count for sync check");
     require(hs_runs==262 && hs_low_pixels==262u*34,"HSYNC: one 34-pixel (4.7 us) pulse per line");
     require(vs_low_pixels==3u*455,"VSYNC: one 3-line pulse per frame");}
    write(0,0x200);require(!d.display_enable && d.screen_blank,"screen blank flag");write(0,0);
    // Register protection and reserved/byte-mask behavior, independent oracle.
    write(0,0x100);for(unsigned a=4;a<40;a+=4){write(a,~0u);all_registers();}
    write(40,0x321);require(read(40)==0x321,"outside protected range");write(0,0);
    uint32_t rng=0x9183f32;for(unsigned i=0;i<256;++i){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
        unsigned a=(rng%256)*4;uint32_t v=rng;if(a==28)v=(rng%240)+1;
        write(a,v,(rng>>16)&15);all_registers();}
    // Compact interlace mode: vblank IRQ and flips only on selected frames.
    reset();mode(8,4,17,10,true);while(!d.frame_start)tick();auto fields=run_frames(4);
    require(fields.vblank==4 && fields.flips==2,"interlace half-rate IRQ");
    write(0,8);while(!d.frame_start)tick();fields=run_frames(4);require(fields.flips==2,"interlace field selection");
    // All internal divider choices, including TIM high-speed selection.
    for(unsigned fast=0;fast<2;++fast)for(unsigned div=0;div<8;++div){mode(8,4,17,10,false,8|(fast?128:0)|div);
        unsigned period=(fast?3:6)*(div+1);require(d.pixel_period==period,"pixel divider");while(!d.frame_start)tick();uint64_t t=clocks;auto c=run_frames(1);
        require(clocks-t==uint64_t(17)*15*period,"divider frame duration");require(c.active==32,"small active area");}
    // External clock selection consumes supplied final pixel ticks only.
    mode(8,4,17,10,false,0);unsigned x=d.pixel_x,y=d.pixel_y;for(unsigned i=0;i<100;++i)tick();require(d.pixel_x==x && d.pixel_y==y,"external clock must not free-run");
    d.external_pixel_tick=1;tick();d.external_pixel_tick=0;require(d.pixel_x==x+1,"external pixel tick");
    std::printf("PASS CRTC: %llu checks; 36 real game setup writes, masks/protection/reserved readback, 3 full 455x262 frames, divider/external clock and interlace IRQ; %llu clocks\n",(unsigned long long)checks,(unsigned long long)clocks);return 0;
}catch(const std::exception&e){std::fprintf(stderr,"FAIL %s after %llu clocks\n",e.what(),(unsigned long long)clocks);return 1;}}
