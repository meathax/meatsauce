// SPDX-License-Identifier: GPL-3.0-or-later
// Production Sheriff descriptor with a synchronous RAM service model.
#include "Vhiscore.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <vector>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);if(argc!=2)return 2;Vhiscore b;
 std::ifstream cfg(argv[1],std::ios::binary);std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(cfg)),{});if(bytes.size()!=24)return 2;
 std::array<uint8_t,65536> ram{};ram[0x60f2]=0x21;uint8_t read_q=0;
 b.reset=1;b.paused=0;b.autosave=0;b.ioctl_upload=0;b.ioctl_download=0;b.ioctl_wr=0;b.ioctl_addr=0;b.ioctl_index=0;b.OSD_STATUS=0;b.data_from_hps=0;b.data_from_ram=0;
 unsigned writes=0;
 auto tick=[&](){
  b.paused=b.pause_cpu;b.data_from_ram=read_q;b.clk=0;b.eval();
  const unsigned addr=b.ram_address;const uint8_t old=ram[addr];
  if(b.ram_write){if(!b.paused){std::cerr<<"write without pause\n";std::exit(1);}ram[addr]=b.data_to_ram;writes++;}
  b.clk=1;b.eval();read_q=old;
 };
 tick();tick();
 auto download=[&](unsigned index,const std::vector<uint8_t>& data){
  b.ioctl_index=index;b.ioctl_download=1;b.ioctl_wr=0;tick();
  for(unsigned i=0;i<data.size();i++){b.ioctl_addr=i;b.data_from_hps=data[i];b.ioctl_wr=1;tick();b.ioctl_wr=0;tick();}
  b.ioctl_download=0;tick();for(unsigned i=0;i<16;i++)tick();
 };
 download(3,bytes);if(!b.configured){std::cerr<<"FAIL configuration\n";return 1;}
 download(4,{0,0x35,0});
 // The production wrapper holds reset through ROM/config/dump downloads and
 // releases it after 255 clocks. START_WAIT is armed at that falling edge.
 for(unsigned i=0;i<255;i++)tick();b.reset=0;tick();
 for(unsigned i=0;i<10000;i++)tick();
 if(writes){std::cerr<<"FAIL startup guard\n";return 1;}
 bool restored=false;
 for(unsigned i=0;i<50405000;i++){
  tick();if(ram[0x60f1]==0&&ram[0x60f2]==0x35&&ram[0x60f3]==0){restored=true;break;}
 }
 if(!restored){std::cerr<<"FAIL restore, writes="<<writes<<" data="<<unsigned(ram[0x60f2])<<'\n';return 1;}
 for(unsigned i=0;i<1000;i++)tick();
 // A legitimate game score update, followed by an OSD-open autosave request.
 ram[0x60f2]=0x56;b.autosave=1;b.OSD_STATUS=1;
 bool requested=false;for(unsigned i=0;i<10000;i++){tick();if(b.ioctl_upload_req){requested=true;break;}}
 if(!requested){std::cerr<<"FAIL autosave request\n";return 1;}
 b.ioctl_upload=1;b.ioctl_index=4;b.ioctl_addr=0;tick();
 std::array<unsigned,3> saved{};
 for(unsigned i=0;i<3;i++){b.ioctl_addr=i;tick();tick();saved[i]=b.data_to_hps;}
 b.ioctl_upload=0;tick();
 if(saved!=std::array<unsigned,3>{0,0x56,0}){std::cerr<<"FAIL upload data "<<saved[0]<<','<<saved[1]<<','<<saved[2]<<'\n';return 1;}
 std::cout<<"PASS production Sheriff config, startup guard, paused restore and changed-score autosave/upload; three bytes at 0x60f1\n";
 return 0;
}
