// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_ddr_share.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
#include <tuple>
double sc_time_stamp(){return 0;}
static void ck(bool x,const char*s){if(!x)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 Vcs_ddr_share d;unsigned rng=0x1938;auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
 auto edge=[&](){d.clk=1;d.eval();d.clk=0;d.eval();};d.reset=1;d.clk=0;d.eval();edge();d.reset=0;
 unsigned b=0,r=0,remaining=0,wait_b=0,wait_r=0,max_b=0,max_r=0,reads=0,writes=0,beats=0;
 bool held=false;std::tuple<unsigned,unsigned,unsigned,unsigned,unsigned,uint64_t> previous;
 for(unsigned cycle=0;cycle<500000 && (b<2000 || r<2000 || remaining);++cycle){
  bool board=b<2000,rotate=r<2000;
  d.board_rd=board && b%3==0;d.board_we=board && b%3!=0;
  d.board_addr=0x6000000+b*8;d.board_burst=d.board_rd?8:1;d.board_be=0xff;d.board_din=uint64_t(b)*0x123456789;
  d.rotate_we=rotate;d.rotate_addr=0x4800000+r;d.rotate_be=r&1?0xf0:0x0f;d.rotate_din=uint64_t(r)*0x987654321;
  d.DDRAM_BUSY=cycle<12 || random()%4==0;d.DDRAM_DOUT_READY=remaining && random()%3==0;d.eval();
  auto command=std::make_tuple(unsigned(d.DDRAM_RD),unsigned(d.DDRAM_WE),unsigned(d.DDRAM_ADDR),unsigned(d.DDRAM_BURSTCNT),unsigned(d.DDRAM_BE),uint64_t(d.DDRAM_DIN));
  if(held)ck(command==previous,"physical command changed under BUSY");
  bool physical=(d.DDRAM_RD||d.DDRAM_WE)&&!d.DDRAM_BUSY;
  bool ba=board&&!d.board_busy,ra=rotate&&!d.rotate_busy;
  ck(!(ba&&ra),"two owners accepted");ck(physical==(ba||ra),"acceptance ownership mismatch");
  if(remaining)ck(!physical && d.board_busy && d.rotate_busy,"new command before read drain");
  if(ba){ck(d.DDRAM_ADDR==0x6000000+b*8&&d.DDRAM_DIN==uint64_t(b)*0x123456789,"board payload");++b;max_b=std::max(max_b,wait_b);wait_b=0;}
  else if(board)++wait_b;
  if(ra){ck(d.DDRAM_WE&&!d.DDRAM_RD&&d.DDRAM_ADDR==0x4800000+r&&d.DDRAM_BURSTCNT==1,"rotation payload");++r;max_r=std::max(max_r,wait_r);wait_r=0;}
  else if(rotate)++wait_r;
  ck(wait_b<160&&wait_r<160,"owner starvation");
  held=(d.DDRAM_RD||d.DDRAM_WE)&&d.DDRAM_BUSY;previous=command;
  if(d.DDRAM_DOUT_READY){--remaining;++beats;}
  if(physical&&d.DDRAM_RD){remaining=8;++reads;}
  if(physical&&d.DDRAM_WE)++writes;
  edge();
 }
 ck(b==2000&&r==2000&&!remaining,"incomplete stress run");ck(beats==reads*8,"read beat ownership");
 std::cout<<"PASS DDR share: "<<b<<" board / "<<r<<" rotation commands; "<<reads<<" bursts / "<<beats<<" beats, max owner wait "<<max_b<<"/"<<max_r<<"; stalled commands stable\n";return 0;
}catch(const std::exception&e){std::cerr<<"FAIL DDR share: "<<e.what()<<"\n";return 1;}}
