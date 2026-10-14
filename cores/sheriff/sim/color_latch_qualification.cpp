// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcolor_latch_qualification.h"
#include "verilated.h"
#include <iostream>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv); Vcolor_latch_qualification b;
 auto edge=[&](){b.clk=0;b.eval();b.clk=1;b.eval();b.clk=0;b.eval();};
 b.reset=1;b.ce_xtal=0;b.ce_counter=0;b.d=15;edge();b.reset=0;
 unsigned pixels=0,captures=0,holds=0,seen=0,expected=0,last_capture=0;
 for(unsigned p=0;p<10240;++p) {
  b.d=((p/320)+(p&7))&15;unsigned data=b.d;
  // The real 4I divider advances once per four crystal positive edges.
  // Match the already qualified shared-clock schedule, not a new phase.
  for(unsigned crystal=0;crystal<4;++crystal){
   b.ce_xtal=1;b.ce_counter=crystal==0;b.eval();
   unsigned old_clock=(b.upper_4j>>3)&1;bool predicted=b.capture_ce;
   edge();bool rose=!old_clock&&((b.upper_4j>>3)&1);
   if(predicted!=rose){std::cerr<<"QD edge mismatch pixel="<<p<<'\n';return 1;}
   if(rose){
    if((captures==0&&p!=191)||(captures&&p-last_capture!=320))return 2;
    expected=data;seen|=1u<<data;last_capture=p;++captures;
   }
   if(b.q!=expected||b.q_n!=(expected^15)){std::cerr<<"latch mismatch pixel="<<p<<'\n';return 3;}
  }
  ++pixels;b.ce_xtal=0;b.ce_counter=0;
  for(unsigned stall=0;stall<9;++stall){b.d=(data+stall+1)&15;edge();
   if(b.q!=expected||b.q_n!=(expected^15)||b.capture_ce)return 4;++holds;}
 }
 if(captures!=32||seen!=65535)return 5;
 std::cout<<"PASS counter_pixels="<<pixels<<" QD_captures="<<captures<<" capture_values=16 CE_hold_checks="<<holds<<'\n';return 0;
}
