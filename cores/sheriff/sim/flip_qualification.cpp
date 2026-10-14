// SPDX-License-Identifier: GPL-2.0-or-later
// Real board CPU and native renderer; isolated sound ports are fixed by the unit fixture.
#include "Vn8080_board.h"
#include "verilated.h"
#include <iostream>
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);Vn8080_board b;
 auto tick=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
 b.reset=1;b.pause=1;b.flip_screen=0;b.debug_req=0;b.debug_freeze=0;b.debug_wr=0;b.load_wr=0;b.input0=b.input1=b.input2=0;b.input3=0xfc;tick();
 b.load_wr=1;
 for(unsigned a=0;a<1024;a++){b.load_addr=0x4400+a;b.load_data=(a^(a>>5))&7;tick();}
 b.load_wr=0;b.reset=0;b.debug_req=1;b.debug_wr=1;
 for(unsigned a=0;a<8192;a++){b.debug_addr=a;b.debug_dout=(a*29)^(a>>4);tick();}
 b.debug_wr=0;b.debug_req=0;
 for(unsigned game=0;game<2;game++)for(unsigned user=0;user<2;user++){
  b.reset=1;b.load_wr=1;unsigned program[]={0x3e,game?0x20u:0u,0xd3,6,0x76};
  for(unsigned a=0;a<5;a++){b.load_addr=a;b.load_data=program[a];tick();}
  b.load_wr=0;b.pause=0;b.flip_screen=user;
  for(unsigned t=0;t<255;t++)tick();b.reset=0;
  for(unsigned t=0;t<10000;t++)tick();
  if(b.flip!=game){std::cerr<<"FAIL OUT6 flip "<<unsigned(b.flip)<<" expected "<<game<<" pc "<<b.cpu_address<<"\n";return 1;}b.pause=1;unsigned checked=0;
  uint64_t last_ce=0,last_vs=0;bool prior_vs=b.vsync;
  for(uint64_t t=0;t<819200*2;t++){
   tick();
   if(b.ce_pixel){if(last_ce&&t-last_ce!=10)return 2;last_ce=t;
    if(!b.hblank&&!b.vblank){unsigned x=b.pixel_x^(game^user?255:0),y=b.pixel_y^(game^user?255:0);
     unsigned a=y*32+x/8,byte=((a*29)^(a>>4))&255,p=y/8*32+x/8;
     unsigned expected=((byte>>(x%8))&1)?((p^(p>>5))&7):0;
     if(b.rgb!=expected){std::cerr<<"FAIL flip pixel "<<game<<' '<<user<<' '<<b.pixel_x<<' '<<unsigned(b.pixel_y)<<"\n";return 3;}checked++;
    }
   }
   if(b.vsync&&!prior_vs){if(last_vs&&t-last_vs!=819200)return 4;last_vs=t;}prior_vs=b.vsync;
  }
  if(checked!=256*224*2)return 5;
  std::cout<<"PASS game flip "<<game<<" user flip "<<user<<" pixels "<<checked<<" native pixel /10, frame 819200 clocks, 61.5234375 Hz\n";
 }

 b.reset=1;b.pause=0;b.load_wr=1;
 unsigned dip_program[]={0xdb,4,0xc3,0,0};
 for(unsigned a=0;a<5;a++){b.load_addr=a;b.load_data=dip_program[a];tick();}
 b.load_wr=0;for(unsigned t=0;t<255;t++)tick();b.reset=0;
 unsigned reads=0;
 for(unsigned lives=0;lives<4;lives++)for(unsigned cabinet=0;cabinet<2;cabinet++)for(unsigned unused=0;unused<32;unused++){
  unsigned expected=(cabinet?0:0x80)|((31-unused)<<2)|lives;
  b.input3=expected;bool read=false;
  for(unsigned t=0;t<2000;t++){tick();if(b.cpu_read&&(b.cpu_status&0x40)&&(b.cpu_address&7)==4){read=true;if(b.cpu_din!=expected)return 6;break;}}
  if(!read)return 7;reads++;
 }
 std::cout<<"PASS 256 actual 8080 IN4 DIP-port reads including lives, cabinet and unused switch positions"<<std::endl;
}
