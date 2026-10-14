// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvideo_calc.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 unsigned checks=0,runs=0;
 for(unsigned param:{6u,8u,12u})for(unsigned period:{1200u,1213u,1577u,1999u})for(unsigned phase:{1u,4u,7u,9u}){
  Vvideo_calc d;d.par_num=param;d.ce_pix=1;d.new_vmode=0;d.f1=0;d.video_rotated=0;
  unsigned samples=0;
  for(unsigned t=0;t<period*16+phase;++t){
   d.clk_100=(t%10)>=5;d.clk_vid=(t%26)>=13;d.clk_sys=(t%14)>=7;
   bool measured=t>=phase&&((t-phase)%period)<77;
   d.vs=param==8?measured:t%1001<53;d.hs=param==6?measured:t%97<17;d.de=t%97>=29&&t%97<81;
   d.vs_hdmi=t>=phase&&((t-phase)%period)<77;d.eval();
   // Read well after the edge has crossed both settling stages and edge history.
   if(t>=phase+period*4&&((t-phase)%period)==130){
    unsigned lo=period/10,hi=(period+9)/10;
    // Framework vtime starts at zero on the previous edge: readback is interval minus one.
    if(unsigned(d.dout)+1<lo||unsigned(d.dout)+1>hi)throw std::runtime_error("counter missed or duplicated asynchronous timing edge: selector="+std::to_string(param)+" period="+std::to_string(period)+" phase="+std::to_string(phase)+" count="+std::to_string(d.dout));
    ++checks;++samples;
   }
  }
  if(samples!=12)throw std::runtime_error("incomplete period sweep");
  d.final();++runs;
 }
 for(unsigned phase:{1u,4u,7u,9u}){
  Vvideo_calc d;d.par_num=10;d.ce_pix=1;d.new_vmode=0;d.f1=0;d.video_rotated=0;
  for(unsigned t=0;t<16000+phase;++t){
   unsigned at=t>=phase?(t-phase)%1000:999;
   d.clk_100=t%10>=5;d.clk_vid=t%26>=13;d.clk_sys=t%14>=7;
   d.vs=at<50;d.hs=at%100<15;d.de=at>=100&&at<900;d.vs_hdmi=at<50;d.eval();
   if(t>=phase+4000&&(t-phase)%1000==130){
    if(d.dout!=80)throw std::runtime_error("synchronized DE window did not count its 80 clk_100 samples");++checks;
   }
  }
  d.final();++runs;
 }
 std::cout<<"PASS video_calc: "<<checks<<" VS/HS/HDMI periods and DE windows, "<<runs<<" asynchronous period/phase runs; two-stage digital synchronization only, metastability requires fitted analysis\n";
 return 0;
}catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
