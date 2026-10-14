// SPDX-License-Identifier: GPL-3.0-or-later
// Connected clock/load/held-byte stream test, not a raster-origin oracle.
#include "Vn8080_video_path.h"
#include "verilated.h"
#include <iostream>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vn8080_video_path b;
 auto clock=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
 unsigned loads=0,pixels=0,held=0,blank=0;
 for(unsigned reverse=0;reverse<2;reverse++) {
  b.ce_counter=0;b.clear_n=0;b.phase_4i=0;b.hb=0;b.vb=0;
  b.flip_latched=reverse;
  b.serial_left=0;b.serial_right=0;b.rd=0;clock();b.clear_n=1;
  for(unsigned word=0;word<256;word++) {
   // At a pre7 edge the common clock advances 4I while 1L loads.
   b.phase_4i=7;b.ce_counter=1;b.rd=word;b.eval();
   if(!b.load_mode){std::cerr<<"missing pre7 load mode\n";return 1;}
   clock();loads++;
   for(unsigned index=0;index<8;index++) {
    if(index) {
     b.phase_4i=(7+index)&7;b.ce_counter=1;b.rd=word^255;b.eval();
     if(b.load_mode){std::cerr<<"load outside pre7\n";return 1;}
     clock();
    }
    unsigned expected=(word>>(reverse?index:7-index))&1;
    if(b.video_bit!=expected){std::cerr<<"stream differs direction="<<reverse<<" byte="<<word<<" index="<<index<<'\n';return 1;}
    pixels++;
    // Change the external RD bus after the edge: loaded state must hold.
    auto q=b.register_q;
    b.ce_counter=0;b.rd=word^255;clock();
    if(b.register_q!=q || b.video_bit!=expected){std::cerr<<"RD changes visible held byte\n";return 1;}
    held++;
   }
  }
  // After eight output bits, blanking prevents replacement by the RD bus.
  for(unsigned which=0;which<2;which++) {
   b.hb=which;b.vb=!which;b.phase_4i=7;b.ce_counter=1;b.rd=255;b.eval();
   if(b.load_mode){std::cerr<<"blanking did not suppress parallel load\n";return 1;}
   clock();
   if(b.video_bit){std::cerr<<"blanked boundary reloaded RD\n";return 1;}
   blank++;
  }
 }
 std::cout<<"PASS byte_loads="<<loads<<" stream_pixels="<<pixels<<" post_edge_RD_holds="<<held<<" blanked_boundaries="<<blank<<'\n';
 return 0;
}
