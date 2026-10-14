// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vdram_storage_qualification.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
struct Row { unsigned edge,cpu,phase,rr,rc,com,hr,r,c,selector,address,capture; };
struct Drive {
 VerilatedContext context;
 Vdram_storage_qualification b{&context};
 unsigned checks=0,ticks=0,writes=0,reads=0,ignored=0,unsupported=0;
 Drive() {
  context.randSeed(1);
  b.clk=0;b.reset=0;b.consumer_capture=0;b.direct_mode=1;
  b.direct_ras_n=1;b.direct_cas_n=1;b.direct_we_n=1;b.direct_address=0;b.di=0;
  b.cpu_wr_rd_level=0;b.cpu_address=0x2a55;b.cpu_wr_n=1;
  b.physical_h_byte=19;b.physical_v=166;
  b.raw_ras_n=1;b.raw_cas_n=1;b.comadr_n=1;b.hread_n=1;reset();
 }
 void check(bool condition,const std::string&name) {
  checks++;if(!condition)throw std::runtime_error(name+" tick="+std::to_string(ticks));
 }
 void tick() {
  b.clk=0;b.eval();b.clk=1;b.eval();context.timeInc(1);ticks++;
  writes+=b.write_event;reads+=b.read_event;ignored+=b.ignored_cas_event;
  unsupported+=b.unsupported_event;
 }
 void pins(unsigned r,unsigned c,unsigned w,unsigned a,unsigned d=0) {
  b.direct_mode=1;b.direct_ras_n=r;b.direct_cas_n=c;b.direct_we_n=w;
  b.direct_address=a;b.di=d;tick();
 }
 void reset() { b.reset=1;tick();b.reset=0;tick(); }
 void close() { b.consumer_capture=0;pins(1,1,1,0); }
 void early(unsigned row,unsigned column,unsigned data) {
  close();pins(1,1,0,row);pins(0,1,0,row);pins(0,1,0,column);
  pins(0,0,0,column,data);
  check(b.write_event&&!b.read_event&&!b.do_valid,"early write at CAS fall");
  pins(0,0,0,column,data^0xff);
  check(!b.write_event&&!b.do_valid,"low levels/DI change cannot rewrite");
  close();
 }
 void read(unsigned row,unsigned column,unsigned expected) {
  close();pins(0,1,1,row);pins(0,1,1,column);pins(0,0,1,column);
  check(b.read_event&&!b.write_event&&!b.do_valid,"synchronous read request");
  pins(0,0,1,column);
  check(b.do_valid&&b.do_data==expected,"latched row/column read response");
 }
 void frozen(const Row&r) {
  b.direct_mode=0;b.cpu_wr_rd_level=r.cpu;
  b.raw_ras_n=r.rr;b.raw_cas_n=r.rc;b.comadr_n=r.com;b.hread_n=r.hr;
  b.consumer_capture=r.capture;b.eval();
  check(b.actual_ras_n==r.r&&b.actual_cas_n==r.c&&b.actual_we_n==1&&
        b.actual_address==r.address&&b.mux_selector==r.selector,"source control pins");
 }
};
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);if(argc<3)return 2;
 try {
  Drive d;
  // Selected endpoints, writes and holds. No array initialization or hierarchy forcing.
  d.early(0,0,0x31);
  d.read(0,0,0x31);
  d.pins(0,0,1,127);
  d.check(d.b.do_valid&&d.b.do_data==0x31,"column/address changes after latch");
  d.early(127,127,0x45);
  d.read(127,127,0x45);
  d.pins(0,0,0,0,0x92);
  d.check(d.b.write_event&&d.b.do_valid&&d.b.do_data==0x45,"late write keeps previous read DO");
  d.pins(0,0,0,1,0xee);
  d.check(!d.b.write_event&&d.b.do_data==0x45,"late write commits once");
  d.close();d.read(127,127,0x92);
  d.b.consumer_capture=1;d.pins(1,1,1,0);
  d.check(d.b.captured_valid&&d.b.captured_data==0x92&&!d.b.do_valid,
          "old-state consumer before same-edge CAS release");
  d.b.consumer_capture=0;
  d.close();d.pins(1,0,0,0,0xee);
  d.check(d.b.ignored_cas_event&&!d.b.write_event&&!d.b.do_valid,"orphan CAS cannot write");
  d.close();d.read(0,0,0x31);
  d.pins(1,0,1,0);
  d.check(d.b.do_valid&&d.b.do_data==0x31,"RAS rise alone retains DO");
  d.pins(1,0,0,0,0xee);
  d.check(!d.b.write_event,"closed row/stale column cannot late write");
  d.close();d.read(0,0,0x31);
  d.close();d.pins(0,1,1,0);d.pins(0,0,0,0,0xee);
  d.check(d.b.unsupported_event&&!d.b.write_event&&!d.b.read_event,
          "coincident WE/CAS has no invented early/late order");
  d.close();d.read(0,0,0x31);
  d.close();d.pins(0,0,1,0);
  d.check(d.b.unsupported_event&&!d.b.write_event&&!d.b.read_event,
          "coincident RAS/CAS rejected");
  d.close();d.read(0,0,0x31);d.reset();
  d.check(!d.b.do_valid,"reset releases output");d.read(0,0,0x31);d.close();

  std::ifstream f(argv[1]);std::vector<Row> rows;Row r;
  while(f>>r.edge>>r.cpu>>r.phase>>r.rr>>r.rc>>r.com>>r.hr
         >>r.r>>r.c>>r.selector>>r.address>>r.capture)rows.push_back(r);
  if(rows.size()!=64||!f.eof())throw std::runtime_error("fixture count/parse");
  unsigned frozen_reads=0,frozen_writes=0,frozen_ignored=0,captures=0,points=0;
  for(unsigned cpu=0;cpu<2;cpu++) {
   Drive p;
   p.early(0x55,0x54,0x62);  // CPU0x2a55, row low7/column high7.
   p.early(83,41,0xb9);     // PhysicalHbyte19/V166 source projection.
   unsigned oldreads=p.reads,oldwrites=p.writes,oldignored=p.ignored;
   const Row*first=nullptr;for(const auto&v:rows)if(v.cpu==cpu){first=&v;break;}
   if(!first)throw std::runtime_error("missing supplied CPU level");
   p.frozen(*first);p.b.reset=1;p.tick();p.b.reset=0;
   unsigned position=126;
   for(const auto&v:rows)if(v.cpu==cpu) {
    unsigned target=v.edge-(v.phase==0?1:0);
    while(position+1<target){p.b.consumer_capture=0;p.tick();position++;}
    if(position>=target)throw std::runtime_error("fixture time order");
    p.frozen(v);p.tick();position=target;points++;
    p.check(!p.b.unsupported_event,"frozen source edges supported");
    if(v.capture) {
     p.check(p.b.captured_valid&&p.b.captured_data==0xb9,"frozen video old-state capture");
     p.check(p.b.do_valid==(cpu==1),"frozen CAS-release output validity");
     captures++;
    }
   }
   frozen_reads+=p.reads-oldreads;frozen_writes+=p.writes-oldwrites;
   frozen_ignored+=p.ignored-oldignored;d.checks+=p.checks;
  }
  d.check(frozen_reads==6&&frozen_writes==0&&frozen_ignored==2&&captures==4,
          "frozen read/orphan/capture counts");
  std::ofstream out(argv[2]);
  out<<"{\"primary_scenarios\":8,\"checks\":"<<d.checks
     <<",\"frozen_source_rows\":32,\"frozen_source_edge_points\":"<<points
     <<",\"frozen_reads\":"<<frozen_reads<<",\"frozen_writes\":"<<frozen_writes
     <<",\"frozen_ignored_CAS\":"<<frozen_ignored<<",\"old_state_capture_cases\":"<<captures
     <<",\"functional_mismatches\":0}\n";
  std::cout<<"PASS primary scenarios=8 frozen edge points="<<points
           <<" reads="<<frozen_reads<<" orphanCAS="<<frozen_ignored
           <<" captures="<<captures<<" checks="<<d.checks<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
}
