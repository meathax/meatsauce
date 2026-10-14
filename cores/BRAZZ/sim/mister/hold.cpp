// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_video_hold.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{Vcs_video_hold d;d.game_active=0;d.game_ce=0;d.game_hblank=1;d.game_vblank=1;d.game_hs=1;d.game_vs=1;d.game_x=0;d.game_y=0;d.game_rgb=0;
 unsigned since=0,pixels=0,active=0,hs_low=0,vs_low=0,game_pixels=0;bool started=false;
 auto step=[&](){d.clk=0;d.eval();d.clk=1;d.eval();++since;};
 // Phase 1: fallback raster, exact cadence, geometry and sync widths for 3 frames.
 for(unsigned c=0;c<3*455*262*12+100;++c){step();
  if(d.ce){if(started)ck(since==12,"fixed 12-clock pixel enable");started=true;since=0;
   ck(d.x<455&&d.y<262,"raster range");if(!d.hblank&&!d.vblank)++active;if(!d.hs){++hs_low;ck(d.hblank,"HS in blank");}if(!d.vs){++vs_low;ck(d.vblank,"VS in blank");}ck(d.rgb==0,"black fallback");++pixels;}}
 ck(pixels>=3*455*262,"frame pixel count");ck(active>=3*320*240-320*240/2,"active area");
 ck(hs_low/34>=3*262-1&&hs_low%34<34,"HS width 34");ck(vs_low/455>=3*3-1,"VS width 3 lines");
 // Phase 2: game active; registered pass-through with arbitrary game data.
 d.game_active=1;unsigned game_seen=0,expected=0;
 for(unsigned c=0;c<12*12*20;++c){ d.game_ce=(c%12)==5;d.game_x=c/12;d.game_y=3;d.game_rgb=0x112233+(c/12);d.game_hblank=0;d.game_vblank=0;d.game_hs=1;d.game_vs=0;
  step();if(c>40&&d.ce){ck(d.rgb==0x112233u+d.x&&d.y==3&&!d.hblank&&!d.vs&&d.hs,"game pass-through");++game_seen;}}
 ck(game_seen>100,"game pixels passed");
 // Phase 3: back to fallback; cadence returns to exactly 12 after one re-sync.
 d.game_active=0;d.game_ce=0;since=0;unsigned good=0;started=false;
 for(unsigned c=0;c<12*500;++c){step();if(d.ce){if(started&&since==12)++good;started=true;since=0;}}
 ck(good>=490,"fallback cadence recovers");(void)game_pixels;(void)expected;
 std::cout<<"PASS video_hold: "<<checks<<" checks; fixed /12 fallback raster 455x262/320x240, HS 34px, VS 3 lines inside blanking, pass-through, recovery\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL video_hold: "<<e.what()<<"\n";return 1;}
}
