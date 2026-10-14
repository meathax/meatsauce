// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vcpu_ready_qualification.h"
#include "verilated.h"
#include <cstdio>
#include <stdexcept>
#include <memory>
static void require(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
static void tick(Vcpu_ready_qualification& t){t.clk=0;t.eval();t.clk=1;t.eval();require(t.facade_equal,"compatibility facade mismatch");}
int main(int argc,char** argv){
 Verilated::commandArgs(argc,argv);
 try{
  unsigned waits=0, deferred=0, facade=0;
  for(unsigned trial=0;trial<50;++trial){
   auto t=std::make_unique<Vcpu_ready_qualification>();
   t->clk=0;t->reset=1;t->pause=0;t->ready=1;t->irq=0;t->eval();
   for(unsigned i=0;i<150;++i){tick(*t);++facade;}
   t->reset=0;
   bool entered=false,saw_wait=false,released=false,completed=false;
   unsigned held=0;const bool irq_case=trial>=25;
   for(unsigned i=0;i<10000;++i){
    // Lower READY at the actual read-cycle status, before its sampling phase.
    if(!entered&&t->sync&&t->address==0x6000&&(t->dout&0x80)){
     entered=true;t->ready=0;
    }
    if(entered&&!released){
     ++held;
     if(saw_wait){
      require(t->address==0x6000,"address changed during read WAIT");
      require(t->wr_n,"write asserted during read WAIT");
      require(!t->interrupt_ack,"interrupt acknowledged before READY release");
      if(irq_case)t->irq=1;
     }
     if(held>=100+(trial%25)){t->ready=1;released=true;}
    }
    tick(*t);++facade;
    if(entered&&!released&&t->wait_debug){saw_wait=true;++waits;}
    if(t->interrupt_ack){
     require(irq_case&&released&&saw_wait,"unexpected interrupt acknowledgement");
     ++deferred;completed=true;break;
    }
    if(!irq_case&&t->writes1){
     require(t->ram0==0xa5&&t->ram1==0xff,"resumed instruction result mismatch");
     require(t->writes0==1&&t->writes1==1,"duplicated or lost memory write");
     require(released&&saw_wait,"read completed without exercised WAIT");
     completed=true;break;
    }
   }
   require(entered&&completed,"CPU did not resume within bound");
   t->final();
  }
  std::printf("PASS release_phases=25 read_resume_cases=25 deferred_IRQ_cases=%u WAIT_ticks=%u facade_checks=%u\n",deferred,waits,facade);
  return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 2;}
}
