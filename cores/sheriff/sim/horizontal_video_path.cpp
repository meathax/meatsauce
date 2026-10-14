// SPDX-License-Identifier: GPL-3.0-or-later
// Joined native counter/phase/serializer test. No fitted raster offset.
#include "Vhorizontal_video_path_qualification.h"
#include "verilated.h"
#include <iostream>
#include <vector>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vhorizontal_video_path_qualification b;
 auto clock=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
 unsigned pixels=0,loads=0,holds=0,blank_pixels=0,active_pixels=0;
 for(unsigned reverse=0;reverse<2;reverse++) {
  b.reset=1;b.ce_xtal=0;b.ce_counter=0;b.vb=0;b.rd=0;
  b.flip_latched=reverse;clock();b.reset=0;
  unsigned low=0,upper=12,active=0;
  unsigned stream_word=0,index=8;unsigned start_edge=0,first_load_edge=0;
  unsigned pending_word=0,pending_ready=0;bool pending=false;
  std::vector<unsigned> hb;
  for(unsigned crystal=0;crystal<2560;crystal++) {
   bool common_clock=crystal%4==0;
   b.ce_xtal=1;b.ce_counter=common_clock;b.eval();
   if(b.phase_4i!=low || b.upper_4j!=upper || b.hb!=!active) {
    std::cerr<<"counter before-edge differs at "<<crystal<<'\n';return 1;
   }
   bool load=common_clock && active && low%8==7;
   if(common_clock && b.load_mode != bool(active && low%8==7)) {
    std::cerr<<"load polarity/phase differs\n";return 1;
   }
   bool old_cas=b.raw_cas_n,old_hread=b.hread_n;
   unsigned old_count=(upper<<4)|low;
   unsigned sampled_rd=b.rd;
   clock();
   if(common_clock) {
    // Closed raster ranges:64 blank clocks,256 active, repeating320.
    unsigned pixel=crystal/4;
    unsigned expected_active=(pixel%320)>=63 && (pixel%320)<319;
    low=(low+1)%16;
    if((old_count&15)==15) upper=(old_count==255)?(active?12:0):(upper+1)%16;
    if(old_count==255)active^=1;
    if(active!=expected_active || b.phase_4i!=low || b.upper_4j!=upper || b.hb!=!expected_active) {
     std::cerr<<"320-pixel range differs at "<<pixel<<'\n';return 1;
    }
    if(pixel%320==63)start_edge=pixel;
    if(load) {
     if(index<7){std::cerr<<"replacement before eight bits\n";return 1;}
     stream_word=sampled_rd;index=0;loads++;
     if(pixel%320==71) {
      first_load_edge=pixel;
      if(first_load_edge-start_edge!=8){std::cerr<<"derived pipeline interval differs\n";return 1;}
     }
    } else if(index<8)index++;
    unsigned expected=index<8 ? (stream_word>>(reverse?index:7-index))&1 : 0;
    if(b.video_bit!=expected){std::cerr<<"native held-byte stream differs\n";return 1;}
    pixels++;blank_pixels+=b.hb;active_pixels+=!b.hb;hb.push_back(b.hb);
   }
   // Actual phase primitive supplies CAS; video address is captured when
   // CAS falls in the video half. Make DO valid three crystal periods later.
   if(old_cas && !b.raw_cas_n && !b.hread_n) {
    pending_word=(0x81 ^ ((old_count>>3)&31));
    pending_ready=crystal+3;pending=true;
   }
   if(pending && crystal>=pending_ready){b.rd=pending_word;pending=false;}
   // Release/alter RD after the same edge: this must not affect loaded Q.
   if((!old_cas && b.raw_cas_n)||(!old_hread && b.hread_n)) b.rd=0x5a;
   auto retained=b.register_q;
   b.eval();
   if(b.register_q!=retained){std::cerr<<"asynchronous RD changed loaded byte\n";return 1;}
   holds++;
  }
  for(unsigned i=0;i<320;i++)if(hb[i]!=hb[i+320]){std::cerr<<"period differs\n";return 1;}
  if(first_load_edge-start_edge!=8){std::cerr<<"missing first byte observation\n";return 1;}
 }
 std::cout<<"PASS counter_pixels="<<pixels<<" active_pixels="<<active_pixels<<" blank_pixels="<<blank_pixels<<" byte_loads="<<loads<<" RD_retention_observations="<<holds<<" first_byte_after_active_clocks=8\n";
 return 0;
}
