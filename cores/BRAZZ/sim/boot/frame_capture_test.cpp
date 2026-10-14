// SPDX-License-Identifier: GPL-3.0-or-later
#include "frame_capture.hpp"
#include <iostream>
#include <stdexcept>
static unsigned checks=0;
static void check(bool value){++checks;if(!value)throw std::runtime_error("frame capture check "+std::to_string(checks));}
int main(){
    try{
        CompleteFrameCapture f(3,2);uint64_t clock=100;
        auto frame=[&](unsigned w,unsigned h,unsigned salt){for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)f.pixel(clock++,x,y,uint8_t(salt+x),uint8_t(y),uint8_t(salt+y));};
        f.pixel(clock++,1,1,255,255,255);check(!f.collecting&&!f.completed);
        frame(3,2,10);check(!f.completed);
        frame(3,2,20);check(f.completed==1 && !f.rejected);
        check(f.complete.size()==18 && f.complete[0]==10 && f.complete[15]==12 && f.complete[16]==1);
        check(f.complete_start_clock==101 && f.complete_end_clock==106);
        // New origin before all pixels: reject truncated frame, keep the last good image.
        f.pixel(clock++,0,0,30,0,0);check(f.completed==2);
        f.pixel(clock++,1,0,31,0,0);frame(3,2,40);check(f.rejected==1 && f.completed==2 && f.complete[0]==20);
        // Duplicate and missing pixels must never silently form a complete frame.
        f.pixel(clock++,2,1,0,0,0);frame(3,2,50);check(f.rejected==2 && f.completed==2);
        f.pixel(clock++,0,0,60,0,0);f.pixel(clock++,2,0,62,0,0);f.pixel(clock++,0,1,60,1,0);
        frame(3,2,70);check(f.rejected==3 && f.completed==3);
        frame(4,2,80);check(f.completed==4);frame(3,2,90);check(f.rejected==4 && f.completed==4);
        f.pixel(clock++,0,0,100,0,0);check(f.completed==5 && f.complete[0]==90);
        // Actual game geometry, deterministic channel values, no stale pixels between frames.
        CompleteFrameCapture game;
        for(unsigned n=0;n<2;++n)for(unsigned y=0;y<240;++y)for(unsigned x=0;x<320;++x)game.pixel(clock++,x,y,uint8_t(x+n),uint8_t(y),uint8_t(x^y));
        check(game.completed==1 && game.complete.size()==320*240*3);
        for(unsigned y=0;y<240;++y)for(unsigned x=0;x<320;++x){unsigned a=(y*320+x)*3;check(game.complete[a]==uint8_t(x)&&game.complete[a+1]==uint8_t(y)&&game.complete[a+2]==uint8_t(x^y));}
        std::cout<<"PASS complete frame capture: "<<checks<<" checks; exact 320x240 RGB; partial/duplicate/hole/mode rejection\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
