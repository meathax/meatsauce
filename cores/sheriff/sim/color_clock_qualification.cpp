// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcolor_clock_qualification.h"
#include "verilated.h"
#include <cstdio>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <vector>
static void require(bool ok,const char* msg){if(!ok)throw std::runtime_error(msg);}
static unsigned conditioned_q(unsigned p){
 return ((p&1)<<3)|(p&4)|((!(p&8))<<1)|((p>>1)&1);
}
static unsigned rgb_from_q(unsigned q){return ((q>>3)&1)|((q&1)<<1)|(q&4);}
int main(int argc,char** argv){
 try{
  Verilated::commandArgs(argc,argv);require(argc==2,"private blob path required");
  std::ifstream f(argv[1],std::ios::binary);require(bool(f),"private blob open");
  std::vector<unsigned char> blob((std::istreambuf_iterator<char>(f)),{});
  require(blob.size()>=0x4800,"private PROM extent");
  Vcolor_clock_qualification d;d.clk=0;d.clear_n=0;d.ce_counter=0;
  d.flip_latched=0;d.prom_pins=0;d.rd=0xa5;d.eval();d.clk=1;d.eval();
  d.clk=0;d.clear_n=1;d.ce_counter=1;d.eval();
  unsigned expected_q=0,captures=0,holds=0,addresses=0,lines=0;
  unsigned flip_holds=0,serializer_active=0,distinct_rgb=0;
  // Two bounded20-line spans exercise native VB startup then both flip levels.
  // This is a diagnostic counter origin, not an asserted visible origin.
  for(unsigned span=0;span<2;span++){
   d.flip_latched=span;d.eval();
   for(unsigned tick=0;tick<20*320;tick++){
    d.clk=0;d.eval();
    const unsigned h=((d.upper_4j^(span?15:0))<<1)|
      (((d.phase_4i>>3)&1)^(!span));
    const unsigned v=d.raw_vertical^(span?255:0);
    const unsigned mame_address=32*(v>>3)+h;
    require(d.prom_address==mame_address,"static PROM address from source PIO");
    addresses++;
    const unsigned pins=blob[0x4400+d.prom_address]&15;
    d.prom_pins=pins;d.eval();
    const bool capture=d.phase_4i==15;
    require(bool(d.ce_color)==capture,"HREAD_n positive-edge CE");
    const unsigned before_q=d.latch_q,before_phase=d.phase_4i;
    const bool before_hread=d.hread_n;
    if(capture){expected_q=conditioned_q(pins);captures++;}
    else holds++;
    d.clk=1;d.eval();
    require(d.phase_4i==((before_phase+1)&15),"phase supplied by common CE");
    require((!before_hread && d.hread_n)==capture,"actual inverted-QD edge");
    require(d.latch_q==expected_q,"settled pre-edge PROM capture/hold");
    require(d.latch_q_n==((~expected_q)&15),"held complements");
    if(!capture)require(d.latch_q==before_q,"PROM change does not bypass latch");
    if(span==1 && tick<15){require(d.latch_q==before_q,"flip before capture holds color");flip_holds++;}
    const unsigned rgb=rgb_from_q(expected_q);
    require(d.pnp_on==(d.video_bit?rgb:0),"held color through qualified serializer gating");
    if(d.video_bit)serializer_active++;
    if(capture)distinct_rgb|=1u<<rgb;
    if((tick%320)==319){
     lines++;require(captures==lines*20,"twenty HREAD_n captures per320-clock span");
    }
   }
  }
  require(captures==800 && holds==12000 && addresses==12800,"bounded capture coverage");
  require(flip_holds==15 && serializer_active>0,"flip hold and active serializer coverage");
  std::printf("PASS source_clock_captures=%u holds=%u static_addresses=%u spans=%u flip_holds=%u serializer_on=%u observed_RGB_values=%u\n",
   captures,holds,addresses,lines,flip_holds,serializer_active,
   unsigned(__builtin_popcount(distinct_rgb)));
  d.final();return 0;
 }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
