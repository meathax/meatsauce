// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_scanout_load.h"
#include "verilated.h"
#include "../memory/sdram_model.hpp"
#include "../memory/ddr_model.hpp"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 bool expect_failure=argc>1 && std::string(argv[1])=="baseline";
 Vcs_scanout_load d;SdramModel s;DdrModel memory;
 auto check=[](bool x,const char*t){if(!x)throw std::runtime_error(t);};
 auto finish=[&](){memory.finish(d);d.sdram_data_in=s.tick(d.sdram_cke,d.sdram_cs_n,d.sdram_ras_n,d.sdram_cas_n,d.sdram_we_n,d.sdram_ba,d.sdram_address,d.sdram_dqm,d.sdram_data_out,d.sdram_data_oe);d.eval();};
 d.reset=1;for(unsigned i=0;i<4;i++){memory.prepare(d);finish();}d.reset=0;
 bool pending[2]={};uint64_t accepted[2]={},responses[2]={},begin[2]={},max_latency[2]={};
 unsigned frames=0;uint64_t pixels=0;bool failed=false;
 for(uint64_t clock=0;clock<6000000 && frames<3;clock++){
  d.peer_valid=frames ? (unsigned(!pending[0])|(unsigned(!pending[1])<<1)) : 0;
  uint32_t cpu=0x02000000+uint32_t((accepted[0]/8*0x1020+(accepted[0]%8)*4)&0x7ffffc);
  bool write=accepted[1]%17==0;
  uint32_t gpu=write?0x04400000+uint32_t((accepted[1]*4)&0x3ffffc):
       0x03800000+uint32_t(((accepted[1]/4*0x1040)+(accepted[1]%4)*4)&0x7ffffc);
  d.peer_address=(uint64_t(gpu)<<32)|cpu;d.peer_data=uint64_t(0x91827364)<<32;
  d.peer_strobe=0xff;d.peer_write=write?2:0;
  memory.prepare(d);
  bool take[2]={bool(d.peer_valid&d.peer_ready&1),bool(d.peer_valid&d.peer_ready&2)};
  bool reply[2]={bool(d.peer_rsp_valid&1),bool(d.peer_rsp_valid&2)};
  for(unsigned i=0;i<2;i++){
   if(reply[i]){check(pending[i],"lost peer response owner");check(!d.peer_rsp_error,"peer memory error");
    // CPU and texture reads address untouched RAM; writes affect the inactive framebuffer.
    if(i==0 || (accepted[i]-1)%17!=0)check(d.peer_rsp_data==0,"physical peer readback");
    ++responses[i];max_latency[i]=std::max(max_latency[i],clock-begin[i]);pending[i]=false;}
   if(take[i]){check(!pending[i],"second peer owner");pending[i]=true;begin[i]=clock;++accepted[i];}
  }
  if(d.video_tick&&d.video_de&&d.video_armed){++pixels;
   check(d.video_r==0&&d.video_g==0&&d.video_b==0,"inactive-bank writes leaked into displayed RAM");
   if(d.video_x==319&&d.video_y==239)++frames;}
  check(!d.video_fault,"scanout physical memory error");
  if(d.video_underrun){failed=true;break;}
  finish();
 }
 if(expect_failure)check(failed,"baseline did not reproduce display deadline violation");
 else check(!failed&&frames==3&&responses[0]>100&&responses[1]>100,"display deadline or peer liveness");
 std::cout<<(expect_failure?"PASS reproduced fair-arbiter video underrun":"PASS reserved display bandwidth")
   <<": frames="<<frames<<" pixels="<<pixels<<" peers="<<responses[0]<<"/"<<responses[1]
   <<" max service latency="<<max_latency[0]<<"/"<<max_latency[1]
   <<" SDRAM reads/writes/refresh="<<s.reads<<"/"<<s.writes<<"/"<<s.refreshes
   <<" clocks="<<memory.cycles<<"\n";return 0;
}catch(const std::exception&e){std::cerr<<"FAIL scanout load: "<<e.what()<<"\n";return 1;}}
