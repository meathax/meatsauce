// SPDX-License-Identifier: GPL-3.0-or-later
// Speed check: replay one MAME-captured frame's GPU packet list (texture/queue RAM + frame RAM
// dumped by build/speed/mame/dump_frames.lua) through the real GPU/fabric/SDRAM controller with
// live scanout and an optional CPU-like peer, and report render clocks vs the frame period.
// usage: Vcs_gpu_replay <dump_dir> <peer_period: 0=none, 1=back-to-back, N=one read per N clocks>
#include "Vcs_gpu_replay.h"
#include "verilated.h"
#include "../memory/sdram_model.hpp"
#include "../memory/ddr_model.hpp"
#include <array>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
double sc_time_stamp(){return 0;}
static uint32_t model_index(uint32_t physical){
    return ((physical>>12)<<11)|(((physical>>10)&3)<<9)|(((physical>>2)&0xff)<<1)|((physical>>1)&1);
}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
 if(argc<3)throw std::runtime_error("usage: dump_dir peer_period");
 const std::string dir=argv[1];const unsigned peer_period=std::stoul(argv[2]);
 const uint64_t memwait_mask=argc>3?std::stoull(argv[3],nullptr,0):0;
 Vcs_gpu_replay d;SdramModel s;DdrModel ddr;
 auto check=[](bool x,const char*t){if(!x)throw std::runtime_error(t);};
 auto finish=[&](){ddr.finish(d);d.sdram_data_in=s.tick(d.sdram_cke,d.sdram_cs_n,d.sdram_ras_n,d.sdram_cas_n,d.sdram_we_n,d.sdram_ba,d.sdram_address,d.sdram_dqm,d.sdram_data_out,d.sdram_data_oe);d.eval();};
 d.peer_valid=0;d.peer_write=0;d.reg_valid=0;d.reset=1;for(unsigned i=0;i<4;i++){ddr.prepare(d);finish();}d.reset=0;
 for(unsigned n=0;n<400000&&!d.memory_initialized;n++){ddr.prepare(d);finish();}
 check(d.memory_initialized,"fabric power-up timeout");
 std::ifstream meta(dir+"/meta.txt");unsigned frame,first,end,control,bank1,display;
 meta>>frame>>first>>end>>control>>bank1>>display;check(bool(meta),"meta.txt");
 auto load=[&](const char*n){std::vector<uint8_t> v(0x800000);std::ifstream f(dir+"/"+n,std::ios::binary);f.read(reinterpret_cast<char*>(v.data()),v.size());check(f.gcount()==int64_t(v.size()),n);return v;};
 auto texture=load("texture.bin"),framebuf=load("frame.bin");
 const unsigned window=(end-first)&0x7ff;check(window>0,"empty packet list");
 std::vector<unsigned> sync_at;for(unsigned i=0;i<window;i++){const unsigned q=(first+i)&0x7ff;if(texture[q*64]&1)sync_at.push_back(i);}
 check(!sync_at.empty(),"no sync flip in window");
 // Replay exactly one presented frame: after the second-to-last sync flip through the last one.
 const unsigned seg_begin=sync_at.size()>=2?sync_at[sync_at.size()-2]+1:0,seg_end=sync_at.back()+1;
 first=(first+seg_begin)&0x7ff;const unsigned count=seg_end-seg_begin;
 std::vector<uint8_t> packets(count*64);
 for(unsigned i=0;i<count;i++)std::copy_n(texture.begin()+((first+i)&0x7ff)*64,64,packets.begin()+i*64);
 std::copy(packets.begin(),packets.end(),texture.begin());   // relocate to queue slots 0..count-1
 unsigned syncs=0,last_sync=0;for(unsigned i=0;i<count;i++){uint16_t p0=packets[i*64]|(packets[i*64+1]<<8);if(p0&1){++syncs;last_sync=i;}}
 auto stage=[&](const std::vector<uint8_t>&m,uint32_t base){for(uint32_t a=0;a<m.size();a+=2)s.words[model_index(base+a)]=uint16_t(m[a]|(m[a+1]<<8));};
 stage(texture,0x00800000);stage(framebuf,0x01000000);
 auto reg=[&](unsigned a,uint32_t v,unsigned strobe){d.reg_address=a;d.reg_write=1;d.reg_data=v;d.reg_strobe=strobe;d.reg_valid=1;
  for(unsigned n=0;;n++){ddr.prepare(d);finish();if(d.reg_rsp_valid)break;check(n<100000,"GPU MMIO timeout");}d.reg_valid=0;};
 // Let the scanout arm and settle for one frame before starting the render.
 for(unsigned n=0;n<1500000;n++){ddr.prepare(d);finish();}
 reg(0x90,bank1?0x8000:0,3);reg(0x8c,(control&~8u)|4u,1);
 const unsigned stop_at=syncs?last_sync+1:count;
 reg(0x80,count,3);
 std::array<uint64_t,32> hist{};uint64_t busy=0,memwait=0,bursts=0,burst_wait=0,peer_req=0,peer_lat=0,peer_max=0,pixels=0;
 bool pending=false;uint64_t begin=0,render=0;bool done=false;
 for(uint64_t clock=0;clock<200000000;clock++){
  d.peer_valid=peer_period&&!pending&&(peer_period==1||clock%peer_period==0);d.peer_write=0;
  d.peer_address=0x02000000+uint32_t(((peer_req*0x1024)+(peer_req&7)*4)&0x7ffffc);
  ddr.prepare(d);
  const bool take=d.peer_valid&&d.peer_ready;
  if(d.peer_rsp_valid){check(pending,"lost peer response");pending=false;peer_lat+=clock-begin;peer_max=std::max<uint64_t>(peer_max,clock-begin);}
  if(take){pending=true;begin=clock;++peer_req;}
  const unsigned st=d.gpu_state&31;++hist[st];if(st){++busy;if((memwait_mask>>st)&1)++memwait;}
  if(d.gb_valid_o&&!d.gb_ready_o)++burst_wait;if(d.gb_valid_o&&d.gb_ready_o)++bursts;
  if(d.video_tick&&d.video_de&&d.video_armed)++pixels;
  check(!d.video_fault,"scanout memory fault");check(!d.video_underrun,"display underrun");check(!d.gpu_fault,"GPU fault");
  finish();
  if(d.gpu_queue_rear==stop_at&&!d.gpu_busy){render=clock+1;done=true;break;}
  if(d.gpu_flip_sync&&d.gpu_queue_rear!=stop_at){std::fprintf(stderr,"early sync flip at %u/%u\n",unsigned(d.gpu_queue_rear),stop_at);render=clock+1;done=true;break;}
 }
 check(done,"render did not finish in 200M clocks");
 std::printf("RESULT frame=%u packets=%u syncs=%u processed=%u render_clocks=%llu frame_period=1430520 ratio=%.3f busy=%llu memwait=%llu bursts=%llu burst_wait=%llu gpu_pixels=%u peer_period=%u peer_reqs=%llu peer_avg_lat=%.1f peer_max_lat=%llu sdram_refresh=%llu\n",
   frame,count,syncs,unsigned(d.gpu_packets),(unsigned long long)render,double(render)/1430520.0,(unsigned long long)busy,(unsigned long long)memwait,
   (unsigned long long)bursts,(unsigned long long)burst_wait,unsigned(d.gpu_pixels),peer_period,(unsigned long long)peer_req,peer_req?double(peer_lat)/peer_req:0.0,(unsigned long long)peer_max,(unsigned long long)s.refreshes);
 std::printf("HIST");for(unsigned i=0;i<32;i++)if(hist[i])std::printf(" %u:%llu",i,(unsigned long long)hist[i]);std::printf("\n");
 return 0;
}catch(const std::exception&e){std::fprintf(stderr,"FAIL gpu replay: %s\n",e.what());return 1;}}
