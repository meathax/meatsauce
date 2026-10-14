// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_color_path.h"
#include "verilated.h"
#include <cstdio>
#include <stdexcept>
static void require(bool ok,const char* s){if(!ok)throw std::runtime_error(s);}
int main(int argc,char** argv){
 Verilated::commandArgs(argc,argv); Vn8080_color_path d;
 auto edge=[&](){d.clk=0;d.eval();d.clk=1;d.eval();d.clk=0;d.eval();};
 try{
  d.clear_n=0;d.ce_capture=0;d.prom_pins=15;d.color_mode=0;d.color_data=0;d.video_bit=0;
  edge();require(d.latch_q==0 && d.latch_q_n==15,"diagnostic clear");
  d.clear_n=1;unsigned holds=0,captures=0,static_matches=0;
  for(unsigned p=0;p<16;p++)for(unsigned captured_mode=0;captured_mode<4;captured_mode++){
   d.prom_pins=p;d.color_mode=captured_mode;d.ce_capture=1;edge();captures++;
   const bool held_selector=(p&8) && captured_mode!=2;
   const unsigned q=((p&1)<<3)|(p&4)|((!held_selector)<<1)|((p>>1)&1);
   require(d.latch_q==q && d.latch_q_n==(q^15),"corrected PROM/conditioned D2 pins");
   d.ce_capture=0;
   for(unsigned live_mode=0;live_mode<4;live_mode++){
    const unsigned f=(p+live_mode+captured_mode)&7;
    d.color_mode=live_mode;d.color_data=f;d.video_bit=1;
    d.prom_pins=p^15;edge();holds++;
    require(d.latch_q==q,"PROM/mode changes must retain conditioned selector without CE");
    const bool s=live_mode==0 || ((live_mode==1 || live_mode==2)&&held_selector);
    const bool st=live_mode==3;
    const unsigned on=st?7:s?(p&7):(f^7);
    require(d.mux_select==s && d.mux_strobe==st,"decoded LS158 controls");
    require(d.mux_n==on && d.nand_n==(on^7) && d.pnp_on==on,"corrected color path");
    if(live_mode==captured_mode){
     const unsigned mame=live_mode==3?7:live_mode==2||(live_mode==1&&!(p&8))?(f^7):(p&7);
     require(on==mame,"static MAME color rule");static_matches++;
    }
    d.video_bit=0;d.eval();require(d.pnp_on==0 && d.nand_n==7,"common video blanking");
   }
  }
  std::printf("PASS corrected_captures=%u live_mode_hold_checks=%u static_MAME_matches=%u video_blank_checks=256\n",captures,holds,static_matches);
 }catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 2;}
 return 0;
}
