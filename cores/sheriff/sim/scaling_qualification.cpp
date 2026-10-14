// SPDX-License-Identifier: GPL-2.0-or-later
// Viewport fit, native DE preservation and pixel multiples in both orientations.
#include "Vn8080_scaling.h"
#include "verilated.h"
#include <iostream>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);
 for(unsigned rotated=0;rotated<2;rotated++) for(unsigned resolution=0;resolution<2;resolution++) for(unsigned mode=0;mode<5;mode++) {
  Vn8080_scaling b; b.rotated=rotated;b.ARX=rotated?3:4;b.ARY=rotated?4:3;
  b.HDMI_WIDTH=resolution?1920:1280;b.HDMI_HEIGHT=resolution?1080:720;
  b.CROP_SIZE=0;b.CROP_OFF=0;b.SCALE=mode;
  for(unsigned tick=0;tick<819200*4;tick++){
   unsigned pixel=tick/10,x=pixel%320,y=(240+pixel/320)%256;
   b.CE_PIXEL=tick%10==0;b.VGA_VS=y>=248&&y<252;b.VGA_DE_IN=x<256&&y>=16&&y<240;
   b.CLK_VIDEO=0;b.eval();b.CLK_VIDEO=1;b.eval();
   if(tick>819200*2 && b.VGA_DE!=b.VGA_DE_IN){std::cerr<<"FAIL native DE\n";return 1;}
  }
  unsigned w=b.VIDEO_ARX&4095,h=b.VIDEO_ARY&4095;
  if(mode==0){if(b.VIDEO_ARX!=b.ARX||b.VIDEO_ARY!=b.ARY)return 2;}
  else {
   if(!(b.VIDEO_ARX&4096)||!(b.VIDEO_ARY&4096)||!w||!h||w>b.HDMI_WIDTH||h>b.HDMI_HEIGHT||h%(rotated?256:224)) {std::cerr<<"FAIL fit/height "<<rotated<<' '<<resolution<<' '<<mode<<' '<<w<<'x'<<h<<"\n";return 3;}
   if(mode>1&&w%(rotated?224:256))return 4;
  }
  std::cout<<"PASS scale "<<mode<<" rotated "<<rotated<<" "<<w<<"x"<<h<<"\n";
 }
}
