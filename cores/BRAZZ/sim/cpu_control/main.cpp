// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vse3208.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
static uint64_t clocks=0;
double sc_time_stamp() { return double(clocks); }
static void check(bool good,const char* why) { if(!good)throw std::runtime_error(why); }
static uint32_t rng() {static uint32_t s=0x3208fc65;s^=s<<13;s^=s>>17;s^=s<<5;return s;}
struct Bench {
 Vse3208 d;
 std::array<uint8_t,512> memory{};
 bool mp=false,cp=false,error=false,immediate=false,held=false;
 unsigned md=0,cd=0,accepted=0;
 uint32_t mdata=0,value=0;
 uint16_t word=0;
 uint64_t held_tuple=0;
 std::array<uint32_t,8> before{};
 uint32_t sr=0,sp=0,er=0;
 void half(unsigned a,uint16_t v) {memory[a]=v;memory[a+1]=v>>8;}
 uint64_t tuple() const {return uint64_t(d.cp_req_data)|(uint64_t(d.cp_req_register)<<32)|(uint64_t(d.cp_req_id)<<35)|(uint64_t(d.cp_req_write)<<37);}
 void reset(uint16_t op,bool fail,bool fast) {
  word=op;error=fail;immediate=fast;accepted=0;held=false;mp=cp=false;
  memory.fill(0);memory[1]=1;
  half(0x100,0xe812);half(0x102,0xe95a);half(0x104,word);half(0x106,0xffff);
  d.reset=1;d.irq=0;d.nmi=0;d.irq_vector=0;d.state_load=0;
  d.state_pc=0;d.state_sr=0;d.state_sp=0;d.state_er=0;
  for(unsigned i=0;i<8;++i)d.state_registers[i]=0;
  for(unsigned i=0;i<3;++i)tick();d.reset=0;
 }
 void tick() {
  d.clk=0;d.ce=rng()%5!=0;d.req_ready=rng()%4!=0;d.rsp_error=0;
  d.rsp_valid=mp && md==0;d.rsp_data=mdata;
  d.cp_req_ready=rng()%4!=0;d.cp_rsp_valid=cp && cd==0;
  d.cp_rsp_data=value;d.cp_rsp_error=error;d.eval();
  bool mr=d.rsp_valid,ma=d.req_valid && d.req_ready && !d.reset;
  bool ca=d.cp_req_valid && d.cp_req_ready && !d.reset;
  if(held && !d.reset)check(d.cp_req_valid && tuple()==held_tuple,"unstable stalled CP request");
  held=d.cp_req_valid && !d.cp_req_ready && !d.reset;held_tuple=tuple();
  if(ca) {
   check(!cp && accepted==0,"duplicate CP request");
   check(d.cp_req_id==((word>>8)&3) && d.cp_req_register==(word&7),"wrong CP selector");
   check(d.cp_req_write==!(word&8),"wrong CP direction");
   check(d.cp_req_data==0x12,"implicit R0 payload missing");
   for(unsigned i=0;i<8;++i)before[i]=d.registers[i];
   sr=d.sr;sp=d.sp;er=d.er;value=rng();++accepted;
   if(immediate) {d.cp_rsp_valid=1;d.cp_rsp_data=value;d.eval();}
  }
  bool cr=d.cp_rsp_valid && d.cp_rsp_ready && !d.reset;
  unsigned address=d.req_address;
  if(ma)check(!mp && !d.req_write && address+3<memory.size(),"unexpected memory request");
  d.clk=1;d.eval();++clocks;
  if(mr)mp=false;else if(mp && md)--md;
  if(ma) {mdata=0;for(unsigned i=0;i<4;++i)mdata|=uint32_t(memory[address+i])<<(8*i);mp=true;md=rng()%5;}
  if(cr)cp=false;else if(cp && cd)--cd;
  if(ca && !immediate) {cp=true;cd=1+rng()%7;}
 }
 void run() {
  bool done=false;
  for(unsigned i=0;i<1000 && !done;++i) {
   tick();
   if(error && d.fault) {check(d.fault_pc==0x104 && d.fault_opcode==word && !d.retire,"wrong CP fault");done=true;}
   else if(d.retire && d.retire_pc==0x104) {check(!error && !d.fault,"error transfer retired");done=true;}
   else check(!d.fault,"fault before CP reply");
  }
  check(done && accepted==1,"CP completion timeout");
  for(unsigned i=0;i<8;++i) {
   uint32_t expected=before[i];if(i==0 && (word&8) && !error)expected=value;
   check(d.registers[i]==expected,"wrong CP register effect");
  }
  check(d.sr==sr && d.sp==sp && d.er==er && d.pc==0x106,"wrong CP SR/SP/ER/PC effect");
  if(error)for(unsigned i=0;i<20;++i) {tick();check(!d.req_valid && !d.cp_req_valid && !d.retire,"activity after CP error");}
 }
};
int main(int argc,char** argv) {
 Verilated::commandArgs(argc,argv);
 try {
  Bench b;unsigned success=0,errors=0;
  for(unsigned unit=0;unit<4;++unit)for(unsigned reg=0;reg<8;++reg)for(unsigned read=0;read<2;++read) {
   uint16_t word=0xfc60|(unit<<8)|reg|(read<<3);
   for(bool fast:{false,true}) {b.reset(word,false,fast);b.run();++success;}
   b.reset(word,true,false);b.run();++errors;
  }
  b.reset(0xfc70,false,false);
  for(unsigned i=0;i<500 && !b.d.fault;++i)b.tick();
  check(b.d.fault && b.d.fault_pc==0x104 && b.accepted==0,"invalid opcode reached CP port");
  // Production default (INVALID_OP_NOP=0): vendor-named CCMD/GETC/EXC/LDC/STC, a
  // MAME INVALIDOP and out-of-array EXTB/EXTS/JR/CALLR indices all stop visibly
  // without a CP request. (sim cpu runs INVALID_OP_NOP=1 against MAME's no-ops.)
  for(uint16_t word:{0xfc00,0xfc40,0xfc50,0xfc80,0xfc90,0xfe00,0xfa00,0xe088,0xe098,0xe008,0xe018,0xa1c4}) {
   b.reset(word,false,false);
   for(unsigned i=0;i<500 && !b.d.fault;++i)b.tick();
   check(b.d.fault && b.d.fault_pc==0x104 && b.d.fault_opcode==word && b.accepted==0 && !b.d.retire,"undefined opcode did not fault");
  }
  b.reset(0xff6f,false,false);
  for(unsigned i=0;i<500 && !b.d.cp_req_valid;++i)b.tick();
  check(b.d.cp_req_valid,"missing reset cancellation target");
  b.d.reset=1;b.mp=b.cp=false;b.tick();
  check(!b.d.cp_req_valid && !b.d.retire && !b.d.fault,"reset did not cancel CP request");
  std::printf("PASS SE3208 coprocessor transfers: %u successful + %u error cases, all 64 encodings, implicit R0, immediate/delayed replies, request backpressure, paused ce, invalid opcode/reset cancellation; %llu clocks. Synthetic reset BIOS, no state load.\n",success,errors,(unsigned long long)clocks);
  return 0;
 } catch(const std::exception& e) {std::fprintf(stderr,"FAIL coprocessor transfer: %s\n",e.what());return 1;}
}
