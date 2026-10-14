// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_video_freak.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{unsigned checks=0;
 for(unsigned rotated=0;rotated<2;rotated++)for(unsigned mode=0;mode<5;mode++){
  Vcs_video_freak d;d.ROTATE_90=rotated;d.SCALE=mode;d.ARX=rotated?3:4;d.ARY=rotated?4:3;d.HDMI_WIDTH=1920;d.HDMI_HEIGHT=1080;d.CROP_SIZE=0;d.CROP_OFF=0;
  for(unsigned frame=0;frame<5;frame++)for(unsigned y=0;y<262;y++)for(unsigned x=0;x<455;x++){
   d.CE_PIXEL=1;d.VGA_DE_IN=x<320&&y<240;d.VGA_VS=!(y>=244&&y<247);d.CLK_VIDEO=0;d.eval();d.CLK_VIDEO=1;d.eval();
  }
  if(!mode){++checks;if(d.VIDEO_ARX!=(rotated?3:4)||d.VIDEO_ARY!=(rotated?4:3))throw std::runtime_error("normal aspect");}
  else{++checks;if(!(d.VIDEO_ARY&4096)||(d.VIDEO_ARY&4095)!=960)throw std::runtime_error("native/rotated vertical integer height");
   if(mode>1){++checks;if(!(d.VIDEO_ARX&4096)||(d.VIDEO_ARX&4095)%(rotated?240:320))throw std::runtime_error("rotated horizontal integer pixels");}
   if(mode==4){++checks;if((d.VIDEO_ARX&4095)!=(rotated?720:1280))throw std::runtime_error("nearest HV integer dimensions");}
  }
 }
 std::cout<<"PASS scaling: "<<checks<<" checks; all five modes at 1080p, native and 90-degree raster dimensions\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL scaling: "<<e.what()<<"\n";return 1;}
}
