// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vaudio_pause_connected.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
using State=std::array<uint64_t,18>;
static State state(const Vaudio_pause_connected&b){return{b.sample,b.p1,b.p2,b.pc,b.dac,b.mono0,b.mono1,b.enabled,b.slf,b.vco,b.noise,b.ad,b.shot,b.duration0,b.duration1,b.rng,b.divider,uint64_t(b.accumulator)|(uint64_t(b.bits_state)<<6)};}
static void step(Vaudio_pause_connected&b){b.clk=0;b.eval();b.clk=1;b.eval();}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);if(argc<3)return 2;
 std::ifstream rf(argv[1],std::ios::binary);std::vector<uint8_t>rom((std::istreambuf_iterator<char>(rf)),{});if(rom.size()!=0x4800)return 2;
 Vaudio_pause_connected a,b;
 for(auto*p:{&a,&b}){p->reset=1;p->pause=0;p->sound1=0;p->sound2=0;p->load_wr=0;}
 for(unsigned n=0;n<0x4800;n++)for(auto*p:{&a,&b}){p->load_wr=n>=0x4000&&n<0x4400;p->load_addr=n&1023;p->load_data=rom[n];step(*p);}
 for(auto*p:{&a,&b}){p->load_wr=0;for(unsigned n=0;n<1000;n++)step(*p);p->reset=0;}
 const std::array<uint64_t,9> moments={5000,10001,30000,60003,90001,120003,200003,400000,30390000};
 const std::array<unsigned,9> lengths={1,1049,1050,1051,4097,65539,31,701,1053};
 uint64_t samples=0,paused=0,nonzero=0,pins=0,dac_edges=0;size_t pi=0;unsigned prev1=256,prev2=256,prevdac=0;bool saw0=false,saw1=false,sawboth=false,cancel=false,retrigger=false;
 for(uint64_t tick=0;tick<31000000;tick++){
  unsigned command=a.sound1;
  if(tick==10000)command=16;
  if(tick==60000)command=0;
  if(tick==60002)command=16;
  if(tick==90000)command=20;
  if(tick==120000)command=4;
  if(tick==120002)command=20;
  if(tick==200000)command=4;
  if(tick==200002)command=20;
  // pins[5]=~sound1[1] asserts the actual persistent 8035 interrupt.
  if(tick==300000)command=22;
  if(tick==500000)command=20;
  a.sound1=b.sound1=command;
  if(pi<moments.size()&&tick==moments[pi]){
   State frozen=state(b);b.pause=1;
   for(unsigned n=0;n<lengths[pi];n++){step(b);if(b.sample_ce||state(b)!=frozen){std::cerr<<"pause mismatch case="<<pi<<" offset="<<n<<" tick="<<tick<<std::endl;return 1;}}
   paused+=lengths[pi];b.pause=0;pi++;
  }
  step(a);step(b);
  if(state(a)!=state(b)||a.sample_ce!=b.sample_ce){std::cerr<<"resume mismatch tick="<<tick<<std::endl;return 1;}
  if(tick==60003)retrigger=a.duration1==30187079;
  if(tick==90001)cancel=a.mono0&&!a.mono1&&a.enabled;
  saw0|=a.mono0&&!a.mono1;saw1|=!a.mono0&&a.mono1;sawboth|=a.mono0&&a.mono1;
  if(a.p1!=prev1||((a.p2^prev2)&0xf0)){pins++;prev1=a.p1;prev2=a.p2;}
  dac_edges+=a.dac!=prevdac;prevdac=a.dac;
  if(a.sample_ce){samples++;nonzero+=int16_t(a.sample)!=0;}
 }
 if(pi!=moments.size()||!saw0||!saw1||!sawboth||!cancel||!retrigger||a.enabled||!nonzero||pins<4||!dac_edges)return 1;
 std::filesystem::path out=argv[2];std::filesystem::create_directories(out);std::ofstream report(out/"result.json");
 report<<"{\"ticks\":31000000,\"pause_cases\":"<<pi<<",\"paused_clocks\":"<<paused<<",\"compared_sample_events\":"<<samples<<",\"nonzero_samples\":"<<nonzero<<",\"MCU_port_transitions\":"<<pins<<",\"DAC_edges\":"<<dac_edges<<",\"pause_state_mismatches\":0,\"resume_state_mismatches\":0,\"mono0_cancellation\":true,\"mono1_retrigger\":true,\"overlap\":true,\"terminal_timers_idle\":true}\n";
 std::cout<<"PASS pause_cases="<<pi<<" samples="<<samples<<" nonzero="<<nonzero<<" pins="<<pins<<std::endl;return 0;
}
