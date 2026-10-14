// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vcpu_ready_service_qualification.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
int main(int argc,char**argv){
 if(argc!=3)return 2;
 const int origin=std::stoi(argv[1]);std::ofstream trace(argv[2]);
 trace<<"tick,phase,address,status,sync,dbin,wr_n,ramstb_n,hread_n,q2,rdy_in,ready,wait,captured,event\n";
 Vcpu_ready_service_qualification t;std::array<unsigned char,65536> memory{};
 std::vector<unsigned char> p={0x31,0x00,0x41,0x3e,0x5a,0x32,0x00,0x40,
  0x3a,0x00,0x40,0xfe,0x5a,0xc2,0x80,0x00,0x3e,0xa5,0x32,0x01,0x40,
  0x21,0x00,0x40,0x46,0x23,0x4e,0x78,0xa9,0x32,0x02,0x40,
  0x22,0x10,0x40,0x2a,0x10,0x40,0xcd,0x70,0x00,
  0x3e,0x3c,0x32,0x20,0x40,0x76};
 std::copy(p.begin(),p.end(),memory.begin());memory[0x70]=0xc9;memory[0x80]=0x76;
 unsigned ticks=0,requests=0,first=0,second=0,wait_ticks=0,write_commits=0,ready_releases=0;
 unsigned simultaneous=0,read_services=0,write_services=0,waited_read=0,waited_write=0;
 bool last_ram=true,last_q2=false,last_rdy=false,last_ready=false,last_wr=true,last_wait=false;
 bool active=false,seen_first=false,seen_second=false,seen_wait=false;
 unsigned req_addr=0,req_status=0,last_addr=0;bool wait_address_stable=true;
 bool started=false,passed=false;unsigned released_tick=0;unsigned completed_tick=0;
 t.clk=0;t.reset=1;t.bus_data=0;t.eval();
 auto row=[&](const char*event){trace<<ticks<<','<<unsigned(t.phase)<<','<<t.address<<','<<unsigned(t.status)<<','<<unsigned(t.sync)<<','<<unsigned(t.dbin)<<','<<unsigned(t.wr_n)<<','<<unsigned(t.ramstb_n)<<','<<unsigned(t.hread_n)<<','<<unsigned(t.first_capture)<<','<<unsigned(t.rdy_in)<<','<<unsigned(t.ready)<<','<<unsigned(t.waiting)<<','<<unsigned(t.captured_data)<<','<<event<<'\n';};
 for(ticks=0;ticks<50000;++ticks){
  t.clk=0;t.bus_data=memory[t.address];t.eval();
  if(!started&&ticks>=150&&unsigned(t.phase)==unsigned(origin)){t.reset=0;started=true;released_tick=ticks;row("reset_release");}
  bool before_phi3=t.phi3_ttl;
  t.clk=1;t.eval();
  if(started){
   if(!t.ramstb_n&&last_ram){
    if(active&&!seen_second)throw std::runtime_error("new request before double capture");
    active=true;seen_first=seen_second=seen_wait=false;req_addr=t.address;req_status=t.status;++requests;row("request_clear");
   }
   if(t.first_capture&&!last_q2){seen_first=true;++first;row("first_capture");}
   if(t.rdy_in&&!last_rdy){if(active&&!seen_first)throw std::runtime_error("second flag without first");seen_second=true;++second;
    if(!before_phi3&&t.phi3_ttl)++simultaneous;row("second_capture");}
   if(t.waiting){++wait_ticks;seen_wait=true;if(last_wait&&last_addr!=t.address)wait_address_stable=false;}
   if(t.ready&&!last_ready){++ready_releases;row("ready_release");
    if(active&&seen_second){
     if(req_status&0x80){++read_services;if(seen_wait)++waited_read;}
     else if(!(req_status&2)){++write_services;if(seen_wait)++waited_write;}
     active=false;
    }
   }
   if(t.wr_n&&!last_wr&&last_addr&0x4000){memory[last_addr]=t.dout;++write_commits;row("synthetic_write_commit");}
   if(t.waiting!=last_wait)row(t.waiting?"wait_assert":"wait_release");
   if(memory[0x4020]==0x3c&&completed_tick==0)completed_tick=ticks;
   if(completed_tick&&ticks>completed_tick+100){passed=true;break;}
  }
  last_ram=t.ramstb_n;last_q2=t.first_capture;last_rdy=t.rdy_in;last_ready=t.ready;
  last_wr=t.wr_n;last_wait=t.waiting;last_addr=t.address;
 }
 bool memory_ok=memory[0x4000]==0x5a&&memory[0x4001]==0xa5&&memory[0x4002]==0xff&&memory[0x4010]==1&&memory[0x4011]==0x40&&memory[0x4020]==0x3c;
 bool pass=passed&&memory_ok&&wait_address_stable&&requests>=10&&wait_ticks>0&&read_services>=5&&write_services>=6&&waited_read>0&&waited_write>0;
 std::cout<<"{\"origin_phase\":"<<origin<<",\"ticks\":"<<ticks<<",\"reset_release_tick\":"<<released_tick<<",\"requests\":"<<requests<<",\"first_captures\":"<<first<<",\"second_captures\":"<<second<<",\"ready_releases\":"<<ready_releases<<",\"wait_ticks\":"<<wait_ticks<<",\"read_services\":"<<read_services<<",\"write_services\":"<<write_services<<",\"waited_reads\":"<<waited_read<<",\"waited_writes\":"<<waited_write<<",\"write_commits\":"<<write_commits<<",\"simultaneous_sampled_edges\":"<<simultaneous<<",\"wait_address_stable\":"<<(wait_address_stable?"true":"false")<<",\"memory_results_pass\":"<<(memory_ok?"true":"false")<<",\"pass\":"<<(pass?"true":"false")<<"}\n";
 t.final();return pass?0:1;
}
