#include "Vt48_probe_top.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <iterator>
#include <cstdint>
int main(int argc,char**argv){
 if(argc!=3)return 2;
 std::ifstream in(argv[1],std::ios::binary);
 std::vector<unsigned char> rom((std::istreambuf_iterator<char>(in)),{});
 if(rom.size()!=1024){std::cerr<<"Expected actual 1024-byte firmware\n";return 2;}
 std::ofstream trace(argv[2]);trace<<"tick,kind,address,data,control,halt,pc\n";
 Vt48_probe_top t;
 auto tick=[&](){t.clk=0;t.eval();t.clk=1;t.eval();};
 t.reset=1;t.coins_n=3;t.command_valid=0;t.load_we=1;
 for(unsigned i=0;i<1024;i++){t.load_addr=i;t.load_data=rom[i];tick();}
 t.load_we=0;for(int i=0;i<32;i++)tick();t.reset=0;
 unsigned bus=0,control=0,shared=0,irqs=0,halts=0,releases=0,outside=0;
 bool last_halt=false;
 auto event=[&](uint64_t cycle,const char*kind,unsigned addr,unsigned data){
  trace<<cycle<<","<<kind<<","<<addr<<","<<data<<","<<unsigned(t.control)<<","<<unsigned(t.main_halt)<<","<<unsigned(t.program_addr)<<"\n";
 };
 constexpr unsigned cycles=3500000;
 for(unsigned i=0;i<cycles;i++){
  t.command_valid=(i==480000 || i==1920000);
  t.command_read=(i==480000);t.command_addr=0;t.command_data=0x55;
  t.coins_n=(i>=2400000 && i<2640000)?2:3;
  tick();
  if(t.command_valid)event(i,"command",t.command_addr,t.command_read?255:t.command_data);
  if(t.bus_event){++bus;event(i,"bus",0,t.bus_data);}
  if(t.control_event){++control;event(i,"control",0,t.control);}
  if(t.shared_write){++shared;event(i,"shared",t.shared_addr,t.shared_data);}
  if(t.irq2){++irqs;event(i,"irq2",0,t.control);}
  if(t.main_halt!=last_halt){if(t.main_halt)++halts;else ++releases;event(i,"halt",0,t.main_halt);last_halt=t.main_halt;}
  if(t.program_addr>=1024)++outside;
 }
 const uint64_t expected=uint64_t(cycles)*9263750/48000000;
 std::cout<<"{\"cycles\":"<<cycles<<",\"oscillator_ticks\":"<<t.oscillator_ticks<<",\"expected_oscillator_ticks\":"<<expected<<",\"core_ticks\":"<<t.core_ticks<<",\"bus_writes\":"<<bus<<",\"control_writes\":"<<control<<",\"shared_writes\":"<<shared<<",\"irq2_events\":"<<irqs<<",\"halts\":"<<halts<<",\"releases\":"<<releases<<",\"outside_internal_rom_ticks\":"<<outside<<"}\n";
 t.final();return t.oscillator_ticks==expected ? 0:2;
}
