// SPDX-License-Identifier: GPL-2.0-or-later
// Actual platform pixel mapper and queued DDR writes, with a byte-lane sink.
#include "Vn8080_rotation.h"
#include "verilated.h"
#include <array>
#include <iostream>
#include <string>
#include <vector>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vn8080_rotation b;
 bool busy_profile=false,long_busy=false,cw=false;
 for(int n=1;n<argc;n++){
  if(std::string(argv[n])=="--cw")cw=true;
  if(std::string(argv[n])=="--busy")busy_profile=true;
  if(std::string(argv[n])=="--busy-long")long_busy=true;
 }
 b.RESET=1;
 b.CE_PIXEL=0;b.VGA_R=b.VGA_G=b.VGA_B=0;b.VGA_HS=b.VGA_VS=b.VGA_DE=0;
 b.rotate_ccw=!cw;b.no_rotate=0;b.flip=0;b.FB_VBL=0;b.FB_LL=0;b.DDRAM_BUSY=0;
 b.CLK_VIDEO=0;b.eval();b.CLK_VIDEO=1;b.eval();b.RESET=0;
 std::array<std::vector<unsigned>,3> memory;
 for(auto& bank:memory)bank.assign(224*256,~0u);
 unsigned x=0,y=240,phase=0,writes=0;
 uint64_t busy_cycles=0,stalled_cycles=0,request_losses=0;
 bool pending=false;uint64_t pending_data=0;unsigned pending_address=0,pending_be=0;
 for(uint64_t tick=0;tick<819200ULL*8;tick++) {
  b.CE_PIXEL=phase==0;
  if(b.CE_PIXEL){b.VGA_R=x;b.VGA_G=y;b.VGA_B=x^y;b.VGA_HS=x>=272&&x<304;b.VGA_VS=y>=248&&y<252;b.VGA_DE=x<256&&y>=16&&y<240;}
  // The HDMI reader has its own 60 Hz cadence, distinct from this 61.523 Hz
  // source. Coincident synthetic read/write swaps would exercise neither the
  // real asynchronous cadence nor all three platform framebuffer banks.
  b.FB_VBL=(tick%840000)>=112000&&(tick%840000)<124800;
  b.DDRAM_BUSY=(busy_profile && tick%257<31) || (long_busy && tick%65536<4096);
  busy_cycles+=b.DDRAM_BUSY;
  b.CLK_VIDEO=0;b.eval();
  if(tick>=819200ULL*4) {
   if(pending && (!b.DDRAM_WE || b.DDRAM_ADDR!=pending_address ||
       b.DDRAM_DIN!=pending_data || b.DDRAM_BE!=pending_be))request_losses++;
   pending=b.DDRAM_WE && b.DDRAM_BUSY;
   if(pending){pending_address=b.DDRAM_ADDR;pending_data=b.DDRAM_DIN;pending_be=b.DDRAM_BE;stalled_cycles++;}
  }
  if(b.DDRAM_WE&&!b.DDRAM_BUSY&&tick>=819200ULL*4) {
   unsigned bank=(b.DDRAM_ADDR>>20)&3;
   unsigned offset=((b.DDRAM_ADDR&0xfffff)<<3)+(b.DDRAM_BE==0xf0?4:0);
   unsigned data=b.DDRAM_BE==0xf0?b.DDRAM_DIN>>32:b.DDRAM_DIN;
   if(bank>=3||offset%4||offset/4>=memory[0].size()||b.DDRAM_BURSTCNT!=1||b.DDRAM_RD){std::cerr<<"FAIL DDR address/format\n";return 1;}
   memory[bank][offset/4]=data;writes++;
  }
  b.CLK_VIDEO=1;b.eval();
  if(b.overflow){std::cerr<<"FAIL rotation queue overflow at "<<tick<<'\n';return 1;}
  phase=(phase+1)%10;if(phase==0&&++x==320){x=0;y=(y+1)&255;}
 }
 if(!b.FB_EN||!b.video_rotated||b.FB_WIDTH!=224||b.FB_HEIGHT!=256||b.FB_STRIDE!=896||b.FB_FORMAT!=6){std::cerr<<"FAIL framebuffer geometry "<<b.FB_WIDTH<<'x'<<b.FB_HEIGHT<<" stride="<<b.FB_STRIDE<<'\n';return 1;}
 unsigned checked=0,errors=0;
 for(unsigned bank=0;bank<3;bank++)for(unsigned dy=0;dy<256;dy++)for(unsigned dx=0;dx<224;dx++) {
  unsigned sx=cw?dy:255-dy,sy=cw?239-dx:16+dx,expected=sx|(sy<<8)|((sx^sy)<<16);
  if(memory[bank][dy*224+dx]!=expected)errors++;
  checked++;
 }
  std::cout<<(cw?"CW rotation pixels=":"CCW rotation pixels=")<<checked<<" writes="<<writes<<" errors="<<errors
      <<" request_losses="<<request_losses<<" busy_cycles="<<busy_cycles<<" stalled_cycles="<<stalled_cycles
      <<" 224x256 stride896; DDR_BUSY="<<(long_busy?"4096/65536 bursts":busy_profile?"31/257 bounded stalls":"0")<<'\n';
  if(errors||request_losses||writes!=4*256*224)return 1;
 b.no_rotate=1;
 for(uint64_t tick=0;tick<819200ULL*4;tick++) {
  b.CE_PIXEL=phase==0;
  if(b.CE_PIXEL){b.VGA_HS=x>=272&&x<304;b.VGA_VS=y>=248&&y<252;b.VGA_DE=x<256&&y>=16&&y<240;b.FB_VBL=b.VGA_VS;}
  b.CLK_VIDEO=0;b.eval();b.CLK_VIDEO=1;b.eval();
  phase=(phase+1)%10;if(phase==0&&++x==320){x=0;y=(y+1)&255;}
 }
 if(b.FB_EN||b.video_rotated){std::cerr<<"FAIL native orientation bypass\n";return 1;}
 std::cout<<"PASS native orientation disables framebuffer\n";
 return 0;
}
