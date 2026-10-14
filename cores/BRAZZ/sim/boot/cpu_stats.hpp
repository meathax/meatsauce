// SPDX-License-Identifier: GPL-3.0-or-later
// Optional CPU throughput profile (CS_CPU_STATS=<window clocks>). Counts every
// system clock by CPU state/continuation and CP0 cache state, so the cost of
// each retired instruction can be split into fetch, data, store and MMIO waits.
// Observation only: reads internal state after the clock edge, drives nothing.
#pragma once
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
struct CpuStats {
    uint64_t window=0,clocks=0,retired=0,w_clocks=0,w_retired=0,ce=0;
    std::array<std::array<uint64_t,16>,256> hist{}; // [cpu_state*16+continuation][cp0_state]
    uint64_t cpu_wait_ready=0,bypass=0;
    // Shared-bus occupancy per client (accept -> response), window and total.
    std::array<uint64_t,5> occ_n{},occ_sum{},occ_max{},w_occ_n{},w_occ_sum{},w_occ_max{};
    uint64_t bus_accept_clock=0;unsigned bus_owner=0;bool bus_busy=false;
    void bus(uint64_t clock,bool accepted,unsigned client,bool responded){
        if(responded&&bus_busy){uint64_t d=clock-bus_accept_clock;unsigned c=bus_owner<5?bus_owner:4;
            ++occ_n[c];occ_sum[c]+=d;if(d>occ_max[c])occ_max[c]=d;++w_occ_n[c];w_occ_sum[c]+=d;if(d>w_occ_max[c])w_occ_max[c]=d;bus_busy=false;}
        if(accepted){bus_busy=true;bus_accept_clock=clock;bus_owner=client;}
    }
    void print_bus(const char* tag,const std::array<uint64_t,5>& n,const std::array<uint64_t,5>& sum,const std::array<uint64_t,5>& mx) const {
        std::printf("CPUSTAT %s bus occupancy n/avg/max:",tag);
        for(unsigned c=0;c<5;++c)std::printf(" c%u=%llu/%.1f/%llu",c,(unsigned long long)n[c],n[c]?double(sum[c])/double(n[c]):0.0,(unsigned long long)mx[c]);
        std::printf("\n");
    }
    explicit CpuStats(){if(const char* e=std::getenv("CS_CPU_STATS"))window=std::strtoull(e,nullptr,0);}
    ~CpuStats(){final_report();}
    bool enabled() const {return window!=0;}
    void sample(unsigned cpu_state,unsigned continuation,unsigned cp0_state,bool retire,bool mem_valid,bool mem_ready,bool ce_now){
        ++clocks;++w_clocks;if(retire){++retired;++w_retired;}if(ce_now)++ce;
        ++hist[(cpu_state&15)*16+(continuation&15)][cp0_state&15];
        if(mem_valid&&!mem_ready)++cpu_wait_ready;
    }
    void window_report(uint64_t clock,uint32_t pc=0,uint32_t packets=0){
        if(!window||w_clocks<window)return;
        std::printf("CPUSTAT clock=%llu window_instr=%llu window_clocks=%llu instr_per_clk=%.4f MAME_ratio=%.4f pc=%08x gpu_packets=%u\n",
            (unsigned long long)clock,(unsigned long long)w_retired,(unsigned long long)w_clocks,
            double(w_retired)/double(w_clocks),2.0*double(w_retired)/double(w_clocks),pc,packets);
        print_bus("window",w_occ_n,w_occ_sum,w_occ_max);w_occ_n={};w_occ_sum={};w_occ_max={};
        w_clocks=0;w_retired=0;std::fflush(stdout);
    }
    void final_report() const {
        if(!window)return;
        static const char* cs[]={"RESET_START","FETCH_START","EXECUTE","ACCESS_START","ACCESS_WAIT","STACK_SCAN","VECTOR_START","RETIRE","STOPPED","CP_START","CP_WAIT","LOAD_COMMIT","?","?","?","?"};
        static const char* cn[]={"reset","fetch","load","store","push","pop","vector","?","?","?","?","?","?","?","?","?"};
        static const char* ks[]={"IDLE","LOOKUP","HIT_READ","HIT_REPLY","FILL_REQ","FILL_RSP","WRITE_REQ","WRITE_RSP","BYP_REQ","BYP_RSP","INVAL","?","?","?","?","?"};
        std::printf("CPUSTAT total clocks=%llu retired=%llu clocks_per_instr=%.3f MAME_ratio=%.4f cpu_mem_wait_ready=%llu\n",
            (unsigned long long)clocks,(unsigned long long)retired,double(clocks)/double(retired?retired:1),
            2.0*double(retired)/double(clocks?clocks:1),(unsigned long long)cpu_wait_ready);
        print_bus("total",occ_n,occ_sum,occ_max);
        print_bus("last-window",w_occ_n,w_occ_sum,w_occ_max);
        for(unsigned k=0;k<256;++k){
            uint64_t row=0;for(auto v:hist[k])row+=v;if(!row)continue;
            const unsigned st=k>>4,co=k&15;
            std::printf("CPUSTAT %-12s %-6s %6.3f clk/instr :",cs[st],(st==3||st==4)?cn[co]:"",double(row)/double(retired?retired:1));
            for(unsigned c=0;c<16;++c)if(hist[k][c])std::printf(" %s=%.3f",ks[c],double(hist[k][c])/double(retired?retired:1));
            std::printf("\n");
        }
        std::fflush(stdout);
    }
};
