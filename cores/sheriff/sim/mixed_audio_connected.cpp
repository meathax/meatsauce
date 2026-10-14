// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vmixed_audio_connected.h"
#include "verilated.h"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
struct Write{uint64_t tick;unsigned port,data;};
struct Pin{uint64_t tick;unsigned pc,p1,p2,dac;};
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);if(argc<7)return 2;
 std::ifstream rf(argv[1],std::ios::binary),io(argv[2]),pf(argv[3]),af(argv[4],std::ios::binary),sf(argv[5],std::ios::binary);
 std::vector<uint8_t>rom((std::istreambuf_iterator<char>(rf)),{});if(rom.size()!=0x4800)return 2;
 std::vector<Write>writes;std::vector<Pin>pins;std::string line;
 while(std::getline(io,line)){if(line.empty()||!isdigit(line[0]))continue;for(auto&c:line)if(c==',')c=' ';
 uint64_t tick;unsigned frame,y,x,address,data,status,inte;std::string kind;std::istringstream s(line);s>>tick>>frame>>y>>x>>kind>>address>>data>>status>>inte;
 if(kind=="out"&&((address&7)==4||(address&7)==5))writes.push_back({tick+1,address&7,data});}
 while(std::getline(pf,line)){if(line.empty()||!isdigit(line[0]))continue;for(auto&c:line)if(c==',')c=' ';Pin p;std::istringstream s(line);s>>p.tick>>p.pc>>p.p1>>p.p2>>p.dac;pins.push_back(p);}
 std::filesystem::path out=argv[6];std::filesystem::create_directories(out);
 std::ofstream raw(out/"current-audio.raw",std::ios::binary),ctl(out/"controls.csv");ctl<<"tick,mono0,mono1,enabled\n";
 Vmixed_audio_connected b;b.reset=1;b.sound1=0;b.sound2=0;b.load_wr=0;
 auto step=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
 for(unsigned a=0;a<0x4800;a++){b.load_wr=a>=0x4000&&a<0x4400;b.load_addr=a&1023;b.load_data=rom[a];step();}
 b.load_wr=0;for(unsigned i=0;i<1000;i++)step();b.reset=0;
 uint64_t samples=0,changed=0,starts=0,controls=0,pincount=0;size_t wi=0,pi=0;unsigned prev1=256,prev2=256,prevc=8;bool prev_enable=false;
 for(uint64_t tick=0;samples<1439875;tick++){
  while(wi<writes.size()&&writes[wi].tick==tick){const auto&w=writes[wi++];if(w.port==4)b.sound1=w.data;else b.sound2=w.data;}
  step();
  if(b.p1!=prev1||((b.p2^prev2)&0xf0)){if(pi>=pins.size())return 1;const auto&p=pins[pi++];
   if(p.tick!=tick||p.pc!=b.pc||p.p1!=b.p1||p.p2!=b.p2||p.dac!=b.dac){std::cerr<<"pin mismatch tick="<<tick<<" expected="<<p.tick<<" p1="<<unsigned(b.p1)<<" p2="<<unsigned(b.p2)<<" expected="<<p.p1<<","<<p.p2<<" pc="<<b.pc<<"/"<<p.pc<<std::endl;return 1;}
   prev1=b.p1;prev2=b.p2;pincount++;}
  unsigned c=b.mono0+2*b.mono1+4*b.enabled;if(c!=prevc){ctl<<tick<<','<<unsigned(b.mono0)<<','<<unsigned(b.mono1)<<','<<unsigned(b.enabled)<<'\n';prevc=c;controls++;}
  starts+=b.enabled&&!prev_enable;prev_enable=b.enabled;
  if(b.sample_ce){int16_t old,component;af.read((char*)&old,2);sf.read((char*)&component,2);if(!af||!sf)return 2;int16_t actual=b.current_audio;
   if(int16_t(b.old_audio)!=old||actual!=component+(b.dac?4915:0)){std::cerr<<"audio mismatch sample="<<samples<<" old="<<int16_t(b.old_audio)<<"/"<<old<<" new="<<actual<<" component="<<component<<" dac="<<unsigned(b.dac)<<std::endl;return 1;}
   raw.write((char*)&actual,2);changed+=old!=actual;samples++;}
  if(tick&&tick%50000000==0)std::cout<<"tick="<<tick<<" samples="<<samples<<std::endl;
 }
 std::ofstream result(out/"result.json");result<<"{\"samples\":"<<samples<<",\"old_board_identity_mismatches\":0,\"current_prediction_mismatches\":0,\"changed_samples\":"<<changed<<",\"exact_connected_pin_changes\":"<<pincount<<",\"control_changes\":"<<controls<<",\"envelope_enable_edges\":"<<starts<<",\"writes_consumed\":"<<wi<<"}\n";
 std::cout<<"PASS samples="<<samples<<" pins="<<pincount<<std::endl;return 0;
}
