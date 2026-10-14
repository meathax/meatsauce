// SPDX-License-Identifier: GPL-3.0-or-later
// Native simulator state, never a production CPU/RAM injection port.
#pragma once
#include "verilated_save.h"
#ifdef CS_TIMED_SDRAM
#include "../obj_dir/host_timed_checkpoint/identity.hpp"
#else
#include "../obj_dir/host_checkpoint/identity.hpp"
#endif
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <type_traits>
#include <utility>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <cstdlib>
#endif

inline void checkpoint_binary_mode(){
#ifdef _WIN32
    // Verilator 5.050 save.cpp opens descriptors without O_BINARY. MinGW's
    // default text mode expands LF and treats 0x1a as EOF on restore.
    if(_set_fmode(_O_BINARY))throw std::runtime_error("checkpoint binary mode failed");
#endif
}

struct CheckpointArchive {
    bool reading;
    std::fstream file;
    explicit CheckpointArchive(const std::filesystem::path& path,bool load):reading(load),
        file(path,std::ios::binary|(load?std::ios::in:std::ios::out|std::ios::trunc)) {
        if(!file)throw std::runtime_error("checkpoint file open failed");
    }
    void block(void* data,size_t size){
        if(reading)file.read(static_cast<char*>(data),size);
        else file.write(static_cast<const char*>(data),size);
        if(!file)throw std::runtime_error("checkpoint truncated or write failed");
    }
    template<class T> void value(T& data){
        static_assert(std::is_trivially_copyable_v<T>);
        block(&data,sizeof(data));
    }
    template<class A,class B> void value(std::pair<A,B>& data){value(data.first);value(data.second);}
    void value(BootObserver::BusEvent& data){(*this)(data.at,data.start,data.client,data.target,data.strobe,data.address,data.data,data.write,data.response,data.error);}
#ifdef CS_TIMED_SDRAM
    void value(SdramReturnBeat& data){(*this)(data.at,data.data);}
#endif
    void value(SdramModel::Beat& data){(*this)(data.at,data.index);}
    void value(DdrModel::Beat& data){(*this)(data.cycle,data.data);}
    void value(DdrModel::Command& data){(*this)(data.read,data.write,data.address,data.burst,data.be,data.data);}
    template<class T,size_t N> void value(std::array<T,N>& data){for(auto& x:data)value(x);}
    template<class T> void value(std::vector<T>& data){
        uint64_t n=data.size();value(n);
        if(n>0x8000000/sizeof(T))throw std::runtime_error("checkpoint vector size invalid");
        if(reading)data.resize(n);
        if constexpr(std::is_trivially_copyable_v<T>)block(data.data(),n*sizeof(T));
        else for(auto& x:data)value(x);
    }
    template<class T> void value(std::deque<T>& data){
        uint64_t n=data.size();value(n);
        if(n>1024)throw std::runtime_error("checkpoint pending queue size invalid");
        if(reading)data.resize(n);
        for(auto& x:data)value(x);
    }
    template<class K,class V> void value(std::map<K,V>& data){
        uint64_t n=data.size();value(n);
        if(n>0x10000)throw std::runtime_error("checkpoint map size invalid");
        if(reading){data.clear();for(uint64_t i=0;i<n;i++){K k{};V v{};value(k);value(v);data.emplace(k,v);}}
        else for(const auto& x:data){auto k=x.first;auto v=x.second;value(k);value(v);}
    }
    template<class... T> void operator()(T&... data){(value(data),...);}
    void identity(){
        std::array<char,8> magic{'C','S','C','P','0','0','0','1'},actual_magic=magic;
        std::array<char,65> expected{},actual{};
        std::memcpy(expected.data(),CS_CHECKPOINT_ID,65);actual=expected;
        value(actual_magic);value(actual);
        if(actual_magic!=magic||actual!=expected)throw std::runtime_error("checkpoint schema/source/ROM identity mismatch");
    }
};

inline const char* checkpoint_env(const char* key){const char* v=std::getenv(key);return v?v:"";}
inline uint64_t checkpoint_number(const char* key){const char* v=checkpoint_env(key);return *v?std::stoull(v):0;}
inline uint64_t checkpoint_hash(const std::filesystem::path& path){
    std::ifstream file(path,std::ios::binary);if(!file)throw std::runtime_error("checkpoint hash open failed");
    uint64_t h=14695981039346656037ULL;char chunk[65536];
    while(file){file.read(chunk,sizeof(chunk));for(std::streamsize i=0;i<file.gcount();i++){h^=uint8_t(chunk[i]);h*=1099511628211ULL;}}
    return h;
}

template<class A> void checkpoint_memory(A& a,Memory& m,SdramModel& s,DdrModel& d){
    a(m.ram,m.nvram,m.reset_ram,m.bank,m.writes);
    a(s.words,s.row,s.activated,s.closed,s.last_write,s.read_beats,s.cycle,s.blocked_until,
      s.refreshes,s.reads,s.writes,s.last_refresh,s.max_refresh_gap,s.configured,s.write_tail,
      s.write_index,s.write_bank,s.data);
    a(d.bytes,d.pending,d.cycles,d.reads,d.writes,d.beats,d.busy_cycles,d.random,d.stalled,
      d.held,d.current,d.current_accepted);
}
template<class A> void checkpoint_observer(A& a,BootObserver& o,CabinetInput& c){
    a(o.pages,o.access_latencies,o.rgb,o.clock,o.start_access,o.accesses,o.access_cycles,
      o.enabled_accesses,o.enabled_cycles,o.disabled_accesses,o.disabled_cycles,
      o.raster_frames,o.active_pixels,o.irq_acks,o.min_x,o.min_y,o.max_x,o.max_y,
      o.access_enabled,o.previous_vblank,o.first_gpu_saved,o.clipped,o.active_packet_completed,
      o.gpu_start_saved,o.context_trace_closed,o.gpu_trace_requests,o.video_trace_writes,
      o.concurrent_trace_writes,o.cabinet_commands,o.cabinet_releases,o.cabinet_sequence,
      o.previous_packets,o.report_period,o.bus_tail,o.bus_tail_count,o.pending_bus,o.diagnostic_pending);
    auto& f=o.frames;
    a(f.current,f.complete,f.pixels,f.completed,f.rejected,f.start_clock,f.last_clock,
      f.complete_start_clock,f.complete_end_clock,f.collecting,f.invalid,
      f.current_sources,f.complete_sources,f.current_bases,f.complete_bases,f.current_unknown,f.complete_unknown);
    a(c.next_poll,c.last_sequence,c.commands,c.releases,c.invalid_polls,c.release_frame,c.release_pending);
    if(a.reading&&o.context_trace_closed){o.gpu_bus.close();o.video_mmio.close();o.concurrent_writes.close();}
}

template<class Dut,class External> void save_checkpoint(const std::filesystem::path& directory,
                                                       uint64_t clock,Dut& dut,External external){
    if(std::filesystem::exists(directory))throw std::runtime_error("checkpoint destination exists");
    const auto stage=std::filesystem::path(directory.string()+".partial");
    if(std::filesystem::exists(stage))throw std::runtime_error("incomplete checkpoint destination exists");
    std::filesystem::create_directories(stage);
    {VerilatedSave state;state.open((stage/"rtl.bin").string());state<<dut;state.close();}
    {CheckpointArchive state(stage/"external.bin",false);state.identity();state.value(clock);external(state);}
    const uint64_t rtl_hash=checkpoint_hash(stage/"rtl.bin"),external_hash=checkpoint_hash(stage/"external.bin");
    {std::ofstream manifest(stage/"manifest.txt");manifest<<CS_CHECKPOINT_ID<<'\n'<<clock<<'\n'<<rtl_hash<<'\n'<<external_hash<<'\n';
     if(!manifest)throw std::runtime_error("checkpoint manifest write failed");}
    std::filesystem::rename(stage,directory);
    std::printf("CHECKPOINT saved clock=%llu path=%s identity=%s\n",(unsigned long long)clock,directory.string().c_str(),CS_CHECKPOINT_ID);
    std::fflush(stdout);
}
template<class Dut,class External> uint64_t restore_checkpoint(const std::filesystem::path& directory,
                                                              Dut& dut,External external){
    std::ifstream manifest(directory/"manifest.txt");std::string id;uint64_t clock{},rtl_hash{},external_hash{};
    if(!(manifest>>id>>clock>>rtl_hash>>external_hash)||id!=CS_CHECKPOINT_ID)
        throw std::runtime_error("checkpoint source/ROM manifest mismatch");
    if(checkpoint_hash(directory/"rtl.bin")!=rtl_hash||checkpoint_hash(directory/"external.bin")!=external_hash)
        throw std::runtime_error("checkpoint file integrity mismatch");
    {CheckpointArchive state(directory/"external.bin",true);state.identity();uint64_t actual_clock{};state.value(actual_clock);
     if(actual_clock!=clock)throw std::runtime_error("checkpoint clock mismatch");external(state);}
    {VerilatedRestore state;state.open((directory/"rtl.bin").string());state>>dut;state.close();}
    std::printf("CHECKPOINT restored clock=%llu path=%s identity=%s\n",(unsigned long long)clock,directory.string().c_str(),CS_CHECKPOINT_ID);
    std::fflush(stdout);return clock;
}
