// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only snapshot of the real pending scanout word and its committed FIFO tag.
#pragma once
#include <cstdint>
#include <stdexcept>
struct ScanoutPixelSource {
 bool emit=false,de=false,known=false;unsigned x=0,y=0;uint16_t color=0;uint32_t base=UINT32_MAX;
 template<class D> void verify(const D& d)const {
  if(!d.video_tick)return; // reset may discard a pending pixel
  if(!emit||bool(d.video_de)!=de||d.video_x!=x||d.video_y!=y)
   throw std::runtime_error("scanout provenance/coordinate pipeline mismatch");
  if(d.video_r!=uint8_t(((color>>11)<<3)|((color>>11)>>2))||
     d.video_g!=uint8_t((((color>>5)&63)<<2)|(((color>>5)&63)>>4))||
     d.video_b!=uint8_t(((color&31)<<3)|((color&31)>>2)))
   throw std::runtime_error("scanout provenance/actual RGB word mismatch");
 }
};
inline ScanoutPixelSource scanout_source(bool emit,bool de,bool visible,bool ready,bool armed,
 unsigned x,unsigned y,uint32_t word,bool half,unsigned tag_y,uint32_t tag_base){
 ScanoutPixelSource s;s.emit=emit;s.de=de;s.x=x;s.y=y;
 bool draw=visible&&ready&&armed;s.color=draw?uint16_t(half?word>>16:word):0;
 if(emit&&de&&draw){
  if(tag_y!=y)throw std::runtime_error("ready scanout pixel lost committed FIFO row tag");
  s.known=true;s.base=tag_base;
 }
 return s;
}
