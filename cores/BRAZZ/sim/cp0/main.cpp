// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvr0_cp0.h"
#include "verilated.h"
#include <vector>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
static uint64_t clocks=0;
double sc_time_stamp(){return double(clocks);}
static void check(bool b,const char* m){if(!b)throw std::runtime_error(m);}
static uint32_t rng(){static uint32_t s=0xfc65beef;s^=s<<13;s^=s>>17;s^=s<<5;return s;}
struct Bench {
 Vvr0_cp0 d;
 std::vector<uint32_t> ram=std::vector<uint32_t>(32768);
 // CPU-visible memory model. Equal to ram except while a posted write drains.
 std::vector<uint32_t> model;
 bool posted_check=false;std::vector<uint32_t> posted_addresses;
 // The backend request register can be empty for a clock between queued
 // fill words / posted writes: idle means no traffic for several clocks.
 unsigned quiet=0;
 bool pending=false,reply_error=false,held=false,accepted=false,cp_accepted=false;
 unsigned delay=0,requests=0,replies=0,accesses=0;
 uint32_t reply=0,fail_address=0xffffffff;
 uint64_t held_meta=0;uint32_t held_address=0;
 Bench(){for(auto& w:ram)w=rng();d.reset=1;d.req_valid=0;d.cp_req_valid=0;d.cp_rsp_ready=1;d.snoop_valid=0;d.invalidate_all=0;for(unsigned i=0;i<3;++i)tick();d.reset=0;model=ram;}
 unsigned index(uint32_t a){return (a>>2)&32767;}
 uint32_t mask(unsigned s){uint32_t m=0;for(unsigned i=0;i<4;++i)if(s&(1<<i))m|=0xffu<<(8*i);return m;}
 uint64_t meta(){return uint64_t(d.mem_req_data)|(uint64_t(d.mem_req_strobe)<<32)|(uint64_t(d.mem_req_write)<<36);}
 void tick(){
  d.clk=0;d.mem_req_ready=!pending && rng()%4!=0;
  d.mem_rsp_valid=pending && delay==0;d.mem_rsp_data=reply;d.mem_rsp_error=reply_error;d.eval();
  accepted=d.req_valid && d.req_ready && !d.reset;cp_accepted=d.cp_req_valid && d.cp_req_ready && !d.reset;
  bool accept=d.mem_req_valid && d.mem_req_ready && !d.reset,respond=d.mem_rsp_valid;
  uint32_t addr=d.mem_req_address,data=d.mem_req_data;unsigned lanes=d.mem_req_strobe;bool write=d.mem_req_write;
  if(held && !d.reset)check(d.mem_req_valid && addr==held_address && meta()==held_meta,"unstable stalled memory request");
  held=d.mem_req_valid && !d.mem_req_ready && !d.reset;held_address=addr;held_meta=meta();
  d.clk=1;d.eval();++clocks;
  if(respond){pending=false;++replies;}else if(pending && delay)--delay;
  if(accept){
   check(!pending && !(addr&3),"memory protocol");++requests;pending=true;delay=1+rng()%7;reply_error=addr==fail_address;
   reply=ram[index(addr)];if(write && !reply_error){uint32_t m=mask(lanes);ram[index(addr)]=(reply&~m)|(data&m);}
  }
  // A posted write must reach the backend with the CPU-visible lanes/data once drained.
  quiet=(!pending && !d.mem_req_valid && !accepted)?quiet+1:0;
  if(posted_check && quiet>=4){for(auto pa:posted_addresses)check(ram[index(pa)]==model[index(pa)],"posted write lane/data");posted_addresses.clear();posted_check=false;}
 }
 uint32_t control(unsigned reg,bool write,uint32_t data=0,bool error=false,unsigned unit=0){
  d.cp_req_id=unit;d.cp_req_register=reg;d.cp_req_write=write;d.cp_req_data=data;d.cp_req_valid=1;
  unsigned n=0;do{tick();check(++n<2000,"control acceptance timeout");}while(!cp_accepted);d.cp_req_valid=0;
  while(!d.cp_rsp_valid){tick();check(++n<2000,"control response timeout");}
  check(bool(d.cp_rsp_error)==error,"control error classification");return d.cp_rsp_data;
 }
 uint32_t access(uint32_t address,bool write=false,uint32_t data=0,unsigned lanes=15,bool cacheable=true,bool error=false){
  uint32_t expected=model[index(address)];if(write && !error){uint32_t m=mask(lanes);expected=(expected&~m)|(data&m);}
  d.req_address=address;d.req_write=write;d.req_data=data;d.req_strobe=lanes;d.req_cacheable=cacheable;d.req_valid=1;
  unsigned n=0;do{tick();check(++n<2000,"CPU acceptance timeout");}while(!accepted);d.req_valid=0;
  while(!d.rsp_valid){tick();check(++n<2000,"CPU response timeout");}
  check(bool(d.rsp_error)==error,"CPU error classification");
  if(write && !error)model[index(address)]=expected;
#ifdef CS_CP0_POSTED
  if(write && !error && cacheable){posted_check=true;posted_addresses.push_back(address);}
  else
#endif
  if(!error){if(write)check(ram[index(address)]==expected,"incorrect write-through lane/data");else check(d.rsp_data==expected,"stale/incorrect cache data");}
  ++accesses;return d.rsp_data;
 }
 void drain(){unsigned n=0;quiet=0;while(quiet<4 || posted_check){tick();check(++n<2000,"posted write drain timeout");}}
 void snoop(uint32_t address,uint32_t value){if(posted_check)drain();ram[index(address)]=value;model[index(address)]=value;d.snoop_address=address;d.snoop_valid=1;tick();d.snoop_valid=0;}
};
int main(int argc,char** argv){
 Verilated::commandArgs(argc,argv);
 try {
  Bench b;constexpr uint32_t a=0x02000000;
  check(!b.d.cache_enabled && b.control(6,false)==0x80204b01,"reset status");
  b.access(a);b.access(a,true,0x12345678,5);b.access(a);
  b.control(7,true,0x800);check(b.d.cache_enabled && (b.control(6,false)&0x800000),"enable/status");
  check(b.control(7,false)==0x1100 && b.control(3,false)==0x80,"register constants");
#ifdef CS_CP0_POSTED
  // CACHE_WHILE_DISABLED: the disabled-phase accesses above already filled the line.
  b.control(5,true,1);while(b.d.invalidation_busy)b.tick();
#endif
  auto req=b.requests;b.access(a);b.drain();check(b.requests==req+4,"line fill count");
  req=b.requests;for(unsigned w=0;w<4;++w)b.access(a+w*4);b.drain();check(b.requests==req,"cache hit missed");
  b.access(a+4,true,0xa1b2c3d4,10);b.access(a+4);
  b.snoop(a,0xcafebeef);req=b.requests;b.access(a);b.drain();check(b.requests==req+4,"snoop did not invalidate");
  // Three colliding lines exercise both ways and LRU replacement.
  b.access(a+0x800);b.access(a);req=b.requests;b.access(a+0x1000);b.drain();check(b.requests==req+4,"conflict fill");
  req=b.requests;b.access(a);b.drain();check(b.requests==req,"recent line evicted");
  req=b.requests;b.control(5,true,0);b.access(a);b.drain();check(b.requests==req,"zero invalidation changed tags");
  b.control(5,true,1);check(b.d.invalidation_busy,"invalidation busy missing");
  check(b.control(6,false)&0x100000,"busy status missing");
  while(b.d.invalidation_busy)b.tick();req=b.requests;b.access(a);b.drain();check(b.requests==req+4,"invalidate did not clear tags");
  // MAME 0.289 SE3208: MVTC/MVFC are no-ops. Write-back request (CR3 bit6), unspecified registers and other
  // coprocessor ids are accepted without error and change nothing; unspecified reads return 0.
  b.control(3,true,0x40);check(b.control(4,false)==0,"unspecified register read");check(b.control(7,false,0,false,1)==0,"other coprocessor read");
  check(b.d.cache_enabled && b.control(3,false)==0x80,"unsupported control mutated state");
  // Bypass writes while disabled must not leave stale data on re-enable.
  b.control(7,true,0);b.access(a,true,0x5a5aa5a5);b.control(7,true,0x800);b.access(a);
  for(unsigned i=0;i<1500;++i){uint32_t addr=a+((rng()%8192)*4);bool write=rng()%3==0;b.access(addr,write,rng(),1+rng()%15);if(write)b.access(addr);}
  // Read and hit-write backend errors invalidate any partially changed line.
#ifdef CS_CP0_POSTED
  // A posted write's backend error is reported on the next reply and clears the cache.
  b.drain();b.access(a);b.drain();const auto posted_inv=b.d.invalidations;b.fail_address=a;
  {b.d.req_address=a;b.d.req_write=1;b.d.req_data=0xdeadbeef;b.d.req_strobe=15;b.d.req_cacheable=1;b.d.req_valid=1;
   do{b.tick();}while(!b.accepted);b.d.req_valid=0;while(!b.d.rsp_valid)b.tick();
   check(!b.d.rsp_error,"posted write reported its error synchronously");}
  b.drain();b.fail_address=0xffffffff;
  {const auto inv=posted_inv;b.access(a+4,false,0,15,true,true);while(b.d.invalidation_busy)b.tick();check(b.d.invalidations==inv+1,"posted error did not invalidate");}
  b.access(a);
  // Posted write followed by an immediate hit, a miss and an uncached access: order and data.
  b.access(a+8);b.access(a+8,true,0x01020304);b.access(a+8);b.access(a+0x4000);b.access(a+12,true,0x0badf00d,15,false);b.access(a+12);
  // Back-to-back posted writes fill the write FIFO (hits and misses, partial lanes),
  // then reads of every location, then a miss that must wait for the FIFO to drain.
  for(unsigned i=0;i<12;++i)b.access(a+0x40+((i*0x204)&0x1ffc),true,rng(),1+rng()%15);
  for(unsigned i=0;i<12;++i)b.access(a+0x40+((i*0x204)&0x1ffc));
  for(unsigned i=0;i<6;++i)b.access(a+0x80+i*4,true,rng());b.access(a+0x6000);b.drain();
#else
  b.access(a);b.fail_address=a;b.access(a,true,0xdeadbeef,15,true,true);b.fail_address=0xffffffff;b.access(a);
#endif
  b.control(5,true,1);while(b.d.invalidation_busy)b.tick();b.fail_address=a;b.access(a,false,0,15,true,true);b.fail_address=0xffffffff;b.access(a);
  // A snoop after the first fill word must prevent installation of a torn line.
  b.control(5,true,1);while(b.d.invalidation_busy)b.tick();
  // Early restart: the requested word (a+4) answers first; the snoop lands while
  // the remaining words are still filling in the background.
  b.drain();uint32_t old=b.ram[b.index(a+4)];unsigned prior_replies=b.replies,prior_requests=b.requests;
  b.d.req_address=a+4;b.d.req_write=0;b.d.req_data=0;b.d.req_strobe=15;b.d.req_cacheable=1;b.d.req_valid=1;
  do{b.tick();}while(!b.accepted);b.d.req_valid=0;
  while(!b.d.rsp_valid)b.tick();check(b.d.rsp_data==old,"inflight read snapshot changed");
  check(b.replies==prior_replies+1,"early restart did not answer with the first word");
  while(b.replies<prior_replies+2)b.tick();check(b.requests-prior_requests<4,"fill finished before snoop");
  b.snoop(a,b.ram[b.index(a)]^0xffffffff);
  b.drain();req=b.requests;b.access(a);b.drain();check(b.requests==req+4,"snooped fill installed stale line");
  b.d.invalidate_all=1;b.tick();b.d.invalidate_all=0;while(b.d.invalidation_busy)b.tick();req=b.requests;b.access(a);b.drain();check(b.requests==req+4,"global bank invalidation failed");
  // Control response must remain stable under backpressure.
  b.tick();b.d.cp_rsp_ready=0;b.control(6,false);auto status=b.d.cp_rsp_data;
  for(unsigned i=0;i<20;++i){b.tick();check(b.d.cp_rsp_valid && b.d.cp_rsp_data==status,"unstable stalled control reply");}b.d.cp_rsp_ready=1;b.tick();
#ifdef CS_CP0_POSTED
  std::printf("POSTED_WRITES=1 CACHE_WHILE_DISABLED=1: ");
#endif
  std::printf("PASS CP0/cache: %u CPU accesses, %u backend requests, hits=%u misses=%u invalidations=%u; enable/status, lanes, two-way LRU, external/bank snoops, inflight-fill coherency, errors and backpressure; %llu clocks. Qualified descriptor; write-back requests accepted as write-through (MAME no-op).\n",b.accesses,b.requests,b.d.hits,b.d.misses,b.d.invalidations,(unsigned long long)clocks);
  return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"FAIL CP0/cache: %s\n",e.what());return 1;}
}
