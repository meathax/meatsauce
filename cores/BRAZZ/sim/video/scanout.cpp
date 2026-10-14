// SPDX-License-Identifier: BSD-3-Clause
#include "Vvr0_scanout.h"
#include "Vvr0_scanout___024root.h"
#include "../boot/scanout_source.hpp"
#include "../boot/frame_capture.hpp"
#include <memory>
#include "verilated.h"
#include "../obj_dir/gpu_reference/vr0_gpu_reference.hpp"
#include <deque>
#include <cstdio>
#include <cstdlib>
#include <fstream>
static uint64_t clocks=0,checks=0,pixels=0,requests=0;
static uint32_t rng=0x913ea241;
double sc_time_stamp(){return double(clocks);}
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void require(bool value,const char*message){++checks;if(!value){std::fprintf(stderr,"FAIL scanout %s clock=%llu\n",message,(unsigned long long)clocks);std::exit(1);}}
struct Expected {unsigned x,y;bool de,hs,vs,hb,vb;uint16_t color;};
struct Bench {
    bool rot=false; // OSD Orientation Flipped: native 180-degree scanout
    Vvr0_scanout d;GpuMemory frame,texture;
    bitmap_ind16 bitmap;screen_device screen;
    std::deque<Expected> stream;
    unsigned width=320,height=240,htotal=455,vtotal=262,period=12,x=0,y=0,phase=0,number=0;
    unsigned delay=0,max_delay=9;bool pending=false,reply_error=false,inject_error=false,strict=true;
    uint32_t response=0,base=0;uint64_t checked_pixels=0,provenance_pixels=0;
    std::unique_ptr<CompleteFrameCapture> capture;
    Bench():bitmap(320,240){
        for(unsigned a=0;a<frame.bytes.size();a+=2)frame.write_word(a,uint16_t(((a/2)*0x9e37u)^((a/2)>>13)^0x1234u));
        const uint16_t edges[]={0xf800,0x07e0,0x001f,0xffff,0,0x39e7};for(unsigned i=0;i<6;++i)frame.write_word(i*2,edges[i]);
    }
    void reference(){bitmap=bitmap_ind16(width,height);vr0video_device ref(texture,frame);ref.m_display_dest=base;rectangle clip(0,int(width)-1,0,int(height)-1);ref.screen_update(screen,bitmap,clip);}
    void reset(){d.reset=1;d.restart=0;d.pixel_tick=0;d.req_ready=0;d.rsp_valid=0;d.clk=0;d.eval();d.clk=1;d.eval();++clocks;d.reset=0;pending=false;stream.clear();x=y=phase=number=0;checked_pixels=0;capture=std::make_unique<CompleteFrameCapture>(width,height);}
    void setup(unsigned w,unsigned h,uint32_t b=0){width=w;height=h;htotal=w+135;vtotal=h+22;base=b;reference();reset();}
    void change_base(uint32_t b){base=b;reference();}
    void tick(){
        d.clk=0;d.pixel_tick=phase==0;d.pixel_x=x;d.pixel_y=y;
        d.visible_width=width;d.visible_height=height;d.display_address=base;d.screen_blank=0;d.flip=rot;
        d.hblank=x>=width;d.vblank=y>=height;d.display_enable=!d.hblank&&!d.vblank;
        d.hsync=!(x>=width+10&&x<width+30);d.vsync=!(y>=height+2&&y<height+5);
        d.req_ready=!pending&&random32()%4!=0;d.rsp_valid=pending&&delay==0;d.rsp_data=response;d.rsp_error=reply_error;d.eval();
        bool accept=d.req_valid&&d.req_ready,reply=d.rsp_valid;
        if(d.pixel_tick){uint16_t color=d.display_enable?(rot?bitmap.pix(height-1-y,width-1-x):bitmap.pix(y,x)):0;stream.push_back({x,y,bool(d.display_enable),bool(d.hsync),bool(d.vsync),bool(d.hblank),bool(d.vblank),color});}
        if(accept){require(!pending,"single outstanding memory read");require(d.req_address>=0x04000000&&d.req_address<0x04800000,"framebuffer bus window");require(!(d.req_address&3)&&!d.req_write&&d.req_strobe==15,"aligned full word read");response=frame.read_dword(d.req_address&0x7fffff);++requests;}
#define S(field) d.rootp->vr0_scanout__DOT__##field
        auto source=scanout_source(S(pixel_pending),S(pending_de),S(pending_visible),S(pending_ready),S(pending_armed),
            S(pending_x),S(pending_y),S(pixel_word),S(pending_half),S(tag_y)[S(pending_y)&1],S(tag_base)[S(pending_y)&1]);
#undef S
        d.clk=1;d.eval();++clocks;
        if(pending){if(delay)--delay;else pending=false;}
        if(accept){pending=true;delay=1+random32()%max_delay;reply_error=inject_error;inject_error=false;}
        if(d.video_tick){
            source.verify(d);
            if(source.known&&!rot){
                require(source.color==frame.read_word((source.base+(source.y&511)*2048+source.x*2)&0x7fffff),"actual emitted word agrees with FIFO source bank and physical framebuffer");
                ++provenance_pixels;
            }
            if(d.video_de)capture->pixel(clocks,d.video_x,d.video_y,d.video_r,d.video_g,d.video_b,source.known?source.base:UINT32_MAX);
            require(!stream.empty(),"output tick has matching raster input");auto e=stream.front();stream.pop_front();
            require(d.video_x==e.x&&d.video_y==e.y,"pixel coordinate latency");
            require(bool(d.video_de)==e.de&&bool(d.video_hsync)==e.hs&&bool(d.video_vsync)==e.vs&&bool(d.video_hblank)==e.hb&&bool(d.video_vblank)==e.vb,"aligned DE/sync/blank");
            if(strict){uint16_t color=d.armed?e.color:0;require(d.video_r==pal5bit(color>>11)&&d.video_g==pal6bit(color>>5)&&d.video_b==pal5bit(color),"unchanged MAME screen pixel and RGB565 expansion");if(d.armed&&e.de){++pixels;++checked_pixels;}require(!d.underrun&&!d.memory_fault,"normal memory deadline/error");}
        }
        if(++phase==period){phase=0;if(++x==htotal){x=0;if(++y==vtotal){y=0;++number;}}}
    }
    void frames(unsigned count,bool flip=false){unsigned last=number+count;bool flipped=false;while(number<last){if(flip&&!flipped&&number==1&&y==height+1){change_base(0x400000);flipped=true;}tick();}require(d.armed&&checked_pixels>0,"scanout armed and real pixels checked");}
};
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);Bench b;
    for(auto wh:{std::pair<unsigned,unsigned>{1,3},{319,17},{320,240},{1024,515}}){b.setup(wh.first,wh.second,wh.first==1024?0x7ff000:0);b.frames(3);
      require(b.capture->completed&&b.capture->complete_unknown==0,"complete frame has no invented or missing FIFO sources");
      require(b.capture->complete_bases.size()==1&&b.capture->complete_bases.begin()->first==b.base&&b.capture->complete_bases.begin()->second==uint64_t(b.width)*b.height,"complete frame source-bank coverage");
      for(auto source:b.capture->complete_sources)require(source==b.base,"ordered per-pixel FIFO source map");
      std::printf("PASS scanout %ux%u base=%06x pixels=%llu\n",wh.first,wh.second,b.base,(unsigned long long)b.checked_pixels);}
    require(b.provenance_pixels>0,"real pending FIFO provenance exercised");
    b.setup(320,240,0x100000);b.frames(3,true);std::puts("PASS scanout vblank bank flip 1MiB to 4MiB");
    // Flip the programmed display base after a pixel enters the output pipeline.
    // That pixel must still name its old FIFO bank, even though the register is new.
    b.setup(320,17,0x100000);b.frames(2);b.strict=false;
    while(!(b.number==2&&b.y==2&&b.x==30&&b.phase==1))b.tick();
    auto before=b.provenance_pixels;b.change_base(0x400000);b.tick();
    require(b.provenance_pixels==before+1,"in-flight pixel retains old bank through midline base change");
    b.strict=true;std::puts("PASS scanout actual FIFO provenance across in-flight display-bank flip");
    std::ifstream native("sim/obj_dir/gpu_game/rtl_frame_after.bin",std::ios::binary);native.read(reinterpret_cast<char*>(b.frame.bytes.data()),b.frame.bytes.size());require(native.gcount()==int64_t(b.frame.bytes.size()),"complete native RTL-generated framebuffer");b.setup(320,240);b.frames(2);std::puts("PASS scanout native RTL game-draw framebuffer via unchanged MAME screen_update");
    b.setup(320,17);while(!b.pending)b.tick();b.delay=40;
    b.d.restart=1;b.tick();b.d.restart=0;
    b.frame.write_word(0,b.frame.read_word(0)^0xffff);b.reference();b.frames(3);
    std::puts("PASS scanout restart cancels delayed old prefetch and reloads changed framebuffer");
    // Native 180-degree flip: from the frame after the flip is sampled (start of the last visible line),
    // display pixel (x,y) must be MAME screen pixel (W-1-x, H-1-y).
    b.rot=true;b.setup(320,240);b.strict=false;
    {unsigned end=b.number+3;while(b.number<end)b.tick();} // flip sampled, scanout armed (no strict pixels yet)
    b.strict=true;b.frames(2);b.rot=false;
    std::puts("PASS scanout native 180-degree flip matches the rotated MAME screen");
    b.setup(1024,8);b.frames(2);b.strict=false;b.period=1;unsigned end=b.number+3;while(b.number<end)b.tick();require(b.d.underrun,"late memory/fast raster reports underrun");std::puts("PASS scanout deliberately insufficient memory bandwidth exposes underrun without slowing raster");
    b.setup(320,240);b.inject_error=true;for(unsigned i=0;i<1000;++i)b.tick();require(b.d.memory_fault,"memory response error sticky");b.reset();require(!b.d.memory_fault&&!b.d.underrun,"reset clears faults");
    b.d.visible_width=1025;b.d.eval();require(b.d.unsupported_geometry,"unsupported width exposed");
    std::printf("PASS scanout pixels=%llu requests=%llu checks=%llu clocks=%llu\n",(unsigned long long)pixels,(unsigned long long)requests,(unsigned long long)checks,(unsigned long long)clocks);return 0;
}
