// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vinterrupt_path_qualification.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
int main(int argc,char**argv){
 try {
  Verilated::commandArgs(argc,argv); if(argc!=2)throw std::runtime_error("trace path required");
  Vinterrupt_path_qualification t; std::ofstream log(argv[1]);
  log<<"tick,case,vertical,vb,intr,intd,inte,inta,request_rise_before,irq,vector,counter_ce\n";
  unsigned long tick=0;unsigned checks=0,events=0,vertical_steps=0,blank_carries=0;
  auto step=[&](const char*name){t.clk=0;t.eval();bool rise=t.request_rise;
   t.clk=1;t.eval();++tick;log<<tick<<','<<name<<','<<unsigned(t.raw_vertical)<<','<<unsigned(t.vb)<<','<<unsigned(t.intr)<<','<<unsigned(t.intd)<<','<<unsigned(t.inte)<<','<<unsigned(t.status_inta)<<','<<rise<<','<<unsigned(t.irq)<<','<<unsigned(t.interrupt_data)<<','<<unsigned(t.counter_ce)<<'\n';return rise;};
  auto check=[&](bool ok,const char*name){++checks;if(!ok)throw std::runtime_error(name);};
  t.joined=0;t.counter_reset=1;t.counter_ce=0;t.sample_ce=1;t.status_inta=0;t.inte=1;
  t.manual_vertical=127;t.manual_vb=0;t.diagnostic_clear=1;step("manual-origin-v127");
  t.diagnostic_clear=0;step("origin-release");check(!t.irq,"no reset release request");
  t.manual_vertical=128;check(step("request-v128"),"v128 rise observed");check(t.irq&&t.interrupt_data==0xcf,"v128 CF captures INTE");
  t.inte=0;step("inte-drops-pending");check(t.irq,"INTE drop retains pending IRQ");
  t.manual_vertical=192;step("vector-live-pending");check(t.irq&&t.interrupt_data==0xd7,"pending IRQ retains and vector follows INTD");
  t.status_inta=1;t.sample_ce=0;step("inta-between-strobes");check(!t.irq,"latched INTA clears outside CE");
  t.sample_ce=1;t.manual_vertical=240;t.manual_vb=1;step("request-under-inta");check(!t.irq,"INTA dominates coincident request");
  t.status_inta=0;t.inte=1;step("inta-release-intr-high");check(!t.irq,"INTA release is not new request");
  t.manual_vertical=239;t.manual_vb=0;step("request-low");t.inte=0;t.manual_vertical=240;t.manual_vb=1;
  check(step("v240-disabled"),"v240 rise observed");check(!t.irq&&t.interrupt_data==0xd7,"v240 samples disabled INTE");
  t.inte=1;step("inte-rises-intr-high");check(!t.irq,"INTE rise does not recapture held INTR");
  t.diagnostic_clear=1;step("diagnostic-clear-intr-high");t.diagnostic_clear=0;step("diagnostic-release-intr-high");check(!t.irq,"diagnostic release is not request");
  t.manual_vertical=127;t.manual_vb=0;step("ce-request-low");t.manual_vertical=128;t.sample_ce=0;step("ce-held-request");check(!t.irq,"CE holds IRQ storage");
  t.sample_ce=1;check(step("ce-observes-request"),"CE observes settled pending edge");check(t.irq,"CE captures INTE");
  t.manual_vertical=239;step("pending-before-disabled-event");t.inte=0;t.manual_vertical=240;t.manual_vb=1;step("disabled-event-overwrites-pending");check(!t.irq,"disabled rising request samples zero");
  // Joined counter zero is an explicitly synthetic origin, not PCB reset.
  t.joined=1;t.counter_reset=1;t.diagnostic_clear=1;t.inte=1;t.status_inta=0;t.sample_ce=1;step("joined-synthetic-zero");
  t.counter_reset=0;t.diagnostic_clear=0;unsigned previous_v=t.raw_vertical;bool ack_next=false;
  for(unsigned n=0;n<163840*4+3;++n){
   t.counter_ce=(n%4)==0;t.status_inta=ack_next;ack_next=false;
   t.clk=0;t.eval();bool active_carry=t.counter_ce&&t.h_carry&&t.h_active;
   bool rejected_carry=t.counter_ce&&t.h_carry&&!t.h_active;
   unsigned pre_v=t.raw_vertical;bool rising=step("joined-counter");
   if(t.raw_vertical!=pre_v){++vertical_steps;check(active_carry,"vertical changes on active-end carry");}
   if(rejected_carry)++blank_carries;
   check(t.vb==(t.raw_vertical<16||t.raw_vertical>=240),"qualified steady VB relation");
   if(rising){++events;check(t.raw_vertical==128||t.raw_vertical==240,"joined request counter event");
    check(t.irq,"joined enabled IRQ capture");check(t.interrupt_data==(t.raw_vertical==128?0xcf:0xd7),"joined live CF/D7 vector");ack_next=true;}
   if(t.status_inta)check(!t.irq,"joined INTA clear");previous_v=t.raw_vertical;
  }
  check(events==4,"two requests per synthetic field");check(vertical_steps==512,"joined 512 vertical carries");check(blank_carries==512,"joined 512 rejected blank carries");
  log.close();std::cout<<"{\"pass\":true,\"checks\":"<<checks<<",\"master_samples\":"<<tick<<",\"joined_requests\":"<<events<<",\"vertical_increments\":"<<vertical_steps<<",\"rejected_blank_carries\":"<<blank_carries<<",\"synthetic_origin\":\"counter-zero/VB-high\",\"physical_origin_qualified\":false}\n";
  t.final();return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 2;}
}
