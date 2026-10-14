// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_flash_cmd.h"
#include "verilated.h"
#include <cstdio>
#include <stdexcept>
static uint64_t clocks=0;
double sc_time_stamp(){return double(clocks);}
int main(int argc,char** argv){
 Verilated::commandArgs(argc,argv);
 Vcs_flash_cmd d;
 auto check=[](bool b){if(!b)throw std::runtime_error("cartridge command/query mismatch");};
 auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();++clocks;};
 try {
  d.reset=1;d.reg_valid=0;d.flash_bank=0;tick();d.reset=0;
  check(d.command==0xff && !d.read_override && !d.reg_rsp_valid);
  unsigned cases=0;
  for(unsigned bank=0;bank<8;++bank)for(unsigned command=0;command<256;++command){
   d.flash_bank=bank;d.reg_write=1;d.reg_valid=1;d.reg_data=0xa5000000|command;tick();
   check(d.reg_rsp_valid && d.command==(0xa5000000|command) && bool(d.read_override)==(command!=255));
   d.reg_write=0;tick();
   uint32_t expected=command==0x90 ? (bank<3 ? 0x00180089u:0xffffffffu):0;
   check(d.reg_rsp_valid && d.reg_rsp_data==expected);
   d.reg_valid=0;tick();check(!d.reg_rsp_valid);++cases;
  }
  d.reset=1;tick();check(d.command==255 && !d.read_override && !d.reg_rsp_valid);
  std::printf("PASS cartridge command/query: %u command/bank combinations, three present 16MiB banks, absent-bank identity, FF normal-ROM selection, whole-word command replacement/reset; %llu clocks. Pinned MAME profile; no NOR programming claim.\n",cases,(unsigned long long)clocks);
  return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
