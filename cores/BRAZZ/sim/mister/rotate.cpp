// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_screen_rotate.h"
#include "verilated.h"
#include <map>
#include <iostream>
#include <stdexcept>
#include <tuple>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{Vcs_screen_rotate d;std::map<unsigned,unsigned> memory;unsigned cycles=0,writes=0;
 bool held=false;std::tuple<uint32_t,uint64_t,uint8_t> held_command{};
 auto tick=[&](){d.clk=0;d.eval();auto command=std::make_tuple(uint32_t(d.ddram_addr),uint64_t(d.ddram_din),uint8_t(d.ddram_be));if(held&&!d.reset)ck(d.ddram_we&&command==held_command,"stable command through DDR BUSY");held=!d.reset&&d.ddram_we&&d.ddram_busy;held_command=command;if(d.ddram_we&&!d.ddram_busy){unsigned address=(d.ddram_addr<<3)+(d.ddram_be==0xf0?4:0);ck(d.ddram_be==0xf0||d.ddram_be==0x0f,"DWORD mask");memory[address]=unsigned(d.ddram_din);++writes;}d.clk=1;d.eval();++cycles;};
 auto reset=[&](){d.reset=1;d.ddram_busy=0;d.display_enable=0;d.ce_pix=0;d.frame_start=0;d.fb_vbl=0;d.direct_video=0;tick();d.reset=0;memory.clear();writes=0;};
 auto frame=[&](unsigned mode,bool busy){d.orientation=mode;for(unsigned y=0;y<6;y++)for(unsigned x=0;x<8;x++){d.ce_pix=1;d.frame_start=x==0&&y==0;d.display_enable=1;d.pixel_x=x;d.pixel_y=y;d.rgb=(x<<16)|(y<<8)|0x5a;d.ddram_busy=busy||((cycles%11)<5);tick();d.frame_start=0;d.ce_pix=0;d.display_enable=0;for(int n=0;n<3;n++){d.ddram_busy=busy||((cycles%11)<5);tick();}}d.ce_pix=0;d.display_enable=0;d.frame_start=0;d.ddram_busy=0;for(int n=0;n<32;n++)tick();};
 auto publish=[&](){d.fb_vbl=1;for(int n=0;n<5;n++)tick();d.fb_vbl=0;for(int n=0;n<5;n++)tick();};
 for(unsigned mode=1;mode<4;mode++){
  reset();frame(mode,false);ck(!d.fb_en,"wait for HDMI vblank");publish();ck(d.fb_en&&writes==48&&!d.overflow,"complete DDR frame");ck(d.fb_width==(mode==3?8:6)&&d.fb_height==(mode==3?6:8),"dimensions");unsigned base=d.fb_base,stride=d.fb_stride;
  for(unsigned y=0;y<6;y++)for(unsigned x=0;x<8;x++){unsigned dx=mode==1?5-y:mode==2?y:7-x,dy=mode==1?x:mode==2?7-x:5-y;unsigned address=base+dy*stride+dx*4;ck(memory.count(address)&&memory[address]==(0x5a0000|(y<<8)|x),"pixel orientation/BGR packing");}
  frame(mode,true);ck(d.overflow,"overflow diagnosed");publish();ck(d.fb_en&&d.fb_base==base,"retain previous complete frame on overflow");d.direct_video=1;d.eval();ck(!d.fb_en,"direct-video bypass");
 }
 reset();d.orientation=1;for(unsigned i=0;i<48;i++){d.ce_pix=1;d.frame_start=i==0;d.display_enable=1;d.pixel_x=i%8;d.pixel_y=i/8;d.rgb=(d.pixel_x<<16)|(d.pixel_y<<8)|0x5a;d.ddram_busy=i<8;tick();}d.ce_pix=0;d.frame_start=0;d.display_enable=0;d.ddram_busy=0;for(unsigned i=0;i<32;i++)tick();publish();ck(d.fb_en&&writes==48&&!d.overflow,"consecutive queued pop/push");for(unsigned y=0;y<6;y++)for(unsigned x=0;x<8;x++){unsigned a=d.fb_base+x*d.fb_stride+(5-y)*4;ck(memory.count(a)&&memory[a]==(0x5a0000|(y<<8)|x),"burst RAM head/bypass order");}
 reset();frame(0,false);publish();ck(!d.fb_en&&!writes,"native mode no DDR writes");std::cout<<"PASS rotation: "<<checks<<" checks; CW/CCW/180, DDR stalls/overflow, publication, queued burst and stable BUSY\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL rotation: "<<e.what()<<"\n";return 1;}
}
