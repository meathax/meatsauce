// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcpu_dram_service_qualification.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);if(argc<4)return 2;
 const unsigned origin=std::stoul(argv[1]);
 VerilatedContext context;context.randSeed(1);
 Vcpu_dram_service_qualification t{&context};
 std::array<unsigned char,65536> rom{};
 std::array<unsigned char,16384> committed{};
 std::array<bool,16384> written{};
 // Same ordinary instruction fixture as cpu_ready_service_qualification.cpp.
 std::vector<unsigned char> p={0x31,0x00,0x41,0x3e,0x5a,0x32,0x00,0x40,
  0x3a,0x00,0x40,0xfe,0x5a,0xc2,0x80,0x00,0x3e,0xa5,0x32,0x01,0x40,
  0x21,0x00,0x40,0x46,0x23,0x4e,0x78,0xa9,0x32,0x02,0x40,
  0x22,0x10,0x40,0x2a,0x10,0x40,0xcd,0x70,0x00,
  0x3e,0x3c,0x32,0x20,0x40,0x76};
 std::copy(p.begin(),p.end(),rom.begin());rom[0x70]=0xc9;rom[0x80]=0x76;
 std::ofstream trace(argv[2]);
 trace<<"tick,phase,address,status,sync,dbin,wr_n,raw_ras_n,raw_cas_n,comadr_n,hread_n,ras_n,cas_n,we_n,mux_address,do_valid,do_data,read_address,commit_address,commit_data,q2,rdy_in,ready,wait,event\n";
 unsigned ticks=0,requests=0,first=0,second=0,wait_ticks=0,write_commits=0;
 unsigned read_services=0,write_services=0,valid_read_captures=0,read_requests=0;
 unsigned unsupported=0,ignored=0,completed_tick=0,released_tick=0;
 bool last_ram=true,last_q2=false,last_rdy=false,last_ready=false,last_wait=false;
 bool active=false,seen_first=false,seen_second=false,started=false,passed=false;
 bool wait_address_stable=true;unsigned req_addr=0,req_status=0,last_addr=0;
 std::string failure;
 auto row=[&](const char*event) {
  trace<<ticks<<','<<unsigned(t.phase)<<','<<t.address<<','<<unsigned(t.status)<<','<<unsigned(t.sync)<<','<<unsigned(t.dbin)<<','<<unsigned(t.wr_n)
   <<','<<unsigned(t.raw_ras_n)<<','<<unsigned(t.raw_cas_n)<<','<<unsigned(t.comadr_n)<<','<<unsigned(t.hread_n)
   <<','<<unsigned(t.ras_n)<<','<<unsigned(t.cas_n)<<','<<unsigned(t.we_n)<<','<<unsigned(t.mux_address)
   <<','<<unsigned(t.do_valid)<<','<<unsigned(t.do_data)<<','<<t.requested_read_address
   <<','<<t.committed_address<<','<<unsigned(t.committed_data)<<','<<unsigned(t.first_capture)<<','<<unsigned(t.rdy_in)
   <<','<<unsigned(t.ready)<<','<<unsigned(t.waiting)<<','<<event<<'\n';
 };
 auto require=[&](bool ok,const char*why) {
  if(!ok){row("assertion_failure");throw std::runtime_error(std::string(why)+" tick="+std::to_string(ticks));}
 };
 t.clk=0;t.reset=1;t.rom_data=0;t.cpu_wr_rd_level=1;
 t.physical_h_byte=19;t.physical_v=166;t.eval();
 try {
  for(ticks=0;ticks<50000;ticks++) {
   t.clk=0;t.rom_data=rom[t.address];t.eval();
   if(!started&&ticks>=150&&unsigned(t.phase)==origin) {
    t.reset=0;started=true;released_tick=ticks;row("reset_release");
   }
   const bool before_valid=t.do_valid;
   const unsigned before_data=t.do_data,before_read_address=t.requested_read_address;
   t.clk=1;t.eval();context.timeInc(1);
   if(started) {
    unsupported+=t.unsupported_event;ignored+=t.ignored_cas_event;
    require(!t.unsupported_event,"unsupported RAS/CAS or WE/CAS ordering");
    if(t.read_event){read_requests++;row("storage_read_request");}
    if(t.write_event) {
     require((t.committed_cpu_address&0x4000)&&!t.committed_cpu_wr_n,
             "write without raw CPU RAM write");
     require(t.committed_address==(t.committed_cpu_address&0x3fff),
             "latched row/column differs from CPU write address");
     committed[t.committed_address]=t.committed_data;written[t.committed_address]=true;
     write_commits++;row("storage_write_commit");
     if(t.committed_address==0x20&&t.committed_data==0x3c&&!completed_tick)completed_tick=ticks;
    }
    if(!t.ramstb_n&&last_ram) {
     require(!active||seen_second,"new request before second capture");
     active=true;seen_first=seen_second=false;req_addr=t.address;req_status=t.status;
     requests++;row("request_clear");
    }
    if(t.first_capture&&!last_q2) {
     seen_first=true;first++;row("first_capture");
     if(active&&(req_status&0x80))require(before_valid,"first RAM-read capture lacks DO valid");
    }
    if(t.rdy_in&&!last_rdy) {
     require(!active||seen_first,"second capture without first");
     seen_second=true;second++;row("second_capture");
     if(active&&(req_status&0x80)) {
      require(before_valid,"second RAM-read capture lacks DO valid");
      require(before_read_address==(req_addr&0x3fff),"second capture belongs to another address");
      require(written[req_addr&0x3fff],"read of unseeded fixture byte");
      require(before_data==committed[req_addr&0x3fff]&&t.captured_data==before_data,
              "captured DO differs from actual committed data");
      valid_read_captures++;
     }
    }
    if(t.waiting) {
     wait_ticks++;if(last_wait&&last_addr!=t.address)wait_address_stable=false;
    }
    if(t.ready&&!last_ready&&active&&seen_second) {
     if(req_status&0x80)read_services++;
     else if(!(req_status&2))write_services++;
     active=false;row("ready_release");
    }
    if(t.waiting!=last_wait)row(t.waiting?"wait_assert":"wait_release");
    if(completed_tick&&ticks>completed_tick+100&&t.wr_n&&!t.waiting&&!active){passed=true;break;}
   }
   last_ram=t.ramstb_n;last_q2=t.first_capture;last_rdy=t.rdy_in;last_ready=t.ready;
   last_wait=t.waiting;last_addr=t.address;
  }
  require(passed,"ordinary fixture did not reach marker");
 } catch(const std::exception&e) {failure=e.what();}
 const bool memory_ok=written[0]&&committed[0]==0x5a&&written[1]&&committed[1]==0xa5&&
  written[2]&&committed[2]==0xff&&written[0x10]&&committed[0x10]==1&&
  written[0x11]&&committed[0x11]==0x40&&written[0x20]&&committed[0x20]==0x3c;
 const bool pass=failure.empty()&&passed&&memory_ok&&wait_address_stable&&
  requests>=10&&read_services>=5&&write_services>=6&&valid_read_captures>=5&&write_commits>=8;
 std::ofstream out(argv[3]);
 out<<"{\"origin_phase\":"<<origin<<",\"ticks\":"<<ticks<<",\"reset_release_tick\":"<<released_tick
  <<",\"requests\":"<<requests<<",\"first_captures\":"<<first<<",\"second_captures\":"<<second
  <<",\"read_services\":"<<read_services<<",\"write_services\":"<<write_services
  <<",\"valid_RAM_read_captures\":"<<valid_read_captures<<",\"wait_ticks\":"<<wait_ticks
  <<",\"storage_read_requests\":"<<read_requests<<",\"storage_write_commits\":"<<write_commits
  <<",\"ignored_CAS_events\":"<<ignored<<",\"unsupported_events\":"<<unsupported
  <<",\"wait_address_stable\":"<<(wait_address_stable?"true":"false")
  <<",\"memory_results_pass\":"<<(memory_ok?"true":"false")<<",\"pass\":"<<(pass?"true":"false")<<"}\n";
 std::cout<<(pass?"PASS ":"FAIL ")<<"origin="<<origin<<" ticks="<<ticks
  <<" actualWrites="<<write_commits<<" validReadCaptures="<<valid_read_captures<<'\n';
 if(!failure.empty())std::cerr<<failure<<'\n';
 t.final();return pass?0:1;
}
