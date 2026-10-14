// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only capture: publish only a complete, ordered configured raster rectangle.
#pragma once
#include <cstdint>
#include <vector>
#include <map>
struct CompleteFrameCapture {
    const unsigned width,height;
    std::vector<uint8_t> current,complete;
    std::vector<uint32_t> current_sources,complete_sources;
    std::map<uint32_t,uint64_t> current_bases,complete_bases;
    uint64_t current_unknown=0,complete_unknown=0;
    uint64_t pixels=0,completed=0,rejected=0,start_clock=0,last_clock=0;
    uint64_t complete_start_clock=0,complete_end_clock=0;
    bool collecting=false,invalid=false;
    CompleteFrameCapture(unsigned w=320,unsigned h=240):width(w),height(h),current(w*h*3),complete(w*h*3),current_sources(w*h,UINT32_MAX),complete_sources(w*h,UINT32_MAX){}
    void pixel(uint64_t clock,unsigned x,unsigned y,uint8_t r,uint8_t g,uint8_t b,uint32_t source_base=UINT32_MAX){
        if(x==0 && y==0){
            if(collecting){
                if(!invalid && pixels==uint64_t(width)*height){
                    complete=current;complete_sources=current_sources;complete_bases=current_bases;complete_unknown=current_unknown;++completed;
                    complete_start_clock=start_clock;complete_end_clock=last_clock;
                }else ++rejected;
            }
            collecting=true;invalid=false;pixels=0;start_clock=clock;current_bases.clear();current_unknown=0;
        }
        if(!collecting)return;
        if(pixels>=uint64_t(width)*height || x!=pixels%width || y!=pixels/width)invalid=true;
        if(!invalid){const unsigned offset=unsigned(pixels)*3;current[offset]=r;current[offset+1]=g;current[offset+2]=b;current_sources[pixels]=source_base;
            if(source_base==UINT32_MAX)++current_unknown;else ++current_bases[source_base];}
        ++pixels;last_clock=clock;
    }
};
