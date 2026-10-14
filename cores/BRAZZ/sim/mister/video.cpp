// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_diagnostic_video.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{Vcs_diagnostic_video d;unsigned pixels=0,active=0,frames=0,period=0,reset_pixels=0;
 for(unsigned cycle=0;cycle<3*1430520;cycle++){
  d.reset=cycle>100000&&cycle<110000;d.clk=0;d.eval();++period;
  if(d.ce_pix){ck(period==12,"steady native divider despite reset");period=0;ck(d.pixel_x==pixels%455&&d.pixel_y==(pixels/455)%262,"native beam");ck(d.hsync==!(d.pixel_x>=344&&d.pixel_x<376),"continuous HS");ck(d.vsync==!(d.pixel_y>=244&&d.pixel_y<247),"continuous VS");if(d.frame_start)++frames;if(!d.hblank&&!d.vblank)++active;if(d.reset){++reset_pixels;ck(d.rgb==0,"reset blanks RGB only");}++pixels;}
  d.clk=1;d.eval();
 }
 ck(pixels==3*455*262&&active==3*320*240&&frames==3&&reset_pixels>0,"three complete frames");std::cout<<"PASS diagnostic video: "<<checks<<" checks; fixed /12, 455x262, 320x240, 1430520 clocks/frame\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL video: "<<e.what()<<"\n";return 1;}
}
