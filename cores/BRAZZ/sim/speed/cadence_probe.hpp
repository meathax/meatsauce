// SPDX-License-Identifier: GPL-3.0-or-later
// Speed/cadence observer for the full-board sim. Read-only: samples top ports and
// public_flat_rd internal nets (sim/speed/speed_public.vlt). Writes two CSVs:
//   frames.csv - one row per raster frame (CRTC vblank_start)
//   flips.csv  - one row per display-bank flip (the game's presented frames)
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>
#include <array>
#include <stdexcept>

struct CadenceProbe {
    FILE* frames=nullptr; FILE* flips=nullptr; FILE* states=nullptr;
    // raster-frame accumulators
    uint64_t f_start=0,frame_no=0; unsigned f_flip_ticks=0,f_flips=0;
    uint64_t f_retire=0,f_cpu_stall=0,f_bursts=0,f_burst_wait=0,f_burst_inflight=0;
    uint64_t f_gpu_busy=0,f_gpu_syncwait=0,f_gpu_starved=0,f_gpu_memwait=0,f_polls=0,f_fc1=0;
    std::array<uint64_t,5> f_client{}; std::array<uint64_t,32> f_state{};
    uint32_t f_pk0=0,f_px0=0;
    // flip-interval accumulators (since previous flip)
    uint64_t i_start=0; unsigned i_ticks=0; uint64_t i_retire=0,i_cpu_stall=0,i_gpu_busy=0,i_gpu_memwait=0,
        i_gpu_starved=0,i_gpu_syncwait=0,i_polls=0,i_bursts=0,i_burst_wait=0,i_poll_clocks=0;
    int64_t i_sync=-1,i_fc1=-1,i_firstpoll=-1,i_lastsubmit=-1; uint32_t i_pk0=0,i_px0=0,i_front0=0;
    unsigned i_submitted=0;
    uint64_t flip_no=0;
    bool cpu_pending=false,prev_sync=false,burst_inflight=false,waiting=false;
    int prev_bank=-1; uint32_t prev_front=0;
    uint64_t mem_wait_mask=0; // GPU states counted as memory wait
    void open(const std::string& dir,uint64_t memwait_mask){
        mem_wait_mask=memwait_mask;
        frames=std::fopen((dir+"/frames.csv").c_str(),"w");
        flips=std::fopen((dir+"/flips.csv").c_str(),"w");
        states=std::fopen((dir+"/gpu_states.csv").c_str(),"w");
        if(!frames||!flips||!states)throw std::runtime_error("cadence probe open failed");
        std::fprintf(frames,"frame,clock,clocks,flip_tick,flips,display_bank,flip_count,flip_sync,queue_front,queue_rear,packets,pixels,"
            "retired,cpu_stall,gpu_busy,gpu_memwait,gpu_syncwait,gpu_starved,bursts,burst_wait,burst_inflight,polls,fc1,"
            "cpu_req,dma_req,gpu_req,spu_req,scan_req,interlaced,pc\n");
        std::fprintf(flips,"flip,clock,interval_clocks,vblank_ticks,packets,pixels,submitted,retired,cpu_stall,poll_clocks,polls,"
            "gpu_busy,gpu_memwait,gpu_syncwait,gpu_starved,bursts,burst_wait,t_fc1,t_firstpoll,t_lastsubmit,t_sync\n");
        std::fprintf(states,"frame");for(int i=0;i<32;i++)std::fprintf(states,",s%d",i);std::fprintf(states,"\n");
    }
    void flush(){std::fflush(frames);std::fflush(flips);std::fflush(states);}
    // Called once per system clock after the clock edge has been evaluated.
    template<class D,class G> void tick(uint64_t clock,D& d,const G& g){
        const unsigned st=g.state&31; ++f_state[st];
        const bool idle=st==0;
        if(!idle){++f_gpu_busy;++i_gpu_busy;if((mem_wait_mask>>st)&1){++f_gpu_memwait;++i_gpu_memwait;}}
        else if(g.flip_sync){++f_gpu_syncwait;++i_gpu_syncwait;}
        else if(g.queue_front==g.queue_rear){++f_gpu_starved;++i_gpu_starved;}
        if(g.flip_sync&&!prev_sync&&i_sync<0)i_sync=int64_t(clock-i_start);
        prev_sync=g.flip_sync;
        if(g.burst_valid&&!g.burst_ready){++f_burst_wait;++i_burst_wait;}
        if(g.burst_valid&&g.burst_ready){++f_bursts;++i_bursts;burst_inflight=true;}
        if(burst_inflight)++f_burst_inflight;
        if(g.burst_done)burst_inflight=false;
        if(g.queue_front!=prev_front){i_submitted+=(g.queue_front-prev_front)&0x7ff;prev_front=g.queue_front;i_lastsubmit=int64_t(clock-i_start);}
        if(d.retire){++f_retire;++i_retire;}
        if(d.cpu_trace_valid&&d.cpu_trace_ready)cpu_pending=true;
        if(cpu_pending){++f_cpu_stall;++i_cpu_stall;}
        if(d.cpu_trace_rsp_valid)cpu_pending=false;
        if(d.req_valid&&d.req_ready&&d.req_client<5)++f_client[d.req_client];
        if(d.mmio_valid&&d.mmio_ready&&(d.mmio_address&~3u)==0x030000a4u){
            if(d.mmio_write){ if((d.mmio_strobe&4)&&((d.mmio_data>>16)&0xff)==1){++f_fc1;if(i_fc1<0)i_fc1=int64_t(clock-i_start);waiting=true;} }
            else {++f_polls;++i_polls;if(waiting&&i_firstpoll<0)i_firstpoll=int64_t(clock-i_start);}
        }
        if(waiting)++i_poll_clocks;
        if(g.flip_tick){++f_flip_ticks;++i_ticks;}
        const int bank=g.display_bank;
        if(prev_bank>=0&&bank!=prev_bank){
            ++f_flips;++flip_no;
            std::fprintf(flips,"%llu,%llu,%llu,%u,%u,%u,%u,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%lld,%lld,%lld,%lld\n",
                (unsigned long long)flip_no,(unsigned long long)clock,(unsigned long long)(clock-i_start),i_ticks,
                unsigned(d.gpu_packets-i_pk0),unsigned(d.gpu_pixels-i_px0),i_submitted,(unsigned long long)i_retire,(unsigned long long)i_cpu_stall,
                (unsigned long long)i_poll_clocks,(unsigned long long)i_polls,(unsigned long long)i_gpu_busy,(unsigned long long)i_gpu_memwait,
                (unsigned long long)i_gpu_syncwait,(unsigned long long)i_gpu_starved,(unsigned long long)i_bursts,(unsigned long long)i_burst_wait,
                (long long)i_fc1,(long long)i_firstpoll,(long long)i_lastsubmit,(long long)i_sync);
            std::fflush(flips);
            i_start=clock;i_ticks=0;i_retire=i_cpu_stall=i_gpu_busy=i_gpu_memwait=i_gpu_starved=i_gpu_syncwait=i_polls=i_bursts=i_burst_wait=i_poll_clocks=0;
            i_sync=i_fc1=i_firstpoll=i_lastsubmit=-1;i_pk0=d.gpu_packets;i_px0=d.gpu_pixels;i_submitted=0;waiting=false;
        }
        prev_bank=bank;
        if(g.vblank_start){
            ++frame_no;
            std::fprintf(frames,"%llu,%llu,%llu,%u,%u,%d,%u,%u,%u,%u,%u,%u,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%u,%08x\n",
                (unsigned long long)frame_no,(unsigned long long)clock,(unsigned long long)(clock-f_start),f_flip_ticks,f_flips,bank,unsigned(g.flip_count),unsigned(g.flip_sync),
                unsigned(g.queue_front),unsigned(g.queue_rear),unsigned(d.gpu_packets-f_pk0),unsigned(d.gpu_pixels-f_px0),
                (unsigned long long)f_retire,(unsigned long long)f_cpu_stall,(unsigned long long)f_gpu_busy,(unsigned long long)f_gpu_memwait,
                (unsigned long long)f_gpu_syncwait,(unsigned long long)f_gpu_starved,(unsigned long long)f_bursts,(unsigned long long)f_burst_wait,
                (unsigned long long)f_burst_inflight,(unsigned long long)f_polls,(unsigned long long)f_fc1,
                (unsigned long long)f_client[0],(unsigned long long)f_client[1],(unsigned long long)f_client[2],(unsigned long long)f_client[3],(unsigned long long)f_client[4],
                unsigned(g.interlaced),unsigned(d.pc));
            std::fprintf(states,"%llu",(unsigned long long)frame_no);for(auto v:f_state)std::fprintf(states,",%llu",(unsigned long long)v);std::fprintf(states,"\n");
            if(frame_no%16==0)flush();
            f_start=clock;f_flip_ticks=f_flips=0;f_retire=f_cpu_stall=f_bursts=f_burst_wait=f_burst_inflight=0;
            f_gpu_busy=f_gpu_syncwait=f_gpu_starved=f_gpu_memwait=f_polls=f_fc1=0;f_client={};f_state={};
            f_pk0=d.gpu_packets;f_px0=d.gpu_pixels;
        }
    }
};
