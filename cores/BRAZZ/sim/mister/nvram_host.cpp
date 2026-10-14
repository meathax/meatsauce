// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_nvram_host.h"
#include "verilated.h"
#include <array>
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static void ck(bool x,const char*s){if(!x)throw std::runtime_error(s);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 Vcs_nvram_host d;std::array<uint32_t,16> ram{};unsigned cycles=0,transactions=0,reads=0,writes=0,delay=0;bool pending=false;uint32_t reply=0;
 auto tick=[&](){
  d.clk=0;d.backup_ready=!pending && cycles%4!=0;d.backup_rsp_valid=pending && delay==0;d.backup_rsp_data=reply;d.eval();
  bool accept=d.backup_valid&&d.backup_ready,respond=d.backup_rsp_valid;
  unsigned addr=d.backup_address;uint32_t value=d.backup_data;unsigned lanes=d.backup_strobe;bool write=d.backup_write;
  d.clk=1;d.eval();d.clk=0;d.eval();++cycles;
  if(pending&&delay)--delay;
  if(respond)pending=false;
  if(accept){ck(addr<ram.size(),"backup range");reply=ram[addr];if(write){for(unsigned i=0;i<4;i++)if(lanes&(1u<<i))ram[addr]=(ram[addr]&~(255u<<(i*8)))|(value&(255u<<(i*8)));++writes;}else ++reads;
   pending=true;delay=2+cycles%7;++transactions;}
 };
 auto settle=[&](){unsigned limit=0;d.eval();while(d.ioctl_wait){ck(++limit<100,"host wait timeout");tick();}};
 d.memory_reset=1;tick();d.memory_reset=0;d.cpu_quiet=1;tick();
 d.ioctl_index=4;d.ioctl_download=1;tick();
 d.cpu_quiet=0;d.ioctl_addr=0;d.ioctl_dout=0xa5;d.ioctl_wr=1;tick();d.ioctl_wr=0;
 for(unsigned i=0;i<9;i++){tick();ck(!d.backup_valid && d.ioctl_wait && ram[0]==0,"restore retains token until CPU quiescent");}
 d.cpu_quiet=1;settle();
 for(unsigned i=1;i<64;i++){ck(!d.restore_reset,"no game reset during restore");settle();d.ioctl_addr=i;d.ioctl_dout=i^0xa5;d.ioctl_wr=1;tick();d.ioctl_wr=0;settle();}
 d.ioctl_addr=64;d.ioctl_wr=1;tick();d.ioctl_wr=0;d.ioctl_download=0;settle();tick();
 {unsigned seen=0;for(unsigned i=0;i<40;i++){tick();if(d.restore_reset)++seen;}
  ck(seen==16,"restore completion emits one bounded game-reset pulse");}
 for(unsigned i=0;i<64;i++)ck(((ram[i/4]>>(8*(i%4)))&255)==(i^0xa5),"actual SRAM restore bytes");
 ck(writes==64,"restore range ignored");
 // Game writes invalidate upload cache and trigger a save. Do not own another SRAM.
  d.nvram_written=1;d.osd_open=1;d.cpu_quiet=0;tick();
  ck(!d.pause_cpu&&!d.dirty,"save event captured before control");
  d.nvram_written=0;tick();tick();ck(d.pause_cpu&&d.dirty,"coincident write/OSD survives event pipeline (two register stages)");
  for(unsigned i=0;i<12;i++)tick();
 ck(d.pause_cpu&&!d.ioctl_upload_req&&d.dirty,"save waits for in-flight CPU operation");
 d.cpu_quiet=1;for(unsigned i=0;i<6;i++)tick();ck(d.ioctl_upload_req,"quiet save request");
 auto start=[&](){d.ioctl_addr=0;d.ioctl_upload=1;d.ioctl_rd=1;tick();d.ioctl_rd=0;tick();settle();ck(!d.ioctl_upload_req&&d.pause_cpu,"HPS upload prime");};
 auto send=[&](unsigned address){d.ioctl_addr=address;d.ioctl_rd=0;tick();settle();d.eval();ck(d.ioctl_din==(address^0xa5),"prefetched upload byte");
  // Actual hps_io consumes old DIN then advances addr and pulses rd.
  tick();d.ioctl_addr=address+1;d.ioctl_rd=1;tick();d.ioctl_rd=0;tick();};
 auto finish=[&](){d.ioctl_upload=0;d.ioctl_rd=0;tick();settle();tick();ck(!d.pause_cpu,"upload pause release");};
 auto request=[&](){d.osd_open=0;tick();d.osd_open=1;tick();for(unsigned i=0;i<7;i++)tick();ck(d.ioctl_upload_req,"dirty retry");};
 start();for(unsigned i=0;i<7;i++)send(i);finish();ck(d.dirty,"short upload stays dirty");
 request();start();send(1);for(unsigned i=0;i<64;i++)send(i);finish();ck(d.dirty,"reordered upload stays dirty");
 request();start();for(unsigned i=0;i<64;i++)send(i);finish();ck(!d.dirty,"complete real HPS upload clears dirty");
 d.osd_open=0;tick();d.osd_open=1;for(unsigned i=0;i<10;i++)tick();ck(!d.ioctl_upload_req,"unchanged SRAM does not resave");
 ck(reads>=16&&reads<55,"word prefetch reuse");
 std::cout<<"PASS NVRAM host: "<<writes<<" masked physical backup writes / "<<reads<<" prefetched reads; HPS prime/address advance, short/reordered/full upload, quiet snapshot; "<<cycles<<" clocks\n";return 0;
}catch(const std::exception&e){std::cerr<<"FAIL NVRAM host: "<<e.what()<<"\n";return 1;}}
